import Foundation

/// Temporary folder resolved through symlinks (/tmp -> /private/tmp) so paths
/// match what the index stores.
func makeTempFolder(_ label: String) throws -> URL {
    let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("lumos-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let resolved = realpath(folder.path, nil) else {
        throw ExpectationFailure.failed("Could not resolve \(folder.path)")
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

func writeFile(at url: URL, contents: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let data = contents.data(using: .utf8) else {
        throw ExpectationFailure.failed("Could not encode \(url.lastPathComponent) as UTF-8")
    }
    try data.write(to: url)
}

struct TestEntry {
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Int64
    let hidden: Bool
}

func testFile(_ path: String, size: Int64, modified: Int64) -> TestEntry {
    return TestEntry(path: path, isDirectory: false, size: size, modified: modified, hidden: path.split(separator: "/").last?.hasPrefix(".") == true)
}

func testFolder(_ path: String) -> TestEntry {
    return TestEntry(path: path, isDirectory: true, size: 0, modified: 0, hidden: path.split(separator: "/").last?.hasPrefix(".") == true)
}

func appendTestEntry(_ data: inout IndexData, parent: Int32, name: String, size: Int64, modified: Int64, flags: UInt8) throws -> Int32 {
    var bytes = Array(name.utf8)
    return try bytes.withUnsafeMutableBufferPointer { buffer in
        try data.appendEntry(parent: parent, name: UnsafeBufferPointer(buffer), size: size, modified: modified, flags: flags)
    }
}

/// Synthetic index rooted at `rootPath`; parents must appear in `entries`
/// (or be the root) and are created before children by sorting.
func buildTestIndex(rootPath: String, entries: [TestEntry]) throws -> IndexData {
    var data = IndexData.empty()
    let rootId = try data.addRoot(path: rootPath, modified: 0)
    var folders: [String: Int32] = [rootPath: rootId]
    for entry in entries.sorted(by: { $0.path < $1.path }) {
        guard let parentId = folders[parentPath(entry.path)] else {
            throw ExpectationFailure.failed("missing parent for \(entry.path)")
        }
        var flags: UInt8 = entry.isDirectory ? EntryFlag.directory : 0
        if entry.hidden {
            flags |= EntryFlag.hidden
        }
        let id = try appendTestEntry(
            &data,
            parent: parentId,
            name: (entry.path as NSString).lastPathComponent,
            size: entry.size,
            modified: entry.modified,
            flags: flags
        )
        if entry.isDirectory {
            folders[entry.path] = id
        }
    }
    return data
}

func searchNames(_ data: IndexData, _ raw: String, showHidden: Bool) -> [String] {
    return searchIndex(data, query: parseQuery(raw), showHidden: showHidden, sortColumn: .name, ascending: true)
        .map { data.nameString($0) }
}

/// Indexes `folder` from scratch with the production scanner.
func scanFolder(_ folder: URL) throws -> IndexStore {
    let store = IndexStore(data: IndexData.empty())
    let rootId = try store.write { data in
        try data.addRoot(path: folder.path, modified: modificationTime(folder.path))
    }
    let finished = try runScan(
        store: store,
        tasks: [ScanTask(id: rootId, path: folder.path, rootPath: folder.path, mode: .fresh)],
        progress: ScanProgress(),
        threadCount: 4
    )
    try expect(finished, "scan finished")
    return store
}

/// Path -> (size, isDirectory) for every live entry, for comparing indexes.
func indexedTree(_ data: IndexData) -> [String: String] {
    var tree: [String: String] = [:]
    for index in 0..<data.count where data.isLive(Int32(index)) {
        let id = Int32(index)
        tree[data.fullPath(id)] = data.isDirectory(id) ? "dir" : "file:\(data.size[index])"
    }
    return tree
}

func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}
