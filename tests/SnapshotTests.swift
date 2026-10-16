import Foundation

func snapshotSuite() -> TestSuite {
    let suite = TestSuite(name: "Snapshot")

    func sampleIndex() throws -> IndexData {
        return try buildTestIndex(rootPath: "/r", entries: [
            testFolder("/r/a"),
            testFile("/r/a/x.txt", size: 7, modified: 100),
            testFile("/r/a/Caf\u{00E9}.md", size: 3, modified: 200),
            testFolder("/r/.config"),
            testFile("/r/.config/settings", size: 1, modified: 300)
        ])
    }

    func meta(_ data: IndexData) -> SnapshotMeta {
        return SnapshotMeta(eventId: 42, roots: data.roots, volumeUUIDs: ["/r": "UUID"], rescanRoots: [], savedAt: 1)
    }

    suite.test("round trip keeps entries, flags and metadata") {
        let folder = try makeTempFolder("snapshot")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.lumos")
        let data = try sampleIndex()
        try writeSnapshot(data, meta: meta(data), to: url)
        let loaded = try readSnapshot(from: url)
        try expectEqual(indexedTree(loaded.data), indexedTree(data), "same tree")
        try expectEqual(loaded.meta.eventId, 42, "event id")
        try expectEqual(loaded.meta.volumeUUIDs["/r"], "UUID", "volume id")
        try expectEqual(searchNames(loaded.data, "file:", showHidden: false), ["Caf\u{00E9}.md", "x.txt"], "hidden flags survive")
        try expectEqual(searchNames(loaded.data, "cafe", showHidden: false), ["Caf\u{00E9}.md"], "folded names survive")
    }

    suite.test("tombstones must be compacted before saving") {
        let folder = try makeTempFolder("snapshot-dirty")
        defer { try? FileManager.default.removeItem(at: folder) }
        var data = try sampleIndex()
        guard case .found(let id) = data.lookup(path: "/r/a") else {
            throw ExpectationFailure.failed("missing folder")
        }
        _ = data.removeEntry(id)
        var rejected = false
        do {
            try writeSnapshot(data, meta: meta(data), to: folder.appendingPathComponent("index.lumos"))
        } catch SnapshotError.writeFailed {
            rejected = true
        }
        try expect(rejected, "uncompacted data rejected")
        let compacted = compactIndex(data)
        try writeSnapshot(compacted, meta: meta(compacted), to: folder.appendingPathComponent("index.lumos"))
        let loaded = try readSnapshot(from: folder.appendingPathComponent("index.lumos"))
        try expectEqual(indexedTree(loaded.data), indexedTree(data), "compacted round trip")
    }

    suite.test("corruption, truncation and version changes are detected") {
        let folder = try makeTempFolder("snapshot-bad")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.lumos")
        let data = try sampleIndex()
        try writeSnapshot(data, meta: meta(data), to: url)
        let original = try Data(contentsOf: url)

        var flipped = original
        flipped[original.count / 2] ^= 0xFF
        try flipped.write(to: url)
        var checksum = false
        do { _ = try readSnapshot(from: url) } catch SnapshotError.checksumMismatch { checksum = true }
        try expect(checksum, "flipped byte detected")

        try original.prefix(original.count - 20).write(to: url)
        var broken = false
        do { _ = try readSnapshot(from: url) } catch SnapshotError.checksumMismatch { broken = true } catch SnapshotError.truncated { broken = true }
        try expect(broken, "truncated file detected")

        var future = original
        future[8] = 99
        try future.write(to: url)
        var version = false
        do { _ = try readSnapshot(from: url) } catch SnapshotError.versionMismatch { version = true }
        try expect(version, "format version checked")

        var missing = false
        do { _ = try readSnapshot(from: folder.appendingPathComponent("nope.lumos")) } catch SnapshotError.missing { missing = true }
        try expect(missing, "missing file reported")
    }

    suite.test("service follows live changes and replays the journal after a restart") {
        let root = try makeTempFolder("service-root")
        let home = try makeTempFolder("service-home")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        try writeFile(at: root.appendingPathComponent("existing/start.txt"), contents: "s")
        func count(_ service: IndexService, _ query: String) -> Int {
            return service.store.read { data in
                searchIndex(data, query: parseQuery(query), showHidden: true, sortColumn: .name, ascending: true).count
            }
        }
        let first = IndexService(folder: home, roots: [root.path])
        try first.start()
        try expect(waitUntil(timeout: 20) { first.isIdle() && count(first, "start.txt") == 1 }, "initial scan")
        for index in 0..<200 {
            try writeFile(at: root.appendingPathComponent("live/batch/file-\(index).txt"), contents: "\(index)")
        }
        try expect(waitUntil(timeout: 20) { count(first, "path:live/batch file:") == 200 }, "live additions indexed")
        try FileManager.default.removeItem(at: root.appendingPathComponent("existing"))
        try expect(waitUntil(timeout: 20) { count(first, "start.txt") == 0 }, "live deletion indexed")
        first.stop()

        try FileManager.default.removeItem(at: root.appendingPathComponent("live/batch/file-0.txt"))
        try writeFile(at: root.appendingPathComponent("offline/deep/inside/added.txt"), contents: "a")
        let second = IndexService(folder: home, roots: [root.path])
        try second.start()
        try expect(waitUntil(timeout: 20) { count(second, "added.txt") == 1 }, "addition while stopped replayed")
        try expect(waitUntil(timeout: 20) { count(second, "path:live/batch file:") == 199 }, "deletion while stopped replayed")
        second.stop()
    }

    suite.test("clear and reindex rebuilds the index and snapshot from scratch") {
        let root = try makeTempFolder("clear-root")
        let home = try makeTempFolder("clear-home")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        for index in 0..<50 {
            try writeFile(at: root.appendingPathComponent("docs/sheet-\(index).txt"), contents: "\(index)")
        }
        let service = IndexService(folder: home, roots: [root.path])
        try service.start()
        defer { service.stop() }
        try expect(service.waitUntilExact(seconds: 20), "initial scan")
        let snapshot = home.appendingPathComponent("index.lumos")
        try expect(FileManager.default.fileExists(atPath: snapshot.path), "snapshot written after the first scan")
        let objectsBefore = service.store.read { $0.liveCount }
        let layoutBefore = service.store.layout

        service.clearAndReindex()
        try expect(waitUntil(timeout: 20) {
            service.store.layout != layoutBefore && service.isIdle() && service.status().phase == .live
        }, "rebuild finished")
        try expectEqual(service.store.read { $0.liveCount }, objectsBefore, "same objects after rebuild")
        try expect(service.status().message.contains("from scratch"), "status reports a from-scratch index")
        try expect(FileManager.default.fileExists(atPath: snapshot.path), "snapshot rewritten after the rebuild")
        try expect(service.waitUntilExact(seconds: 20), "exact after the rebuild")
    }

    return suite
}
