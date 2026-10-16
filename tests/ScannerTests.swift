import Foundation

func scannerSuite() -> TestSuite {
    let suite = TestSuite(name: "Scanner")

    suite.test("lists names, sizes and kinds") {
        let root = try makeTempFolder("list")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(at: root.appendingPathComponent("five.txt"), contents: "12345")
        try writeFile(at: root.appendingPathComponent("sub/inner.txt"), contents: "x")
        try writeFile(at: root.appendingPathComponent("Cafe\u{0301}.md"), contents: "")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "five.txt")
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: listingBufferSize, alignment: 16)
        defer { buffer.deallocate() }
        let listing = try listDirectory(root.path, buffer: buffer)
        var byName: [String: Int] = [:]
        for index in 0..<listing.count {
            byName[listing.name(index)] = index
        }
        try expectEqual(Set(byName.keys), ["five.txt", "sub", "Cafe\u{0301}.md", "link"], "names")
        try expectEqual(listing.sizes[byName["five.txt"]!], 5, "size")
        try expect(listing.kinds[byName["sub"]!] == .directory, "directory kind")
        try expect(listing.kinds[byName["link"]!] == .symlink, "symlink kind")
    }

    suite.test("missing folder reports vanished") {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: listingBufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var vanished = false
        do {
            _ = try listDirectory("/tmp/lumos-missing-\(UUID().uuidString)", buffer: buffer)
        } catch ListingError.vanished {
            vanished = true
        }
        try expect(vanished, "vanished error")
    }

    suite.test("scan indexes files and applies skip rules") {
        let root = try makeTempFolder("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(at: root.appendingPathComponent("keep.txt"), contents: "ok")
        try writeFile(at: root.appendingPathComponent("sub/nested.pdf"), contents: "pdf")
        try writeFile(at: root.appendingPathComponent(".hidden"), contents: "dot")
        try writeFile(at: root.appendingPathComponent(".Trash/secret.txt"), contents: "no")
        try writeFile(at: root.appendingPathComponent("recents.sfl2"), contents: "sfl")
        try writeFile(at: root.appendingPathComponent("com.apple.sharedfilelist/RecentDocuments.sfl2"), contents: "sfl")
        try writeFile(at: root.appendingPathComponent("Tool.app/Contents/Info.plist"), contents: "plist")
        let store = try scanFolder(root)
        let names = store.read { data in Set(searchNames(data, "", showHidden: true)) }
        try expect(names.contains("keep.txt"), "keep")
        try expect(names.contains("nested.pdf"), "nested")
        try expect(names.contains(".hidden"), "hidden is indexed")
        try expect(names.contains("Tool.app"), "bundle itself is indexed")
        try expect(!names.contains("Info.plist"), "bundle contents are not")
        try expect(!names.contains("secret.txt") && !names.contains(".Trash"), "trash skipped")
        try expect(!names.contains("recents.sfl2"), "sfl skipped")
        try expect(!names.contains("RecentDocuments.sfl2"), "sharedfilelist skipped")
        let hidden = store.read { data in searchNames(data, ".hidden", showHidden: false) }
        try expect(hidden.isEmpty, "dotfile marked hidden")
    }

    suite.test("directory diff converges to a fresh scan") {
        let root = try makeTempFolder("diff")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(at: root.appendingPathComponent("a/one.txt"), contents: "1")
        try writeFile(at: root.appendingPathComponent("a/two.txt"), contents: "2")
        try writeFile(at: root.appendingPathComponent("b/deep/three.txt"), contents: "3")
        try writeFile(at: root.appendingPathComponent("c/gone.txt"), contents: "x")
        let store = try scanFolder(root)

        try FileManager.default.removeItem(at: root.appendingPathComponent("a/two.txt"))
        try writeFile(at: root.appendingPathComponent("a/one.txt"), contents: "longer contents")
        try writeFile(at: root.appendingPathComponent("a/new/fresh.txt"), contents: "new")
        try writeFile(at: root.appendingPathComponent("b/deep/four.txt"), contents: "4")
        try FileManager.default.removeItem(at: root.appendingPathComponent("c"))
        try writeFile(at: root.appendingPathComponent("c"), contents: "now a file")

        let tasks = store.read { data in
            resolveChangeTasks([
                root.appendingPathComponent("a").path: false,
                root.appendingPathComponent("b/deep").path: false,
                root.path: false
            ], data: data)
        }
        try expectEqual(tasks.count, 3, "three folders to diff")
        _ = try runScan(store: store, tasks: tasks, progress: ScanProgress(), threadCount: 4)
        let expected = try scanFolder(root).read { indexedTree($0) }
        try expectEqual(store.read { indexedTree($0) }, expected, "diffed index equals fresh scan")
    }

    suite.test("recursive diff finds deep changes") {
        let root = try makeTempFolder("recursive")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(at: root.appendingPathComponent("x/y/z/old.txt"), contents: "o")
        let store = try scanFolder(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("x/y/z/old.txt"))
        try writeFile(at: root.appendingPathComponent("x/y/z/new.txt"), contents: "n")
        let tasks = store.read { data in resolveChangeTasks([root.path: true], data: data) }
        try expectEqual(tasks.map(\.mode), [.diffRecursive], "one recursive task")
        _ = try runScan(store: store, tasks: tasks, progress: ScanProgress(), threadCount: 4)
        let expected = try scanFolder(root).read { indexedTree($0) }
        try expectEqual(store.read { indexedTree($0) }, expected, "matches fresh scan")
    }

    suite.test("vanished folder is removed from the index") {
        let root = try makeTempFolder("vanish")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(at: root.appendingPathComponent("doomed/a/b.txt"), contents: "b")
        let store = try scanFolder(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("doomed"))
        let tasks = store.read { data in
            resolveChangeTasks([root.appendingPathComponent("doomed/a").path: false], data: data)
        }
        _ = try runScan(store: store, tasks: tasks, progress: ScanProgress(), threadCount: 2)
        let names = store.read { data in searchNames(data, "", showHidden: true) }
        try expect(!names.contains("b.txt") && !names.contains("a"), "subtree gone: \(names)")
    }

    suite.test("change paths resolve to the right tasks") {
        let data = try buildTestIndex(rootPath: "/r", entries: [
            testFolder("/r/docs"),
            testFolder("/r/docs/sub"),
            testFolder("/r/Tool.app"),
            testFile("/r/docs/file.txt", size: 1, modified: 1)
        ])
        let fresh = resolveChangeTasks(["/r/docs/brand/new/deep": false], data: data)
        try expectEqual(fresh.map(\.path), ["/r/docs"], "new path diffs nearest indexed folder")
        let file = resolveChangeTasks(["/r/docs/file.txt": false], data: data)
        try expectEqual(file.map(\.path), ["/r/docs"], "file path diffs its folder")
        try expect(resolveChangeTasks(["/r/.Trash/x": false], data: data).isEmpty, "trash ignored")
        try expect(resolveChangeTasks(["/r/Tool.app/Contents": false], data: data).isEmpty, "bundle internals ignored")
        try expect(resolveChangeTasks(["/elsewhere": false], data: data).isEmpty, "outside roots ignored")
        let covered = resolveChangeTasks(["/r": true, "/r/docs/sub": false, "/r/docs": false], data: data)
        try expectEqual(covered.map(\.path), ["/r"], "recursive root covers descendants")
        let dropped = resolveChangeTasks(["/": true], data: data)
        try expectEqual(dropped.map(\.path), ["/r"], "dropped events above a root rescan the root")
    }

    suite.test("collapse path prefixes") {
        try expectEqual(
            collapsePathPrefixes(["/a/b", "/a", "/ab", "/a/b/c", "/z"]),
            ["/a", "/ab", "/z"],
            "keeps top-level paths only"
        )
    }

    return suite
}
