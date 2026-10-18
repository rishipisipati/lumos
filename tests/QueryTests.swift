import Foundation

func querySuite() -> TestSuite {
    let suite = TestSuite(name: "Query")

    func sample() throws -> IndexData {
        return try buildTestIndex(rootPath: "/r", entries: [
            testFolder("/r/Clients"),
            testFolder("/r/Clients/Acme"),
            testFile("/r/Clients/Acme/engagement letter.pdf", size: 300, modified: 300),
            testFile("/r/Clients/Acme/Engagement_Letter_v2.docx", size: 100, modified: 500),
            testFolder("/r/Clients/Beta"),
            testFile("/r/Clients/Beta/engagement letter.pdf", size: 200, modified: 100),
            testFolder("/r/Clients/Beta/Engagement"),
            testFile("/r/.engagement-cache", size: 1, modified: 1)
        ])
    }

    func request(
        _ query: String,
        limit: Int,
        offset: Int,
        sort: ResultSort,
        descending: Bool,
        within: [String],
        kind: ResultKind
    ) -> FindRequest {
        return FindRequest(
            query: query,
            limit: limit,
            offset: offset,
            sort: sort,
            descending: descending,
            includeHidden: false,
            within: within,
            kind: kind,
            waitSeconds: 0
        )
    }

    suite.test("total, paging and kinds") {
        let data = try sample()
        let all = try executeFind(data, request: request("engagement letter", limit: 50, offset: 0, sort: .path, descending: false, within: [], kind: .any), trigrams: nil)
        try expectEqual(all.total, 3, "space-separated words are ANDed, so underscores and order don't matter")
        let words = try executeFind(data, request: request("engagement", limit: 2, offset: 1, sort: .name, descending: false, within: [], kind: .any), trigrams: nil)
        try expectEqual(words.total, 4, "hidden excluded")
        try expectEqual(words.entries.count, 2, "window size")
        let folders = try executeFind(data, request: request("engagement", limit: 50, offset: 0, sort: .name, descending: false, within: [], kind: .folders), trigrams: nil)
        try expectEqual(folders.entries.map(\.path), ["/r/Clients/Beta/Engagement"], "folders only")
        try expectEqual(folders.entries.map(\.kind), [.folder], "folder kind")
        var withPackage = data
        _ = try appendTestEntry(&withPackage, parent: data.roots[0].entryId, name: "Viewer.app", size: 0, modified: 0, flags: EntryFlag.directory | EntryFlag.opaque)
        let packages = try executeFind(withPackage, request: request("viewer", limit: 50, offset: 0, sort: .name, descending: false, within: [], kind: .any), trigrams: nil)
        try expectEqual(packages.entries.map(\.kind), [.package], "bundles report as packages")
    }

    suite.test("newest first and scoping") {
        let data = try sample()
        let newest = try executeFind(data, request: request("engagement", limit: 50, offset: 0, sort: .modified, descending: true, within: [], kind: .files), trigrams: nil)
        try expectEqual(
            newest.entries.map(\.path),
            ["/r/Clients/Acme/Engagement_Letter_v2.docx", "/r/Clients/Acme/engagement letter.pdf", "/r/Clients/Beta/engagement letter.pdf"],
            "modified descending"
        )
        try expectEqual(newest.entries.first?.modified, Date(timeIntervalSince1970: 500), "modified date")
        let scoped = try executeFind(data, request: request("engagement", limit: 50, offset: 0, sort: .name, descending: false, within: ["/r/Clients/Beta"], kind: .any), trigrams: nil)
        try expectEqual(scoped.entries.map(\.path), ["/r/Clients/Beta/Engagement", "/r/Clients/Beta/engagement letter.pdf"], "inside Beta only")
        let empty = try executeFind(data, request: request("", limit: 50, offset: 0, sort: .name, descending: false, within: ["/r/Clients/Acme"], kind: .files), trigrams: nil)
        try expectEqual(empty.total, 2, "empty query lists a folder")
        let folders = try executeFind(data, request: request("", limit: 50, offset: 0, sort: .name, descending: false, within: ["/r/Clients"], kind: .folders), trigrams: nil)
        try expectEqual(folders.entries.map(\.path), ["/r/Clients/Acme", "/r/Clients/Beta", "/r/Clients/Beta/Engagement"], "scope folder is not its own result")
        let nested = try executeFind(data, request: request("", limit: 50, offset: 0, sort: .name, descending: false, within: ["/r/Clients", "/r/Clients/Beta"], kind: .folders), trigrams: nil)
        try expectEqual(nested.total, 3, "a nested scope folder stays a result")
        let file = try executeFind(data, request: request("", limit: 50, offset: 0, sort: .name, descending: false, within: ["/r/Clients/Beta/engagement letter.pdf"], kind: .any), trigrams: nil)
        try expectEqual(file.total, 1, "a scoped file matches itself")
    }

    suite.test("scope errors are explicit") {
        let data = try sample()
        var notIndexed = false
        do {
            _ = try executeFind(data, request: request("x", limit: 1, offset: 0, sort: .name, descending: false, within: ["/r/Missing"], kind: .any), trigrams: nil)
        } catch FindError.notIndexed(let path) {
            notIndexed = path == "/r/Missing"
        }
        try expect(notIndexed, "missing folder")
        var outside = false
        do {
            _ = try executeFind(data, request: request("x", limit: 1, offset: 0, sort: .name, descending: false, within: ["/elsewhere"], kind: .any), trigrams: nil)
        } catch FindError.outsideRoots(_, let roots) {
            outside = roots == ["/r"]
        }
        try expect(outside, "outside roots")
    }

    suite.test("protocol round trip") {
        let find = request("a|b", limit: 5, offset: 10, sort: .size, descending: true, within: ["/r"], kind: .files)
        for message in [QueryRequest.find(find), .status, .shutdown] {
            let decoded = try makeQueryDecoder().decode(QueryRequest.self, from: try makeQueryEncoder().encode(message))
            try expectEqual(decoded, message, "request")
        }
        let state = IndexState(phase: "live", exact: true, objects: 3, roots: ["/r"], owner: .daemon, pid: 42, problem: nil)
        let result = FindResult(
            total: 1,
            offset: 0,
            entries: [FoundEntry(path: "/r/a b.pdf", kind: .file, size: 9, modified: Date(timeIntervalSince1970: 1_700_000_000))],
            index: state,
            elapsedMs: 1
        )
        for message in [QueryResponse.found(result), .status(state), .stopping, .failure("nope")] {
            let encoded = try makeQueryEncoder().encode(message)
            try expect(!encoded.contains(0x0A), "single line")
            try expectEqual(try makeQueryDecoder().decode(QueryResponse.self, from: encoded), message, "response")
        }
    }

    suite.test("socket server answers exactly after fresh changes") {
        let root = try makeTempFolder("query-root")
        let home = try makeTempFolder("query-home")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        try writeFile(at: root.appendingPathComponent("Matters/2024/brief.docx"), contents: "b")
        let service = IndexService(folder: home, roots: [root.path])
        try service.start()
        var shutdownRequested = false
        let server = try startQueryServer(service, owner: .daemon, onRequest: {}, shutdown: { shutdownRequested = true })
        defer {
            server.stop()
            service.stop()
        }
        let socket = querySocketPath(folder: home)
        func find(_ query: String, within: [String]) throws -> FindResult {
            let find = FindRequest(
                query: query,
                limit: 50,
                offset: 0,
                sort: .name,
                descending: false,
                includeHidden: false,
                within: within,
                kind: .any,
                waitSeconds: 15
            )
            let response = try sendQuery(.find(find), socketPath: socket, timeout: 30)
            guard case .found(let result) = response else {
                throw ExpectationFailure.failed("unexpected \(response)")
            }
            return result
        }
        let first = try find("brief", within: [])
        try expectEqual(first.entries.map(\.path), [root.path + "/Matters/2024/brief.docx"], "initial scan answered")
        try expect(first.index.exact, "exact after waiting")

        try writeFile(at: root.appendingPathComponent("Matters/2025/new motion.pdf"), contents: "m")
        let fresh = try find("motion", within: [root.appendingPathComponent("Matters").path])
        try expectEqual(fresh.total, 1, "file written just before the query is found")
        try expect(fresh.index.exact, "and the answer is exact")

        try FileManager.default.removeItem(at: root.appendingPathComponent("Matters/2024"))
        let gone = try find("brief", within: [])
        try expectEqual(gone.total, 0, "deleted just before the query")
        try expect(gone.index.exact, "exact no-match")

        let failure = try sendQuery(.find(FindRequest(
            query: "x", limit: 1, offset: 0, sort: .name, descending: false,
            includeHidden: false, within: ["/elsewhere"], kind: .any, waitSeconds: 0
        )), socketPath: socket, timeout: 10)
        guard case .failure = failure else {
            throw ExpectationFailure.failed("expected failure, got \(failure)")
        }
        let status = try sendQuery(.status, socketPath: socket, timeout: 10)
        guard case .status(let state) = status else {
            throw ExpectationFailure.failed("unexpected \(status)")
        }
        try expectEqual(state.owner, .daemon, "owner")
        try expectEqual(state.roots, [root.path], "roots")
        try expectEqual(try sendQuery(.shutdown, socketPath: socket, timeout: 10), .stopping, "daemon accepts shutdown")
        try expect(shutdownRequested, "shutdown callback ran")
    }

    suite.test("missing socket reports not running") {
        let home = try makeTempFolder("query-none")
        defer { try? FileManager.default.removeItem(at: home) }
        var notRunning = false
        do {
            _ = try sendQuery(.status, socketPath: querySocketPath(folder: home), timeout: 2)
        } catch QueryClientError.notRunning {
            notRunning = true
        }
        try expect(notRunning, "not running")
    }

    return suite
}
