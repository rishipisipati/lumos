import Foundation

enum EntryFlag {
    static let directory: UInt8 = 1 << 0
    static let hidden: UInt8 = 1 << 1
    static let symlink: UInt8 = 1 << 2
    static let deleted: UInt8 = 1 << 3
    static let opaque: UInt8 = 1 << 4
    static let root: UInt8 = 1 << 5
}

struct IndexRoot: Equatable, Codable, Sendable {
    let path: String
    let entryId: Int32
}

enum PathLookup: Equatable {
    case found(Int32)
    case missing(ancestor: Int32)
    case outsideRoots
}

enum IndexDataError: Error, LocalizedError {
    case capacityExceeded(String)
    case invalidParent(Int32)

    var errorDescription: String? {
        switch self {
        case .capacityExceeded(let detail):
            return "The Lumos index is full: \(detail)"
        case .invalidParent(let id):
            return "Internal index error: entry \(id) is not a live folder."
        }
    }
}

/// Struct-of-arrays file index. Entry ids are array positions. A parent is always
/// inserted before its children, so `parent[id] < id` holds for every entry and
/// whole-index computations can run as single forward passes.
struct IndexData {
    var parent: [Int32]
    var firstChild: [Int32]
    var nextSibling: [Int32]
    var nameStart: [UInt32]
    var nameLength: [UInt16]
    var foldStart: [UInt32]
    var foldLength: [UInt16]
    var size: [Int64]
    var modified: [Int64]
    var flags: [UInt8]
    var names: [UInt8]
    var folded: [UInt8]
    var roots: [IndexRoot]
    var liveCount: Int
    var deletedCount: Int
    var revision: UInt64

    static func empty() -> IndexData {
        return IndexData(
            parent: [],
            firstChild: [],
            nextSibling: [],
            nameStart: [],
            nameLength: [],
            foldStart: [],
            foldLength: [],
            size: [],
            modified: [],
            flags: [],
            names: [],
            folded: [],
            roots: [],
            liveCount: 0,
            deletedCount: 0,
            revision: 0
        )
    }

    var count: Int {
        return parent.count
    }

    func isLive(_ id: Int32) -> Bool {
        return id >= 0 && Int(id) < parent.count && flags[Int(id)] & EntryFlag.deleted == 0
    }

    func isDirectory(_ id: Int32) -> Bool {
        return flags[Int(id)] & EntryFlag.directory != 0
    }

    func nameString(_ id: Int32) -> String {
        let index = Int(id)
        let start = Int(nameStart[index])
        let length = Int(nameLength[index])
        return names.withUnsafeBufferPointer { buffer in
            return String(decoding: UnsafeBufferPointer(rebasing: buffer[start..<(start + length)]), as: UTF8.self)
        }
    }

    func rootPath(of rootId: Int32) -> String? {
        for root in roots where root.entryId == rootId {
            return root.path
        }
        return nil
    }

    func fullPath(_ id: Int32) -> String {
        var chain: [Int32] = []
        var current = id
        while current >= 0 {
            if flags[Int(current)] & EntryFlag.root != 0 {
                break
            }
            chain.append(current)
            current = parent[Int(current)]
        }
        var path = current >= 0 ? (rootPath(of: current) ?? "") : ""
        for component in chain.reversed() {
            if !path.hasSuffix("/") {
                path += "/"
            }
            path += nameString(component)
        }
        return path
    }

    func parentPathString(_ id: Int32) -> String {
        if flags[Int(id)] & EntryFlag.root != 0 {
            return parentPath(rootPath(of: id) ?? "/")
        }
        return fullPath(parent[Int(id)])
    }

    func record(_ id: Int32) -> FileRecord {
        let index = Int(id)
        let name = nameString(id)
        let parentString = parentPathString(id)
        let path: String
        if flags[index] & EntryFlag.root != 0 {
            path = rootPath(of: id) ?? name
        } else {
            path = parentString.hasSuffix("/") ? parentString + name : parentString + "/" + name
        }
        let isDirectory = flags[index] & EntryFlag.directory != 0
        return FileRecord(
            path: path,
            name: name,
            parent: parentString,
            size: size[index],
            modified: TimeInterval(modified[index]),
            isDirectory: isDirectory,
            ext: fileExtension(fromName: name),
            isHidden: flags[index] & EntryFlag.hidden != 0
        )
    }

    func children(of id: Int32) -> [Int32] {
        var result: [Int32] = []
        var child = firstChild[Int(id)]
        while child >= 0 {
            result.append(child)
            child = nextSibling[Int(child)]
        }
        return result
    }

    func nameEquals(_ id: Int32, _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let index = Int(id)
        let length = Int(nameLength[index])
        if length != bytes.count {
            return false
        }
        if length == 0 {
            return true
        }
        let start = Int(nameStart[index])
        return names.withUnsafeBufferPointer { buffer in
            return memcmp(buffer.baseAddress! + start, bytes.baseAddress!, length) == 0
        }
    }

    func childNamed(_ name: Substring, in parentId: Int32) -> Int32? {
        var utf8 = Array(name.utf8)
        return utf8.withUnsafeMutableBufferPointer { mutable in
            let bytes = UnsafeBufferPointer(mutable)
            var child = firstChild[Int(parentId)]
            while child >= 0 {
                if nameEquals(child, bytes) {
                    return child
                }
                child = nextSibling[Int(child)]
            }
            return nil
        }
    }

    func rootContaining(_ path: String) -> IndexRoot? {
        var best: IndexRoot?
        for root in roots where pathIsInside(path, root: root.path) {
            if best == nil || root.path.count > best!.path.count {
                best = root
            }
        }
        return best
    }

    func lookup(path: String) -> PathLookup {
        guard let root = rootContaining(path) else {
            return .outsideRoots
        }
        if path == root.path {
            return .found(root.entryId)
        }
        let rest = root.path == "/" ? path.dropFirst(1) : path.dropFirst(root.path.count + 1)
        var current = root.entryId
        for component in rest.split(separator: "/") {
            guard let child = childNamed(component, in: current) else {
                return .missing(ancestor: current)
            }
            current = child
        }
        return .found(current)
    }

    mutating func addRoot(path: String, modified rootModified: Int64) throws -> Int32 {
        let id = try reserveId()
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        var utf8 = Array(name.utf8)
        try utf8.withUnsafeMutableBufferPointer { mutable in
            try appendName(UnsafeBufferPointer(mutable))
        }
        parent.append(-1)
        firstChild.append(-1)
        nextSibling.append(-1)
        size.append(0)
        modified.append(rootModified)
        flags.append(EntryFlag.directory | EntryFlag.root)
        roots.append(IndexRoot(path: path, entryId: id))
        liveCount += 1
        revision &+= 1
        return id
    }

    mutating func appendEntry(
        parent parentId: Int32,
        name: UnsafeBufferPointer<UInt8>,
        size entrySize: Int64,
        modified entryModified: Int64,
        flags entryFlags: UInt8
    ) throws -> Int32 {
        let parentIndex = Int(parentId)
        if parentId < 0 || parentIndex >= parent.count
            || flags[parentIndex] & (EntryFlag.deleted | EntryFlag.directory) != EntryFlag.directory {
            throw IndexDataError.invalidParent(parentId)
        }
        let id = try reserveId()
        try appendName(name)
        parent.append(parentId)
        firstChild.append(-1)
        nextSibling.append(firstChild[parentIndex])
        firstChild[parentIndex] = id
        size.append(entrySize)
        modified.append(entryModified)
        flags.append(entryFlags | (flags[parentIndex] & EntryFlag.hidden))
        liveCount += 1
        revision &+= 1
        return id
    }

    mutating func updateEntry(_ id: Int32, size entrySize: Int64, modified entryModified: Int64) {
        let index = Int(id)
        size[index] = entrySize
        modified[index] = entryModified
        revision &+= 1
    }

    /// Marks `start` and all descendants deleted. Callers must then call
    /// `pruneDeletedChildren(of:)` on the parent to unlink it.
    mutating func markSubtreeDeleted(_ start: Int32) -> Int {
        var removed = 0
        var stack: [Int32] = [start]
        while let id = stack.popLast() {
            let index = Int(id)
            if flags[index] & EntryFlag.deleted != 0 {
                continue
            }
            flags[index] |= EntryFlag.deleted
            removed += 1
            var child = firstChild[index]
            while child >= 0 {
                stack.append(child)
                child = nextSibling[Int(child)]
            }
            firstChild[index] = -1
        }
        liveCount -= removed
        deletedCount += removed
        if removed > 0 {
            revision &+= 1
        }
        return removed
    }

    mutating func pruneDeletedChildren(of parentId: Int32) {
        let parentIndex = Int(parentId)
        var head: Int32 = -1
        var tail: Int32 = -1
        var child = firstChild[parentIndex]
        while child >= 0 {
            let next = nextSibling[Int(child)]
            if flags[Int(child)] & EntryFlag.deleted == 0 {
                nextSibling[Int(child)] = -1
                if tail < 0 {
                    head = child
                } else {
                    nextSibling[Int(tail)] = child
                }
                tail = child
            }
            child = next
        }
        firstChild[parentIndex] = head
    }

    mutating func removeEntry(_ id: Int32) -> Int {
        let removed = markSubtreeDeleted(id)
        let parentId = parent[Int(id)]
        if parentId >= 0 {
            pruneDeletedChildren(of: parentId)
        } else {
            roots.removeAll { $0.entryId == id }
        }
        return removed
    }

    private func reserveId() throws -> Int32 {
        if parent.count >= Int(Int32.max) {
            throw IndexDataError.capacityExceeded("more than \(Int32.max) entries")
        }
        return Int32(parent.count)
    }

    private mutating func appendName(_ name: UnsafeBufferPointer<UInt8>) throws {
        if name.count > Int(UInt16.max) {
            throw IndexDataError.capacityExceeded("a file name is longer than \(UInt16.max) bytes")
        }
        if names.count + name.count > Int(UInt32.max) || folded.count + name.count * 3 > Int(UInt32.max) {
            throw IndexDataError.capacityExceeded("file names exceed 4 GB")
        }
        nameStart.append(UInt32(names.count))
        nameLength.append(UInt16(name.count))
        names.append(contentsOf: name)
        let start = folded.count
        appendFoldedName(name, to: &folded)
        let length = folded.count - start
        if length > Int(UInt16.max) {
            throw IndexDataError.capacityExceeded("a folded file name is longer than \(UInt16.max) bytes")
        }
        foldStart.append(UInt32(start))
        foldLength.append(UInt16(length))
    }
}

func pathIsInside(_ path: String, root: String) -> Bool {
    if root == "/" {
        return path.hasPrefix("/")
    }
    return path == root || path.hasPrefix(root + "/")
}

func parentPath(_ path: String) -> String {
    if path == "/" {
        return "/"
    }
    var trimmed = path
    if trimmed.count > 1 && trimmed.hasSuffix("/") {
        trimmed = String(trimmed.dropLast())
    }
    return (trimmed as NSString).deletingLastPathComponent
}

/// Case-, diacritic- and width-insensitive form used for matching. NFC and NFD
/// spellings of the same name fold to identical bytes.
func foldString(_ value: String) -> String {
    return value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
}

func foldedBytes(_ value: String) -> [UInt8] {
    var utf8 = Array(value.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(utf8.count)
    utf8.withUnsafeMutableBufferPointer { mutable in
        appendFoldedName(UnsafeBufferPointer(mutable), to: &out)
    }
    return out
}

func appendFoldedName(_ bytes: UnsafeBufferPointer<UInt8>, to out: inout [UInt8]) {
    var ascii = true
    for byte in bytes where byte >= 0x80 {
        ascii = false
        break
    }
    if ascii {
        for byte in bytes {
            out.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
        }
        return
    }
    out.append(contentsOf: foldString(String(decoding: bytes, as: UTF8.self)).utf8)
}

func rebuildChildLinks(parent: [Int32]) -> (firstChild: [Int32], nextSibling: [Int32]) {
    var firstChild = [Int32](repeating: -1, count: parent.count)
    var nextSibling = [Int32](repeating: -1, count: parent.count)
    var index = parent.count - 1
    while index >= 0 {
        let parentId = parent[index]
        if parentId >= 0 {
            nextSibling[index] = firstChild[Int(parentId)]
            firstChild[Int(parentId)] = Int32(index)
        }
        index -= 1
    }
    return (firstChild, nextSibling)
}

/// Returns a copy without deleted entries. Ids are renumbered in order, so the
/// parent-before-child invariant is preserved.
func compactIndex(_ data: IndexData) -> IndexData {
    var remap = [Int32](repeating: -1, count: data.count)
    var liveTotal = 0
    var nameBytes = 0
    var foldBytes = 0
    for index in 0..<data.count where data.flags[index] & EntryFlag.deleted == 0 {
        remap[index] = Int32(liveTotal)
        liveTotal += 1
        nameBytes += Int(data.nameLength[index])
        foldBytes += Int(data.foldLength[index])
    }
    var next = IndexData.empty()
    next.parent.reserveCapacity(liveTotal)
    next.nameStart.reserveCapacity(liveTotal)
    next.nameLength.reserveCapacity(liveTotal)
    next.foldStart.reserveCapacity(liveTotal)
    next.foldLength.reserveCapacity(liveTotal)
    next.size.reserveCapacity(liveTotal)
    next.modified.reserveCapacity(liveTotal)
    next.flags.reserveCapacity(liveTotal)
    next.names.reserveCapacity(nameBytes)
    next.folded.reserveCapacity(foldBytes)
    data.names.withUnsafeBufferPointer { names in
        data.folded.withUnsafeBufferPointer { folded in
            for index in 0..<data.count where remap[index] >= 0 {
                let parentId = data.parent[index]
                next.parent.append(parentId < 0 ? -1 : remap[Int(parentId)])
                let nameOffset = Int(data.nameStart[index])
                let nameCount = Int(data.nameLength[index])
                next.nameStart.append(UInt32(next.names.count))
                next.nameLength.append(UInt16(nameCount))
                next.names.append(contentsOf: UnsafeBufferPointer(rebasing: names[nameOffset..<(nameOffset + nameCount)]))
                let foldOffset = Int(data.foldStart[index])
                let foldCount = Int(data.foldLength[index])
                next.foldStart.append(UInt32(next.folded.count))
                next.foldLength.append(UInt16(foldCount))
                next.folded.append(contentsOf: UnsafeBufferPointer(rebasing: folded[foldOffset..<(foldOffset + foldCount)]))
                next.size.append(data.size[index])
                next.modified.append(data.modified[index])
                next.flags.append(data.flags[index])
            }
        }
    }
    let links = rebuildChildLinks(parent: next.parent)
    next.firstChild = links.firstChild
    next.nextSibling = links.nextSibling
    next.roots = data.roots.compactMap { root in
        let mapped = remap[Int(root.entryId)]
        return mapped >= 0 ? IndexRoot(path: root.path, entryId: mapped) : nil
    }
    next.liveCount = liveTotal
    next.deletedCount = 0
    next.revision = data.revision &+ 1
    return next
}
