import Foundation

func indexDataSuite() -> TestSuite {
    let suite = TestSuite(name: "IndexData")

    suite.test("folding ignores case, accents and normalization form") {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        try expectEqual(foldedBytes(composed), Array("cafe".utf8), "NFC")
        try expectEqual(foldedBytes(decomposed), Array("cafe".utf8), "NFD")
        try expectEqual(foldedBytes("REPORT-01.PDF"), Array("report-01.pdf".utf8), "ASCII")
        try expectEqual(foldedBytes("\u{00C9}COLE"), Array("ecole".utf8), "accented capital")
    }

    suite.test("paths, lookup and records") {
        let data = try buildTestIndex(rootPath: "/r", entries: [
            testFolder("/r/Projects"),
            testFile("/r/Projects/alpha.pdf", size: 10, modified: 5),
            testFolder("/r/Projects/deep"),
            testFile("/r/Projects/deep/beta.txt", size: 3, modified: 1)
        ])
        guard case .found(let beta) = data.lookup(path: "/r/Projects/deep/beta.txt") else {
            throw ExpectationFailure.failed("beta not found")
        }
        try expectEqual(data.fullPath(beta), "/r/Projects/deep/beta.txt", "full path")
        let record = data.record(beta)
        try expectEqual(record.parent, "/r/Projects/deep", "parent")
        try expectEqual(record.ext, "txt", "ext")
        try expectEqual(record.size, 3, "size")
        guard case .found(let root) = data.lookup(path: "/r") else {
            throw ExpectationFailure.failed("root not found")
        }
        try expectEqual(data.record(root).path, "/r", "root record path")
        guard case .missing(let ancestor) = data.lookup(path: "/r/Projects/new/thing") else {
            throw ExpectationFailure.failed("expected missing")
        }
        try expectEqual(data.fullPath(ancestor), "/r/Projects", "nearest ancestor")
        try expect(data.lookup(path: "/elsewhere/file") == .outsideRoots, "outside roots")
        try expect(data.lookup(path: "/rx") == .outsideRoots, "sibling prefix is outside")
    }

    suite.test("root slash builds clean paths") {
        var data = IndexData.empty()
        let root = try data.addRoot(path: "/", modified: 0)
        let users = try appendTestEntry(&data, parent: root, name: "Users", size: 0, modified: 0, flags: EntryFlag.directory)
        let file = try appendTestEntry(&data, parent: users, name: "a.txt", size: 1, modified: 0, flags: 0)
        try expectEqual(data.fullPath(file), "/Users/a.txt", "path under /")
        try expectEqual(data.record(users).parent, "/", "parent of top level")
        try expect(data.lookup(path: "/Users/a.txt") == .found(file), "lookup under /")
    }

    suite.test("parent ids always precede children") {
        let data = try buildTestIndex(rootPath: "/r", entries: [
            testFolder("/r/a"), testFolder("/r/a/b"), testFile("/r/a/b/c", size: 1, modified: 1)
        ])
        for index in 0..<data.count {
            try expect(data.parent[index] < Int32(index), "parent before child at \(index)")
        }
    }

    suite.test("hidden folders hide their contents") {
        let data = try buildTestIndex(rootPath: "/r", entries: [
            testFolder("/r/.git"),
            testFolder("/r/.git/objects"),
            testFile("/r/.git/objects/pack", size: 1, modified: 1),
            testFile("/r/visible.txt", size: 1, modified: 1)
        ])
        try expectEqual(searchNames(data, "file:", showHidden: false), ["visible.txt"], "hidden subtree omitted")
        try expectEqual(searchNames(data, "pack", showHidden: true), ["pack"], "shown when hidden allowed")
    }

    suite.test("subtree delete unlinks and counts") {
        var data = try buildTestIndex(rootPath: "/r", entries: [
            testFolder("/r/a"),
            testFile("/r/a/1", size: 1, modified: 1),
            testFolder("/r/a/b"),
            testFile("/r/a/b/2", size: 1, modified: 1),
            testFile("/r/keep", size: 1, modified: 1)
        ])
        guard case .found(let folder) = data.lookup(path: "/r/a") else {
            throw ExpectationFailure.failed("folder missing")
        }
        let before = data.liveCount
        let removed = data.removeEntry(folder)
        try expectEqual(removed, 4, "removed a, 1, b, 2")
        try expectEqual(data.liveCount, before - 4, "live count")
        try expectEqual(data.deletedCount, 4, "tombstones")
        guard case .missing = data.lookup(path: "/r/a/b/2") else {
            throw ExpectationFailure.failed("deleted path still found")
        }
        try expectEqual(searchNames(data, "", showHidden: true), ["keep", "r"], "only survivors")
    }

    suite.test("compaction keeps paths and drops tombstones") {
        var data = try buildTestIndex(rootPath: "/r", entries: [
            testFolder("/r/a"),
            testFile("/r/a/x.txt", size: 7, modified: 1),
            testFolder("/r/b"),
            testFile("/r/b/y.txt", size: 9, modified: 2)
        ])
        guard case .found(let folder) = data.lookup(path: "/r/a") else {
            throw ExpectationFailure.failed("folder missing")
        }
        _ = data.removeEntry(folder)
        let compacted = compactIndex(data)
        try expectEqual(compacted.count, 3, "root, b, y.txt")
        try expectEqual(compacted.deletedCount, 0, "no tombstones")
        try expectEqual(indexedTree(compacted), indexedTree(data), "same live tree")
        try expect(compacted.revision != data.revision, "revision changes")
        guard case .found(let y) = compacted.lookup(path: "/r/b/y.txt") else {
            throw ExpectationFailure.failed("y missing after compaction")
        }
        try expectEqual(compacted.size[Int(y)], 9, "metadata kept")
    }

    suite.test("appending under a deleted folder is rejected") {
        var data = try buildTestIndex(rootPath: "/r", entries: [testFolder("/r/a")])
        guard case .found(let folder) = data.lookup(path: "/r/a") else {
            throw ExpectationFailure.failed("folder missing")
        }
        _ = data.removeEntry(folder)
        var threw = false
        do {
            _ = try appendTestEntry(&data, parent: folder, name: "late", size: 0, modified: 0, flags: 0)
        } catch IndexDataError.invalidParent {
            threw = true
        }
        try expect(threw, "invalid parent error")
    }

    return suite
}
