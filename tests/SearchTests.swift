import Foundation

func searchSuite() -> TestSuite {
    let suite = TestSuite(name: "Search")
    let now = Int64(Date().timeIntervalSince1970)

    func sample() throws -> IndexData {
        return try buildTestIndex(rootPath: "/Users/sample", entries: [
            testFolder("/Users/sample/Projects"),
            testFile("/Users/sample/Projects/alpha.pdf", size: 2_000_000, modified: now),
            testFile("/Users/sample/Projects/Caf\u{00E9} menu.txt", size: 40, modified: now - 86_400 * 30),
            testFile("/Users/sample/Projects/notes.PDF", size: 10, modified: now - 86_400 * 400),
            testFile("/Users/sample/.hidden", size: 120, modified: now),
            testFolder("/Users/sample/Archive.photoslibrary")
        ])
    }

    suite.test("ext search") {
        try expectEqual(searchNames(try sample(), "ext:pdf", showHidden: false), ["alpha.pdf", "notes.PDF"], "pdf")
    }

    suite.test("folders and files only") {
        let data = try sample()
        try expectEqual(searchNames(data, "folder:", showHidden: false), ["Archive.photoslibrary", "Projects", "sample"], "folders")
        try expectEqual(searchNames(data, "file: menu", showHidden: false), ["Caf\u{00E9} menu.txt"], "files")
    }

    suite.test("hidden filtered and included") {
        let data = try sample()
        try expect(!searchNames(data, "", showHidden: false).contains(".hidden"), "omitted")
        try expect(searchNames(data, "", showHidden: true).contains(".hidden"), "included")
    }

    suite.test("globs") {
        let data = try sample()
        try expectEqual(searchNames(data, "*.pdf", showHidden: false), ["alpha.pdf", "notes.PDF"], "extension glob")
        try expectEqual(searchNames(data, "al*", showHidden: false), ["alpha.pdf"], "prefix glob")
        try expectEqual(searchNames(data, "a?pha*", showHidden: false), ["alpha.pdf"], "raw glob")
        try expectEqual(searchNames(data, "*menu.txt", showHidden: false), ["Caf\u{00E9} menu.txt"], "suffix glob")
    }

    suite.test("OR and AND") {
        let data = try sample()
        try expectEqual(searchNames(data, "alpha|notes", showHidden: false), ["alpha.pdf", "notes.PDF"], "OR")
        try expect(searchNames(data, "alpha missing", showHidden: false).isEmpty, "AND miss")
        try expectEqual(searchNames(data, "al pdf", showHidden: false), ["alpha.pdf"], "AND hit")
    }

    suite.test("case and accent insensitive names") {
        let data = try sample()
        try expectEqual(searchNames(data, "ALPHA", showHidden: false), ["alpha.pdf"], "case")
        try expectEqual(searchNames(data, "cafe", showHidden: false), ["Caf\u{00E9} menu.txt"], "accent")
        try expectEqual(searchNames(data, "Cafe\u{0301}", showHidden: false), ["Caf\u{00E9} menu.txt"], "NFD query")
    }

    suite.test("path filter including folder boundaries") {
        let data = try sample()
        try expectEqual(
            searchNames(data, "path:Projects", showHidden: false),
            ["alpha.pdf", "Caf\u{00E9} menu.txt", "notes.PDF", "Projects"],
            "path contains folder"
        )
        try expectEqual(searchNames(data, "path:projects/al", showHidden: false), ["alpha.pdf"], "spans separator")
        try expectEqual(searchNames(data, "path:sample/projects", showHidden: false).count, 4, "spans folders")
        try expect(searchNames(data, "path:nowhere", showHidden: false).isEmpty, "no match")
    }

    suite.test("size and date filters") {
        let data = try sample()
        try expectEqual(searchNames(data, "size:>1mb", showHidden: false), ["alpha.pdf"], "large")
        try expectEqual(searchNames(data, "dm:today file:", showHidden: false), ["alpha.pdf"], "today")
    }

    suite.test("sort by size, date and path") {
        let data = try sample()
        func sorted(_ column: SortColumn, _ ascending: Bool) -> [String] {
            return searchIndex(data, query: parseQuery("file:"), showHidden: false, sortColumn: column, ascending: ascending)
                .map { data.nameString($0) }
        }
        try expectEqual(sorted(.size, false), ["alpha.pdf", "Caf\u{00E9} menu.txt", "notes.PDF"], "size desc")
        try expectEqual(sorted(.modified, true), ["notes.PDF", "Caf\u{00E9} menu.txt", "alpha.pdf"], "date asc")
        try expectEqual(sorted(.path, true), ["alpha.pdf", "Caf\u{00E9} menu.txt", "notes.PDF"], "path then name")
    }

    suite.test("name sort with long shared prefixes matches reference order") {
        var entries: [TestEntry] = [testFolder("/r/d")]
        var generator = SystemRandomNumberGenerator()
        for index in 0..<5000 {
            let stem = String(format: "report-%04d-%04d", Int.random(in: 0..<20, using: &generator), index)
            let suffix = ["txt", "PDF", "dat"][index % 3]
            entries.append(testFile("/r/d/\(stem).\(suffix)", size: Int64(index), modified: 0))
        }
        entries.append(testFile("/r/d/report", size: 0, modified: 0))
        entries.append(testFile("/r/d/Report-0000", size: 0, modified: 0))
        let data = try buildTestIndex(rootPath: "/r", entries: entries)
        let ids = searchIndex(data, query: parseQuery("report"), showHidden: true, sortColumn: .name, ascending: true)
        let names = ids.map { data.nameString($0) }
        let reference = names.sorted { left, right in
            let l = foldedBytes(left)
            let r = foldedBytes(right)
            return l == r ? Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8)) : l.lexicographicallyPrecedes(r)
        }
        try expectEqual(names.count, 5002, "all matched")
        try expect(names == reference, "radix order equals reference order")
        let descending = searchIndex(data, query: parseQuery("report"), showHidden: true, sortColumn: .name, ascending: false)
        try expect(descending == ids.reversed(), "descending is reversed")
    }

    suite.test("radix sort pairs") {
        var generator = SystemRandomNumberGenerator()
        for count in [3, 300, 70_000] {
            var keys = (0..<count).map { _ in UInt64.random(in: 0..<UInt64(count * 2), using: &generator) << 20 }
            var values = (0..<count).map { Int32($0) }
            let expected = zip(keys, values).sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            radixSortPairs(&keys, &values)
            try expectEqual(keys, expected.map(\.0), "keys sorted (\(count))")
            try expectEqual(values, expected.map(\.1), "stable values (\(count))")
        }
    }

    suite.test("deleted entries never match") {
        var data = try sample()
        guard case .found(let alpha) = data.lookup(path: "/Users/sample/Projects/alpha.pdf") else {
            throw ExpectationFailure.failed("alpha missing")
        }
        _ = data.removeEntry(alpha)
        try expect(searchNames(data, "alpha", showHidden: true).isEmpty, "gone")
    }

    return suite
}
