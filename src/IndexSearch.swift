import Darwin
import Foundation

enum SortColumn: String, Sendable {
    case name
    case path
    case size
    case modified
}

struct CompiledQuery {
    let nameGroups: [[[UInt8]]]
    let globs: [[CChar]]
    let prefixes: [[UInt8]]
    let suffixes: [[UInt8]]
    let extensions: [[UInt8]]
    let extensionPrefixes: [[UInt8]]
    let anyExtension: Bool
    let pathTerm: [UInt8]?
    let filesOnly: Bool
    let foldersOnly: Bool
    let minSize: Int64?
    let maxSize: Int64?
    let modifiedAfter: TimeInterval?
    let modifiedBefore: TimeInterval?
    let showHidden: Bool
}

func compileQuery(_ query: SearchQuery, showHidden: Bool) -> CompiledQuery {
    return CompiledQuery(
        nameGroups: query.nameOrGroups.map { group in group.map(foldedBytes) },
        globs: query.nameGlobs.map { glob in foldedBytes(glob).map { CChar(bitPattern: $0) } + [0] },
        prefixes: query.namePrefixes.map(foldedBytes),
        suffixes: query.nameSuffixes.map(foldedBytes),
        extensions: query.extensions.map(foldedBytes),
        extensionPrefixes: query.extensionPrefixes.map(foldedBytes),
        anyExtension: query.anyExtension,
        pathTerm: query.pathSubstring.map(foldedBytes),
        filesOnly: query.filesOnly,
        foldersOnly: query.foldersOnly,
        minSize: query.minSize,
        maxSize: query.maxSize,
        modifiedAfter: query.modifiedAfter,
        modifiedBefore: query.modifiedBefore,
        showHidden: showHidden
    )
}

func searchIndex(
    _ data: IndexData,
    query: SearchQuery,
    showHidden: Bool,
    sortColumn: SortColumn,
    ascending: Bool
) -> [Int32] {
    let compiled = compileQuery(query, showHidden: showHidden)
    let ids = matchingIds(data, query: compiled)
    return sortIds(ids, data: data, column: sortColumn, ascending: ascending)
}

/// Raw pointers into an `IndexData` that stay valid for the duration of a read.
struct IndexView {
    let count: Int
    let parent: UnsafeBufferPointer<Int32>
    let flags: UnsafeBufferPointer<UInt8>
    let nameStart: UnsafeBufferPointer<UInt32>
    let nameLength: UnsafeBufferPointer<UInt16>
    let names: UnsafeBufferPointer<UInt8>
    let foldStart: UnsafeBufferPointer<UInt32>
    let foldLength: UnsafeBufferPointer<UInt16>
    let folded: UnsafeBufferPointer<UInt8>
    let size: UnsafeBufferPointer<Int64>
    let modified: UnsafeBufferPointer<Int64>

    @inline(__always)
    func foldedName(_ index: Int) -> UnsafeBufferPointer<UInt8> {
        let start = Int(foldStart[index])
        return UnsafeBufferPointer(rebasing: folded[start..<(start + Int(foldLength[index]))])
    }

    @inline(__always)
    func originalName(_ index: Int) -> UnsafeBufferPointer<UInt8> {
        let start = Int(nameStart[index])
        return UnsafeBufferPointer(rebasing: names[start..<(start + Int(nameLength[index]))])
    }
}

func withIndexView<Result>(_ data: IndexData, _ body: (IndexView) -> Result) -> Result {
    return data.parent.withUnsafeBufferPointer { parent in
        data.flags.withUnsafeBufferPointer { flags in
            data.nameStart.withUnsafeBufferPointer { nameStart in
                data.nameLength.withUnsafeBufferPointer { nameLength in
                    data.names.withUnsafeBufferPointer { names in
                        data.foldStart.withUnsafeBufferPointer { foldStart in
                            data.foldLength.withUnsafeBufferPointer { foldLength in
                                data.folded.withUnsafeBufferPointer { folded in
                                    data.size.withUnsafeBufferPointer { size in
                                        data.modified.withUnsafeBufferPointer { modified in
                                            body(IndexView(
                                                count: data.count,
                                                parent: parent,
                                                flags: flags,
                                                nameStart: nameStart,
                                                nameLength: nameLength,
                                                names: names,
                                                foldStart: foldStart,
                                                foldLength: foldLength,
                                                folded: folded,
                                                size: size,
                                                modified: modified
                                            ))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@inline(__always)
func bytesContain(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
    if needle.isEmpty {
        return true
    }
    if haystack.count < needle.count {
        return false
    }
    return needle.withUnsafeBufferPointer { pattern in
        return memmem(haystack.baseAddress, haystack.count, pattern.baseAddress, pattern.count) != nil
    }
}

@inline(__always)
func bytesHavePrefix(_ haystack: UnsafeBufferPointer<UInt8>, _ prefix: [UInt8]) -> Bool {
    if prefix.count > haystack.count {
        return false
    }
    if prefix.isEmpty {
        return true
    }
    return prefix.withUnsafeBufferPointer { pattern in
        return memcmp(haystack.baseAddress!, pattern.baseAddress!, pattern.count) == 0
    }
}

@inline(__always)
func bytesHaveSuffix(_ haystack: UnsafeBufferPointer<UInt8>, _ suffix: [UInt8]) -> Bool {
    if suffix.count > haystack.count {
        return false
    }
    if suffix.isEmpty {
        return true
    }
    return suffix.withUnsafeBufferPointer { pattern in
        return memcmp(haystack.baseAddress! + (haystack.count - pattern.count), pattern.baseAddress!, pattern.count) == 0
    }
}

@inline(__always)
func bytesEqual(_ left: UnsafeBufferPointer<UInt8>, _ right: [UInt8]) -> Bool {
    return left.count == right.count && bytesHavePrefix(left, right)
}

/// Extension of a folded name: bytes after the last dot, ignoring a leading dot
/// (".zshrc") and a trailing dot ("name.").
@inline(__always)
func foldedExtension(_ name: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
    var index = name.count - 1
    while index > 0 {
        if name[index] == 0x2E {
            if index == name.count - 1 {
                break
            }
            return UnsafeBufferPointer(rebasing: name[(index + 1)...])
        }
        index -= 1
    }
    return UnsafeBufferPointer(rebasing: name[name.count...])
}

/// Folded full path of every live directory, plus whether it contains the path term.
struct PathMatchTable {
    let directoryMatches: [Bool]
    let paths: [UInt8]
    let pathStart: [UInt32]
    let pathLength: [UInt32]
}

func buildPathMatchTable(_ data: IndexData, view: IndexView, term: [UInt8]) -> PathMatchTable {
    var matches = [Bool](repeating: false, count: view.count)
    var pathStart = [UInt32](repeating: 0, count: view.count)
    var pathLength = [UInt32](repeating: 0, count: view.count)
    var paths: [UInt8] = []
    var rootFolded: [Int32: [UInt8]] = [:]
    for root in data.roots {
        rootFolded[root.entryId] = foldedBytes(root.path)
    }
    for index in 0..<view.count {
        let flags = view.flags[index]
        if flags & (EntryFlag.deleted | EntryFlag.directory) != EntryFlag.directory {
            continue
        }
        let start = paths.count
        if flags & EntryFlag.root != 0 {
            paths.append(contentsOf: rootFolded[Int32(index)] ?? [])
        } else {
            let parentIndex = Int(view.parent[index])
            let parentOffset = Int(pathStart[parentIndex])
            let parentCount = Int(pathLength[parentIndex])
            paths.reserveCapacity(paths.count + parentCount + 1 + Int(view.foldLength[index]))
            for offset in parentOffset..<(parentOffset + parentCount) {
                paths.append(paths[offset])
            }
            if parentCount == 0 || paths[paths.count - 1] != 0x2F {
                paths.append(0x2F)
            }
            paths.append(contentsOf: view.foldedName(index))
        }
        pathStart[index] = UInt32(start)
        pathLength[index] = UInt32(paths.count - start)
        matches[index] = paths.withUnsafeBufferPointer { buffer in
            bytesContain(UnsafeBufferPointer(rebasing: buffer[start..<buffer.count]), term)
        }
    }
    return PathMatchTable(directoryMatches: matches, paths: paths, pathStart: pathStart, pathLength: pathLength)
}

/// Needle bytes owned by a `MatchArena`; trivially copyable so the hot scan
/// loop never touches reference counts (shared refcounts across scan threads
/// cause cache-line contention that dwarfs the actual matching work).
struct RawNeedle {
    let base: UnsafePointer<UInt8>
    let count: Int
}

final class MatchArena {
    private var blocks: [UnsafeMutableRawPointer] = []

    func needle(_ bytes: [UInt8]) -> RawNeedle {
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, bytes.count))
        pointer.initialize(from: bytes, count: bytes.count)
        blocks.append(UnsafeMutableRawPointer(pointer))
        return RawNeedle(base: UnsafePointer(pointer), count: bytes.count)
    }

    func cString(_ bytes: [CChar]) -> UnsafePointer<CChar> {
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: max(1, bytes.count))
        pointer.initialize(from: bytes, count: bytes.count)
        blocks.append(UnsafeMutableRawPointer(pointer))
        return UnsafePointer(pointer)
    }

    func list<Element>(_ items: [Element]) -> UnsafeBufferPointer<Element> {
        let pointer = UnsafeMutablePointer<Element>.allocate(capacity: max(1, items.count))
        pointer.initialize(from: items, count: items.count)
        blocks.append(UnsafeMutableRawPointer(pointer))
        return UnsafeBufferPointer(start: pointer, count: items.count)
    }

    deinit {
        for block in blocks {
            block.deallocate()
        }
    }
}

struct MatchProgram {
    let groups: UnsafeBufferPointer<UnsafeBufferPointer<RawNeedle>>
    let globs: UnsafeBufferPointer<UnsafePointer<CChar>>
    let prefixes: UnsafeBufferPointer<RawNeedle>
    let suffixes: UnsafeBufferPointer<RawNeedle>
    let extensions: UnsafeBufferPointer<RawNeedle>
    let extensionPrefixes: UnsafeBufferPointer<RawNeedle>
    let anyExtension: Bool
    let pathTerm: RawNeedle?
    let filesOnly: Bool
    let foldersOnly: Bool
    let minSize: Int64
    let maxSize: Int64
    let modifiedAfter: Double
    let modifiedBefore: Double
    let showHidden: Bool

    var checksExtension: Bool {
        return anyExtension || !extensions.isEmpty || !extensionPrefixes.isEmpty
    }
}

func makeMatchProgram(_ query: CompiledQuery, arena: MatchArena) -> MatchProgram {
    return MatchProgram(
        groups: arena.list(query.nameGroups.map { group in arena.list(group.map(arena.needle)) }),
        globs: arena.list(query.globs.map(arena.cString)),
        prefixes: arena.list(query.prefixes.map(arena.needle)),
        suffixes: arena.list(query.suffixes.map(arena.needle)),
        extensions: arena.list(query.extensions.map(arena.needle)),
        extensionPrefixes: arena.list(query.extensionPrefixes.map(arena.needle)),
        anyExtension: query.anyExtension,
        pathTerm: query.pathTerm.map(arena.needle),
        filesOnly: query.filesOnly,
        foldersOnly: query.foldersOnly,
        minSize: query.minSize ?? Int64.min,
        maxSize: query.maxSize ?? Int64.max,
        modifiedAfter: query.modifiedAfter ?? -Double.infinity,
        modifiedBefore: query.modifiedBefore ?? Double.infinity,
        showHidden: query.showHidden
    )
}

@inline(__always)
private func rawContains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: RawNeedle) -> Bool {
    if needle.count == 0 {
        return true
    }
    if haystack.count < needle.count {
        return false
    }
    return memmem(haystack.baseAddress, haystack.count, needle.base, needle.count) != nil
}

@inline(__always)
private func rawHasPrefix(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: RawNeedle) -> Bool {
    if needle.count == 0 {
        return true
    }
    return haystack.count >= needle.count && memcmp(haystack.baseAddress!, needle.base, needle.count) == 0
}

@inline(__always)
private func rawHasSuffix(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: RawNeedle) -> Bool {
    if needle.count == 0 {
        return true
    }
    return haystack.count >= needle.count
        && memcmp(haystack.baseAddress! + (haystack.count - needle.count), needle.base, needle.count) == 0
}

/// Raw view of a `PathMatchTable` for the scan loop.
struct PathTableView {
    let directoryMatches: UnsafeBufferPointer<Bool>
    let paths: UnsafeBufferPointer<UInt8>
    let pathStart: UnsafeBufferPointer<UInt32>
    let pathLength: UnsafeBufferPointer<UInt32>
}

private func pathTermMatches(
    index: Int,
    view: IndexView,
    table: PathTableView,
    term: RawNeedle,
    scratch: UnsafeMutablePointer<UInt8>
) -> Bool {
    if view.flags[index] & EntryFlag.directory != 0 {
        return table.directoryMatches[index]
    }
    let parentIndex = Int(view.parent[index])
    if table.directoryMatches[parentIndex] {
        return true
    }
    let name = view.foldedName(index)
    if rawContains(name, term) {
        return true
    }
    if term.count < 2 {
        return false
    }
    let tailCount = min(term.count - 1, Int(table.pathLength[parentIndex]))
    let tailEnd = Int(table.pathStart[parentIndex] + table.pathLength[parentIndex])
    var length = 0
    for offset in (tailEnd - tailCount)..<tailEnd {
        scratch[length] = table.paths[offset]
        length += 1
    }
    if length == 0 || scratch[length - 1] != 0x2F {
        scratch[length] = 0x2F
        length += 1
    }
    for offset in 0..<min(term.count - 1, name.count) {
        scratch[length] = name[offset]
        length += 1
    }
    return rawContains(UnsafeBufferPointer(start: scratch, count: length), term)
}

@inline(__always)
private func entryMatches(
    index: Int,
    view: IndexView,
    program: MatchProgram,
    pathTable: PathTableView,
    globScratch: UnsafeMutablePointer<CChar>,
    pathScratch: UnsafeMutablePointer<UInt8>
) -> Bool {
    let flags = view.flags[index]
    if flags & EntryFlag.deleted != 0 {
        return false
    }
    if !program.showHidden && flags & EntryFlag.hidden != 0 {
        return false
    }
    let isDirectory = flags & EntryFlag.directory != 0
    if (program.filesOnly && isDirectory) || (program.foldersOnly && !isDirectory) {
        return false
    }
    let size = view.size[index]
    if size < program.minSize || size > program.maxSize {
        return false
    }
    let modified = Double(view.modified[index])
    if modified < program.modifiedAfter || modified >= program.modifiedBefore {
        return false
    }
    let name = view.foldedName(index)
    if program.checksExtension {
        let ext = foldedExtension(name)
        if program.anyExtension && ext.isEmpty {
            return false
        }
        if !program.extensions.isEmpty {
            var found = false
            for needle in program.extensions where ext.count == needle.count && rawHasPrefix(ext, needle) {
                found = true
                break
            }
            if !found {
                return false
            }
        }
        if !program.extensionPrefixes.isEmpty {
            var found = false
            for needle in program.extensionPrefixes where rawHasPrefix(ext, needle) {
                found = true
                break
            }
            if !found {
                return false
            }
        }
    }
    for needle in program.prefixes where !rawHasPrefix(name, needle) {
        return false
    }
    for needle in program.suffixes where !rawHasSuffix(name, needle) {
        return false
    }
    for group in program.groups {
        var found = false
        for needle in group where rawContains(name, needle) {
            found = true
            break
        }
        if !found {
            return false
        }
    }
    if !program.globs.isEmpty {
        for offset in 0..<name.count {
            globScratch[offset] = CChar(bitPattern: name[offset])
        }
        globScratch[name.count] = 0
        for glob in program.globs where fnmatch(glob, globScratch, 0) != 0 {
            return false
        }
    }
    if let term = program.pathTerm {
        if !pathTermMatches(index: index, view: view, table: pathTable, term: term, scratch: pathScratch) {
            return false
        }
    }
    return true
}

func matchingIds(_ data: IndexData, query: CompiledQuery) -> [Int32] {
    let count = data.count
    if count == 0 {
        return []
    }
    let arena = MatchArena()
    let program = makeMatchProgram(query, arena: arena)
    let pathScratchSize = (query.pathTerm?.count ?? 0) * 2 + 2
    return withExtendedLifetime(arena) {
        withIndexView(data) { view in
            let table = query.pathTerm.map { buildPathMatchTable(data, view: view, term: $0) }
                ?? PathMatchTable(directoryMatches: [], paths: [], pathStart: [], pathLength: [])
            return table.directoryMatches.withUnsafeBufferPointer { directoryMatches in
                table.paths.withUnsafeBufferPointer { paths in
                    table.pathStart.withUnsafeBufferPointer { pathStart in
                        table.pathLength.withUnsafeBufferPointer { pathLength in
                            let tableView = PathTableView(
                                directoryMatches: directoryMatches,
                                paths: paths,
                                pathStart: pathStart,
                                pathLength: pathLength
                            )
                            return scanChunks(count: count) { low, high, output in
                                let globScratch = UnsafeMutablePointer<CChar>.allocate(capacity: Int(UInt16.max) + 1)
                                let pathScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: pathScratchSize)
                                defer {
                                    globScratch.deallocate()
                                    pathScratch.deallocate()
                                }
                                for index in low..<high where entryMatches(
                                    index: index,
                                    view: view,
                                    program: program,
                                    pathTable: tableView,
                                    globScratch: globScratch,
                                    pathScratch: pathScratch
                                ) {
                                    output.append(Int32(index))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Splits `0..<count` into chunks scanned in parallel; results stay in id order.
private func scanChunks(count: Int, body: (Int, Int, inout [Int32]) -> Void) -> [Int32] {
    let chunkCount = max(1, min(256, count / 8192))
    var partial = [[Int32]](repeating: [], count: chunkCount)
    partial.withUnsafeMutableBufferPointer { output in
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            var local: [Int32] = []
            body(chunk * count / chunkCount, (chunk + 1) * count / chunkCount, &local)
            output[chunk] = local
        }
    }
    var result: [Int32] = []
    result.reserveCapacity(partial.reduce(0) { $0 + $1.count })
    for chunk in partial {
        result.append(contentsOf: chunk)
    }
    return result
}

// MARK: - Sorting

func sortIds(_ ids: [Int32], data: IndexData, column: SortColumn, ascending: Bool) -> [Int32] {
    if ids.count < 2 {
        return ids
    }
    var order = ids
    withIndexView(data) { view in
        switch column {
        case .name:
            order.withUnsafeMutableBufferPointer { buffer in
                sortRangeByName(buffer, low: 0, high: buffer.count, depth: 0, view: view)
            }
        case .size:
            var keys = ids.map { UInt64(max(0, view.size[Int($0)])) }
            sortByKeysThenName(&keys, &order, view: view)
        case .modified:
            var keys = ids.map { UInt64(bitPattern: view.modified[Int($0)]) ^ (1 << 63) }
            sortByKeysThenName(&keys, &order, view: view)
        case .path:
            var keys = parentPathRanks(ids, data: data, view: view)
            sortByKeysThenName(&keys, &order, view: view)
        }
    }
    if !ascending {
        order.reverse()
    }
    return order
}

private func sortByKeysThenName(_ keys: inout [UInt64], _ order: inout [Int32], view: IndexView) {
    radixSortPairs(&keys, &order)
    order.withUnsafeMutableBufferPointer { buffer in
        var start = 0
        while start < keys.count {
            var end = start + 1
            while end < keys.count && keys[end] == keys[start] {
                end += 1
            }
            if end - start > 1 {
                sortRangeByName(buffer, low: start, high: end, depth: 0, view: view)
            }
            start = end
        }
    }
}

private func parentPathRanks(_ ids: [Int32], data: IndexData, view: IndexView) -> [UInt64] {
    var parents: [Int32] = []
    var seen = Set<Int32>()
    for id in ids {
        let parentId = view.parent[Int(id)]
        if parentId >= 0 && seen.insert(parentId).inserted {
            parents.append(parentId)
        }
    }
    let paths = parents.map { foldedPathBytes($0, data: data, view: view) }
    let sortedSlots = paths.indices.sorted { left, right in
        return paths[left].lexicographicallyPrecedes(paths[right])
    }
    var rank: [Int32: UInt64] = [:]
    rank.reserveCapacity(parents.count)
    for (position, slot) in sortedSlots.enumerated() {
        rank[parents[slot]] = UInt64(position + 1)
    }
    return ids.map { id in
        let parentId = view.parent[Int(id)]
        return parentId >= 0 ? (rank[parentId] ?? 0) : 0
    }
}

private func foldedPathBytes(_ id: Int32, data: IndexData, view: IndexView) -> [UInt8] {
    var chain: [Int] = []
    var current = Int(id)
    while current >= 0 && view.flags[current] & EntryFlag.root == 0 {
        chain.append(current)
        current = Int(view.parent[current])
    }
    var path = current >= 0 ? foldedBytes(data.rootPath(of: Int32(current)) ?? "") : []
    for index in chain.reversed() {
        if path.last != 0x2F {
            path.append(0x2F)
        }
        path.append(contentsOf: view.foldedName(index))
    }
    return path
}

@inline(__always)
private func nameChunk(_ name: UnsafeBufferPointer<UInt8>, depth: Int) -> UInt64 {
    let start = depth * 8
    var key: UInt64 = 0
    for offset in 0..<8 {
        let position = start + offset
        let byte: UInt64 = position < name.count ? UInt64(name[position]) : 0
        key = (key << 8) | byte
    }
    return key
}

private func compareNames(_ left: Int32, _ right: Int32, view: IndexView) -> Bool {
    let leftName = view.foldedName(Int(left))
    let rightName = view.foldedName(Int(right))
    let common = min(leftName.count, rightName.count)
    if common > 0 {
        let result = memcmp(leftName.baseAddress!, rightName.baseAddress!, common)
        if result != 0 {
            return result < 0
        }
    }
    if leftName.count != rightName.count {
        return leftName.count < rightName.count
    }
    let leftOriginal = view.originalName(Int(left))
    let rightOriginal = view.originalName(Int(right))
    if !leftOriginal.elementsEqual(rightOriginal) {
        return leftOriginal.lexicographicallyPrecedes(rightOriginal)
    }
    return left < right
}

/// MSD radix sort on 8-byte chunks of the folded name, so long shared prefixes
/// ("report-0001-…", dated file names) cost one pass per chunk instead of
/// O(n log n) full string comparisons.
private func sortRangeByName(
    _ order: UnsafeMutableBufferPointer<Int32>,
    low: Int,
    high: Int,
    depth: Int,
    view: IndexView
) {
    let count = high - low
    if count < 2 {
        return
    }
    if count <= 48 {
        var slice = UnsafeMutableBufferPointer(rebasing: order[low..<high])
        slice.sort { compareNames($0, $1, view: view) }
        return
    }
    var keys = [UInt64](repeating: 0, count: count)
    var values = [Int32](repeating: 0, count: count)
    for offset in 0..<count {
        let id = order[low + offset]
        values[offset] = id
        keys[offset] = nameChunk(view.foldedName(Int(id)), depth: depth)
    }
    radixSortPairs(&keys, &values)
    for offset in 0..<count {
        order[low + offset] = values[offset]
    }
    var start = 0
    while start < count {
        var end = start + 1
        while end < count && keys[end] == keys[start] {
            end += 1
        }
        if end - start > 1 {
            if keys[start] & 0xFF != 0 {
                sortRangeByName(order, low: low + start, high: low + end, depth: depth + 1, view: view)
            } else {
                var slice = UnsafeMutableBufferPointer(rebasing: order[(low + start)..<(low + end)])
                slice.sort { compareNames($0, $1, view: view) }
            }
        }
        start = end
    }
}

/// Stable LSD radix sort of `keys`, permuting `values` alongside. Uses 8-bit
/// digits for small inputs and 16-bit digits for large ones; passes where every
/// key shares the digit are skipped.
func radixSortPairs(_ keys: inout [UInt64], _ values: inout [Int32]) {
    let count = keys.count
    if count < 2 {
        return
    }
    if count <= 256 {
        let order = (0..<count).sorted { left, right in
            return keys[left] != keys[right] ? keys[left] < keys[right] : left < right
        }
        keys = order.map { keys[$0] }
        values = order.map { values[$0] }
        return
    }
    let digitBits = count < 65536 ? 8 : 16
    let bucketCount = 1 << digitBits
    let mask = UInt64(bucketCount - 1)
    var keyScratch = [UInt64](repeating: 0, count: count)
    var valueScratch = [Int32](repeating: 0, count: count)
    var counts = [Int](repeating: 0, count: bucketCount)
    for shift in stride(from: 0, to: 64, by: digitBits) {
        for index in 0..<bucketCount {
            counts[index] = 0
        }
        for key in keys {
            counts[Int((key >> UInt64(shift)) & mask)] += 1
        }
        if counts.contains(count) {
            continue
        }
        var total = 0
        for index in 0..<bucketCount {
            let bucket = counts[index]
            counts[index] = total
            total += bucket
        }
        keys.withUnsafeBufferPointer { sourceKeys in
            values.withUnsafeBufferPointer { sourceValues in
                keyScratch.withUnsafeMutableBufferPointer { targetKeys in
                    valueScratch.withUnsafeMutableBufferPointer { targetValues in
                        counts.withUnsafeMutableBufferPointer { offsets in
                            for index in 0..<count {
                                let key = sourceKeys[index]
                                let digit = Int((key >> UInt64(shift)) & mask)
                                let position = offsets[digit]
                                offsets[digit] = position + 1
                                targetKeys[position] = key
                                targetValues[position] = sourceValues[index]
                            }
                        }
                    }
                }
            }
        }
        swap(&keys, &keyScratch)
        swap(&values, &valueScratch)
    }
}
