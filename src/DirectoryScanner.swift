import Darwin
import Foundation

enum EntryKind: UInt8 {
    case file = 0
    case directory = 1
    case symlink = 2
    case other = 3
}

/// One directory's entries as returned by `getattrlistbulk`, packed into flat arrays.
struct DirectoryListing {
    var device: Int32
    var names: [UInt8]
    var nameStarts: [Int]
    var nameLengths: [Int]
    var kinds: [EntryKind]
    var sizes: [Int64]
    var modified: [Int64]
    var hidden: [Bool]
    var devices: [Int32]

    var count: Int {
        return kinds.count
    }

    func name(_ index: Int) -> String {
        return names.withUnsafeBufferPointer { buffer in
            let start = nameStarts[index]
            return String(
                decoding: UnsafeBufferPointer(rebasing: buffer[start..<(start + nameLengths[index])]),
                as: UTF8.self
            )
        }
    }
}

enum ListingError: Error, LocalizedError {
    case vanished(String)
    case denied(String)
    case failed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .vanished(let path):
            return "\(path) no longer exists."
        case .denied(let path):
            return "macOS denied access to \(path)."
        case .failed(let path, let code):
            return "Could not list \(path): \(String(cString: strerror(code)))"
        }
    }
}

private func listingError(path: String, code: Int32) -> ListingError {
    switch code {
    case ENOENT, ENOTDIR:
        return .vanished(path)
    case EACCES, EPERM:
        return .denied(path)
    default:
        return .failed(path, code)
    }
}

let listingBufferSize = 256 * 1024

func listDirectory(_ path: String, buffer: UnsafeMutableRawPointer) throws -> DirectoryListing {
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 {
        throw listingError(path: path, code: errno)
    }
    defer { close(descriptor) }
    var info = stat()
    if fstat(descriptor, &info) != 0 {
        throw listingError(path: path, code: errno)
    }
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_DEVID)
        | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_MODTIME)
        | attrgroup_t(ATTR_CMN_FLAGS)
    request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
    var listing = DirectoryListing(
        device: Int32(info.st_dev),
        names: [],
        nameStarts: [],
        nameLengths: [],
        kinds: [],
        sizes: [],
        modified: [],
        hidden: [],
        devices: []
    )
    while true {
        let returned = getattrlistbulk(descriptor, &request, buffer, listingBufferSize, 0)
        if returned < 0 {
            throw listingError(path: path, code: errno)
        }
        if returned == 0 {
            break
        }
        var entry = UnsafeRawPointer(buffer)
        for _ in 0..<Int(returned) {
            let length = Int(entry.loadUnaligned(as: UInt32.self))
            defer { entry += length }
            var field = entry + 4
            let attributes = field.loadUnaligned(as: attribute_set_t.self)
            field += MemoryLayout<attribute_set_t>.size
            if attributes.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                let entryError = field.loadUnaligned(as: UInt32.self)
                field += 4
                if entryError != 0 {
                    continue
                }
            }
            guard attributes.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else {
                continue
            }
            let nameOffset = Int(field.loadUnaligned(as: Int32.self))
            let nameLength = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let namePointer = (field + nameOffset).assumingMemoryBound(to: UInt8.self)
            field += 8
            var device = listing.device
            if attributes.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                device = field.loadUnaligned(as: Int32.self)
                field += 4
            }
            var objectType: UInt32 = 0
            if attributes.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                objectType = field.loadUnaligned(as: UInt32.self)
                field += 4
            }
            var modifiedSeconds: Int64 = 0
            if attributes.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                modifiedSeconds = Int64(field.loadUnaligned(as: Int.self))
                field += MemoryLayout<timespec>.size
            }
            var fileFlags: UInt32 = 0
            if attributes.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
                fileFlags = field.loadUnaligned(as: UInt32.self)
                field += 4
            }
            var dataLength: Int64 = 0
            if attributes.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
                dataLength = field.loadUnaligned(as: Int64.self)
                field += 8
            }
            let nameBytes = max(0, nameLength - 1)
            if nameBytes == 0 {
                continue
            }
            let kind: EntryKind
            switch objectType {
            case UInt32(VREG.rawValue):
                kind = .file
            case UInt32(VDIR.rawValue):
                kind = .directory
            case UInt32(VLNK.rawValue):
                kind = .symlink
            default:
                kind = .other
            }
            listing.nameStarts.append(listing.names.count)
            listing.nameLengths.append(nameBytes)
            listing.names.append(contentsOf: UnsafeBufferPointer(start: namePointer, count: nameBytes))
            listing.kinds.append(kind)
            listing.sizes.append(kind == .file ? dataLength : 0)
            listing.modified.append(modifiedSeconds)
            listing.hidden.append(fileFlags & UInt32(UF_HIDDEN) != 0 || namePointer[0] == 0x2E)
            listing.devices.append(device)
        }
    }
    return listing
}

// MARK: - What gets indexed

private let junkDirectoryNames: Set<String> = [
    ".Trash",
    ".Trashes",
    ".Spotlight-V100",
    ".fseventsd",
    ".TemporaryItems",
    ".DocumentRevisions-V100",
    ".AppleDouble",
    ".MobileBackups"
]

/// Directories shown as one entry; their contents are not indexed.
private let opaqueDirectoryExtensions: Set<String> = [
    "app",
    "appex",
    "bundle",
    "framework",
    "kext",
    "plugin",
    "xpc",
    "photoslibrary",
    "musiclibrary",
    "tvlibrary",
    "imovielibrary",
    "fcpbundle",
    "logicx",
    "band",
    "pages",
    "numbers",
    "key",
    "rtfd",
    "xcarchive",
    "dsym"
]

let homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path

func isJunkPath(_ path: String) -> Bool {
    if path.hasPrefix("/System") || path == "/dev" || path.hasPrefix("/dev/") {
        return true
    }
    if path.hasPrefix("/private/var/vm") || path.hasPrefix("/private/var/folders") {
        return true
    }
    if path.contains("/Library/Caches") || path.contains("/Library/Logs") {
        return true
    }
    return false
}

func isAutomaticHomePrivacyPath(_ path: String, walkRootPath: String) -> Bool {
    let privacyFolders = ["Library", "Pictures", "Music", "Movies"]
    for folder in privacyFolders {
        let privacyRoot = homeDirectoryPath + "/" + folder
        if path == privacyRoot || path.hasPrefix(privacyRoot + "/") {
            if walkRootPath == privacyRoot || walkRootPath.hasPrefix(privacyRoot + "/") {
                return false
            }
            return true
        }
    }
    return false
}

func isOpaqueDirectoryName(_ name: String) -> Bool {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
        return false
    }
    return opaqueDirectoryExtensions.contains(name[name.index(after: dot)...].lowercased())
}

enum ChildDisposition: Equatable {
    case skip
    case indexOnly
    case descend
}

func directoryDisposition(name: String, path: String, rootPath: String, crossesDevice: Bool) -> ChildDisposition {
    if junkDirectoryNames.contains(name) {
        return .skip
    }
    if isJunkPath(path) || Privacy.isUsageTrackingPath(path) || isAutomaticHomePrivacyPath(path, walkRootPath: rootPath) {
        return .skip
    }
    if crossesDevice || isOpaqueDirectoryName(name) {
        return .indexOnly
    }
    return .descend
}

func childPath(parent: String, name: String) -> String {
    return parent.hasSuffix("/") ? parent + name : parent + "/" + name
}

/// True when a changed path lies somewhere Lumos never indexes (junk, privacy,
/// app bundle internals) so the event can be dropped without touching the index.
func isIgnoredChangePath(_ path: String, rootPath: String) -> Bool {
    if isJunkPath(path) || Privacy.isUsageTrackingPath(path) || isAutomaticHomePrivacyPath(path, walkRootPath: rootPath) {
        return true
    }
    if path == rootPath {
        return false
    }
    let relative = rootPath == "/" ? path.dropFirst(1) : path.dropFirst(rootPath.count + 1)
    for component in relative.split(separator: "/") {
        let name = String(component)
        if junkDirectoryNames.contains(name) || isOpaqueDirectoryName(name) {
            return true
        }
    }
    return false
}

func collapsePathPrefixes(_ paths: [String]) -> [String] {
    let sorted = Set(paths).sorted()
    var result: [String] = []
    for path in sorted {
        if let last = result.last, pathIsInside(path, root: last) {
            continue
        }
        result.append(path)
    }
    return result
}

// MARK: - Scan and diff pool

enum ScanMode: Equatable {
    /// Directory has no indexed children yet: append everything.
    case fresh
    /// Compare the directory listing with indexed children.
    case diff
    /// Diff this directory and every indexed subdirectory below it.
    case diffRecursive
}

struct ScanTask: Equatable {
    let id: Int32
    let path: String
    let rootPath: String
    let mode: ScanMode
}

struct ScanTotals: Equatable {
    var directories: Int
    var added: Int
    var removed: Int
    var updated: Int
    var unreadable: Int

    static func zero() -> ScanTotals {
        return ScanTotals(directories: 0, added: 0, removed: 0, updated: 0, unreadable: 0)
    }

    var changed: Int {
        return added + removed + updated
    }
}

/// Thread-safe progress shared by scan workers and status readers.
final class ScanProgress {
    private let lock = NSLock()
    private var totals = ScanTotals.zero()
    private var cancelled = false

    func add(_ delta: ScanTotals) {
        lock.lock()
        totals.directories += delta.directories
        totals.added += delta.added
        totals.removed += delta.removed
        totals.updated += delta.updated
        totals.unreadable += delta.unreadable
        lock.unlock()
    }

    func current() -> ScanTotals {
        lock.lock()
        defer { lock.unlock() }
        return totals
    }

    func reset() {
        lock.lock()
        totals = ScanTotals.zero()
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

let scanThreadCount: Int = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))

/// Runs scan/diff tasks on a worker pool until the queue drains (or the
/// progress object is cancelled). New subdirectories found along the way are
/// scanned in the same run. Returns false when cancelled before finishing.
func runScan(store: IndexStore, tasks: [ScanTask], progress: ScanProgress, threadCount: Int) throws -> Bool {
    if tasks.isEmpty {
        return true
    }
    let condition = NSCondition()
    var queue = tasks
    var inFlight = 0
    var firstError: Error?
    DispatchQueue.concurrentPerform(iterations: threadCount) { _ in
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: listingBufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            condition.lock()
            while queue.isEmpty && inFlight > 0 && firstError == nil {
                condition.wait()
            }
            if firstError != nil || progress.isCancelled {
                condition.unlock()
                break
            }
            guard let task = queue.popLast() else {
                condition.unlock()
                break
            }
            inFlight += 1
            condition.unlock()
            var discovered: [ScanTask] = []
            var failure: Error?
            do {
                let outcome = try processScanTask(task, store: store, buffer: buffer)
                discovered = outcome.next
                progress.add(outcome.totals)
            } catch {
                failure = error
            }
            condition.lock()
            if let failure, firstError == nil {
                firstError = failure
            }
            queue.append(contentsOf: discovered)
            inFlight -= 1
            condition.broadcast()
            condition.unlock()
        }
    }
    if let firstError {
        throw firstError
    }
    return !progress.isCancelled || queue.isEmpty
}

struct ScanOutcome {
    let next: [ScanTask]
    let totals: ScanTotals
}

private struct PlannedChild {
    let index: Int
    let name: String
    let disposition: ChildDisposition
    let path: String?
}

private func planChildren(_ listing: DirectoryListing, task: ScanTask) -> [PlannedChild] {
    var planned: [PlannedChild] = []
    planned.reserveCapacity(listing.count)
    listing.names.withUnsafeBufferPointer { names in
        for index in 0..<listing.count {
            let start = listing.nameStarts[index]
            let bytes = UnsafeBufferPointer(rebasing: names[start..<(start + listing.nameLengths[index])])
            let name = String(decoding: bytes, as: UTF8.self)
            if listing.kinds[index] != .directory {
                if Privacy.isUsageTrackingFileName(bytes) {
                    continue
                }
                planned.append(PlannedChild(index: index, name: name, disposition: .indexOnly, path: nil))
                continue
            }
            let path = childPath(parent: task.path, name: name)
            let disposition = directoryDisposition(
                name: name,
                path: path,
                rootPath: task.rootPath,
                crossesDevice: listing.devices[index] != listing.device
            )
            if disposition == .skip {
                continue
            }
            planned.append(PlannedChild(index: index, name: name, disposition: disposition, path: path))
        }
    }
    return planned
}

private func entryFlags(_ listing: DirectoryListing, child: PlannedChild) -> UInt8 {
    var flags: UInt8 = 0
    switch listing.kinds[child.index] {
    case .directory:
        flags |= EntryFlag.directory
        if child.disposition == .indexOnly {
            flags |= EntryFlag.opaque
        }
    case .symlink:
        flags |= EntryFlag.symlink
    case .file, .other:
        break
    }
    if listing.hidden[child.index] {
        flags |= EntryFlag.hidden
    }
    return flags
}

private func appendChild(
    _ child: PlannedChild,
    listing: DirectoryListing,
    parentId: Int32,
    task: ScanTask,
    data: inout IndexData
) throws -> ScanTask? {
    let start = listing.nameStarts[child.index]
    let id = try listing.names.withUnsafeBufferPointer { names in
        try data.appendEntry(
            parent: parentId,
            name: UnsafeBufferPointer(rebasing: names[start..<(start + listing.nameLengths[child.index])]),
            size: listing.sizes[child.index],
            modified: listing.modified[child.index],
            flags: entryFlags(listing, child: child)
        )
    }
    if child.disposition == .descend, let path = child.path {
        return ScanTask(id: id, path: path, rootPath: task.rootPath, mode: .fresh)
    }
    return nil
}

func processScanTask(_ task: ScanTask, store: IndexStore, buffer: UnsafeMutableRawPointer) throws -> ScanOutcome {
    var totals = ScanTotals.zero()
    let listing: DirectoryListing
    do {
        listing = try listDirectory(task.path, buffer: buffer)
    } catch ListingError.vanished {
        let removed = store.write { data -> Int in
            if !data.isLive(task.id) || data.flags[Int(task.id)] & EntryFlag.root != 0 {
                return 0
            }
            return data.removeEntry(task.id)
        }
        totals.removed = removed
        return ScanOutcome(next: [], totals: totals)
    } catch is ListingError {
        totals.unreadable = 1
        return ScanOutcome(next: [], totals: totals)
    }
    totals.directories = 1
    let planned = planChildren(listing, task: task)
    var next: [ScanTask] = []
    try store.write { data in
        if !data.isLive(task.id) || !data.isDirectory(task.id) {
            return
        }
        if task.mode == .fresh && data.firstChild[Int(task.id)] < 0 {
            for child in planned {
                if let scan = try appendChild(child, listing: listing, parentId: task.id, task: task, data: &data) {
                    next.append(scan)
                }
                totals.added += 1
            }
            return
        }
        var existing: [String: Int32] = [:]
        var child = data.firstChild[Int(task.id)]
        while child >= 0 {
            existing[data.nameString(child)] = child
            child = data.nextSibling[Int(child)]
        }
        let parentHidden = data.flags[Int(task.id)] & EntryFlag.hidden
        var needsPrune = false
        for plannedChild in planned {
            if let current = existing.removeValue(forKey: plannedChild.name) {
                let index = Int(current)
                let wanted = entryFlags(listing, child: plannedChild) | parentHidden
                let shapeMask = EntryFlag.directory | EntryFlag.symlink | EntryFlag.opaque | EntryFlag.hidden
                if data.flags[index] & shapeMask == wanted & shapeMask {
                    let newSize = listing.sizes[plannedChild.index]
                    let newModified = listing.modified[plannedChild.index]
                    if data.size[index] != newSize || data.modified[index] != newModified {
                        data.updateEntry(current, size: newSize, modified: newModified)
                        totals.updated += 1
                    }
                    if task.mode == .diffRecursive && plannedChild.disposition == .descend, let path = plannedChild.path {
                        next.append(ScanTask(id: current, path: path, rootPath: task.rootPath, mode: .diffRecursive))
                    }
                    continue
                }
                totals.removed += data.markSubtreeDeleted(current)
                needsPrune = true
            }
            if let scan = try appendChild(plannedChild, listing: listing, parentId: task.id, task: task, data: &data) {
                next.append(scan)
            }
            totals.added += 1
        }
        for (_, stale) in existing {
            totals.removed += data.markSubtreeDeleted(stale)
            needsPrune = true
        }
        if needsPrune {
            data.pruneDeletedChildren(of: task.id)
        }
    }
    return ScanOutcome(next: next, totals: totals)
}
