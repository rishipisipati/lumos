import CoreServices
import Foundation

enum IndexPhase: String, Sendable {
    case starting
    case scanning
    case catchingUp
    case updating
    case live
    case failed
}

struct IndexStatus: Equatable, Sendable {
    let phase: IndexPhase
    let objectCount: Int
    let message: String
    let revision: UInt64
    let layout: UInt64
    let problem: String?

    var isBusy: Bool {
        return phase != .live && phase != .failed
    }
}

enum IndexServiceError: Error, LocalizedError {
    case lockUnavailable(String)
    case alreadyRunning(String)

    var errorDescription: String? {
        switch self {
        case .lockUnavailable(let detail):
            return "Could not lock the Lumos index: \(detail)"
        case .alreadyRunning(let pid):
            return "Another Lumos process (pid \(pid)) is already using the index. Quit that copy and try again."
        }
    }
}

private let snapshotSaveInterval: TimeInterval = 20
private let traceEnabled = ProcessInfo.processInfo.environment["LUMOS_TRACE"] == "1"
private let traceStart = DispatchTime.now()

/// Opt-in diagnostics (LUMOS_TRACE=1) written to stderr.
func trace(_ text: @autoclosure () -> String) {
    if !traceEnabled {
        return
    }
    // Read the lazily initialized start first so it can never be later than now.
    let start = traceStart.uptimeNanoseconds
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    fputs(String(format: "[lumos %8.3f] ", seconds) + text() + "\n", stderr)
}
private let networkRescanInterval: TimeInterval = 600
/// Even a zero wait gets this long to collect events FSEvents holds for latency.
private let minimumFlushWait: Double = 0.25
private let watcherLatency: CFTimeInterval = 0.5

/// Owns the live index: initial scan, snapshot load/save, FSEvents journal
/// replay and change application. All index mutations run on `operations`
/// (serial); scan I/O inside an operation is parallel.
final class IndexService {
    let store = IndexStore(data: IndexData.empty())
    private let folder: URL
    private let snapshotURL: URL
    private var roots: [String]
    private let operations = DispatchQueue(label: "lumos.index.operations", qos: .utility)
    private let eventQueue = DispatchQueue(label: "lumos.index.events", qos: .utility)
    private let snapshotQueue = DispatchQueue(label: "lumos.index.snapshot", qos: .utility)
    private let progress = ScanProgress()
    private let stateLock = NSLock()

    private var phase: IndexPhase = .starting
    private var message: String = "Starting…"
    private var problem: String?
    private var pendingChanges: [String: Bool] = [:]
    private var pendingEventId: UInt64 = 0
    private var flushScheduled = false
    private var replayDone = true
    private var operationCount = 0
    /// Shown while live; set on `operations` after a from-scratch scan.
    private var liveMessage = "Up to date"

    private var watcher: FileWatcher?
    private var appliedEventId: UInt64 = 0
    private var rescanRoots: Set<String> = []
    private var savedRevision: UInt64 = UInt64.max
    private var lastSaveAt = Date.distantPast
    private var saveScheduled = false
    private var periodicTimer: DispatchSourceTimer?
    private var lock: IndexLock?
    private var flushGroup: DispatchGroup?
    /// Marker files written here prove FSEvents has caught up to "now"; see
    /// `waitForBarrier`.
    private let barrierFolder: String
    private var barrierWatcher: FileWatcher?
    private var barrierWaiters: [String: DispatchSemaphore] = [:]
    private var barrierIds: [String: FSEventStreamEventId] = [:]
    /// Highest event id the main stream has handed to `handleEvents`.
    private var lastDeliveredEventId: FSEventStreamEventId = 0
    private let barrierQueue = DispatchQueue(label: "lumos.index.barrier", qos: .userInitiated)

    var indexFolder: URL {
        return folder
    }

    init(folder: URL, roots: [String]) {
        self.folder = folder
        self.snapshotURL = folder.appendingPathComponent("index.lumos")
        // realpath, not resolvingSymlinksInPath: Foundation maps /private/tmp to
        // /tmp, but FSEvents reports the real path.
        self.barrierFolder = (normalizeRoots([folder.path]).first ?? folder.path) + "/barrier"
        self.roots = roots
    }

    func start() throws {
        let acquired = IndexLock(directory: folder.path)
        try acquired.acquire()
        try FileManager.default.createDirectory(atPath: barrierFolder, withIntermediateDirectories: true)
        barrierWatcher = try FileWatcher(
            paths: [barrierFolder],
            since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency: 0,
            queue: barrierQueue,
            fileEvents: true,
            handler: { [weak self] events in
                self?.handleBarrierEvents(events)
            }
        )
        lock = acquired
        enqueue { self.startup() }
    }

    /// Stops watching, finishes or cancels the running operation and saves the
    /// index so the next launch resumes from the FSEvents journal.
    func stop() {
        progress.cancel()
        operations.sync {
            periodicTimer?.cancel()
            periodicTimer = nil
            watcher?.stop()
            watcher = nil
            saveSnapshot()
        }
        snapshotQueue.sync {}
        barrierQueue.sync {
            barrierWatcher?.stop()
            barrierWatcher = nil
        }
        lock = nil
    }

    func reindex() {
        enqueue {
            let tasks = self.store.read { data in
                data.roots.map { ScanTask(id: $0.entryId, path: $0.path, rootPath: $0.path, mode: .diffRecursive) }
            }
            self.setState(.scanning, "Re-checking every indexed folder…")
            _ = self.runTasks(tasks)
            self.scheduleSave()
            self.refreshIdlePhase()
        }
    }

    /// Drops the in-memory index and the saved snapshot, then indexes every
    /// root from scratch exactly like a first launch.
    func clearAndReindex() {
        enqueue {
            self.store.replace(IndexData.empty())
            self.rescanRoots = []
            self.savedRevision = UInt64.max
            self.snapshotQueue.sync {}
            if FileManager.default.fileExists(atPath: self.snapshotURL.path) {
                do {
                    try FileManager.default.removeItem(at: self.snapshotURL)
                } catch {
                    self.setState(.failed, "Could not delete \(self.snapshotURL.path): \(error.localizedDescription)")
                    return
                }
            }
            self.startup()
        }
    }

    func updateRoots(_ next: [String]) {
        enqueue {
            self.roots = normalizeRoots(next)
            let tasks = self.reconcileRoots()
            self.startWatcher(since: self.appliedEventId)
            if !tasks.isEmpty {
                self.setState(.scanning, "Indexing new folders…")
                if self.runTasks(tasks) {
                    for task in tasks {
                        self.rescanRoots.remove(task.path)
                    }
                }
            }
            self.scheduleSave()
            self.refreshIdlePhase()
        }
    }

    func status() -> IndexStatus {
        stateLock.lock()
        let currentPhase = phase
        var text = message
        let currentProblem = problem
        stateLock.unlock()
        if currentPhase == .scanning || currentPhase == .updating {
            let totals = progress.current()
            text += "  \(formatCount(totals.added)) added, \(formatCount(totals.removed)) removed"
        }
        return store.readWithLayout { data, layout in
            IndexStatus(
                phase: currentPhase,
                objectCount: data.liveCount,
                message: text,
                revision: data.revision,
                layout: layout,
                problem: currentProblem
            )
        }
    }

    /// True when no operation is queued or running and no change is waiting.
    func isIdle() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operationCount == 0 && !flushScheduled && pendingChanges.isEmpty && replayDone
    }

    /// Asks FSEvents to deliver anything it is holding back for latency.
    func flushEvents() {
        operations.sync {
            watcher?.flush()
        }
    }

    /// `flushEvents` bounded by `deadline`. The flush waits behind any running
    /// operation, so concurrent callers share one in-flight flush instead of
    /// each parking a thread. Returns false when the deadline passed first.
    func flushEvents(before deadline: DispatchTime) -> Bool {
        stateLock.lock()
        let group: DispatchGroup
        if let current = flushGroup {
            group = current
        } else {
            group = DispatchGroup()
            group.enter()
            flushGroup = group
            DispatchQueue.global(qos: .userInitiated).async {
                self.flushEvents()
                self.stateLock.lock()
                self.flushGroup = nil
                self.stateLock.unlock()
                group.leave()
            }
        }
        stateLock.unlock()
        return group.wait(timeout: deadline) == .success
    }

    /// Waits until every change made before the call is applied. A marker file
    /// gets an FSEvents id after all earlier changes; once the main stream
    /// (which also watches the marker folder and delivers in id order) has
    /// handed over that id, every earlier change is queued, and the index is
    /// exact when the operations queue drains.
    func waitUntilExact(seconds: Double) -> Bool {
        let deadline = DispatchTime.now() + max(seconds, 0)
        let flushDeadline = DispatchTime.now() + max(seconds, minimumFlushWait)
        guard let barrierId = waitForBarrier(before: flushDeadline) else {
            return false
        }
        while deliveredEventId() < barrierId {
            if DispatchTime.now() >= flushDeadline || !flushEvents(before: flushDeadline) {
                return false
            }
            if deliveredEventId() < barrierId {
                usleep(5_000)
            }
        }
        while true {
            if isIdle() && status().phase == .live {
                return true
            }
            if DispatchTime.now() >= deadline {
                return false
            }
            usleep(20_000)
        }
    }

    /// FSEvents receives kernel changes asynchronously and numbers them in
    /// order, so a flush alone can miss a write made a moment ago. Creates a
    /// uniquely named marker file and returns the FSEvents id it was given
    /// (seen on the file-level barrier stream), or nil past the deadline.
    private func waitForBarrier(before deadline: DispatchTime) -> FSEventStreamEventId? {
        let path = barrierFolder + "/" + UUID().uuidString
        let seen = DispatchSemaphore(value: 0)
        stateLock.lock()
        barrierWaiters[path] = seen
        stateLock.unlock()
        defer {
            stateLock.lock()
            barrierWaiters[path] = nil
            barrierIds[path] = nil
            stateLock.unlock()
            unlink(path)
        }
        if !FileManager.default.createFile(atPath: path, contents: nil) {
            reportProblem("Cannot write query barrier files in \(barrierFolder); results cannot be confirmed exact.")
            return nil
        }
        if seen.wait(timeout: deadline) != .success {
            return nil
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        return barrierIds[path]
    }

    private func handleBarrierEvents(_ events: [WatchEvent]) {
        stateLock.lock()
        var signals: [DispatchSemaphore] = []
        for event in events {
            if let waiter = barrierWaiters.removeValue(forKey: event.path) {
                barrierIds[event.path] = event.id
                signals.append(waiter)
            }
        }
        stateLock.unlock()
        for signal in signals {
            signal.signal()
        }
    }

    private func deliveredEventId() -> FSEventStreamEventId {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastDeliveredEventId
    }

    func saveNow() {
        operations.sync {
            saveSnapshot()
        }
        snapshotQueue.sync {}
    }

    // MARK: - Operations

    private func enqueue(_ body: @escaping () -> Void) {
        stateLock.lock()
        operationCount += 1
        stateLock.unlock()
        operations.async {
            body()
            self.stateLock.lock()
            self.operationCount -= 1
            self.stateLock.unlock()
        }
    }

    private func startup() {
        setState(.starting, "Loading index…")
        removeLegacyDatabase()
        roots = normalizeRoots(roots)
        if roots.isEmpty {
            setState(.failed, "No folders are selected for indexing.")
            return
        }
        let currentEventId = currentFileSystemEventId()
        var since = currentEventId
        var loadedMeta: SnapshotMeta?
        var loadProblem: String?
        do {
            let loaded = try readSnapshot(from: snapshotURL)
            store.replace(loaded.data)
            loadedMeta = loaded.meta
        } catch SnapshotError.missing {
            loadedMeta = nil
        } catch {
            loadProblem = error.localizedDescription
            fputs("Lumos: saved index not used: \(error.localizedDescription)\n", stderr)
        }
        if let meta = loadedMeta {
            since = min(meta.eventId, currentEventId)
            rescanRoots = Set(meta.rescanRoots)
            for root in meta.roots where roots.contains(root.path) {
                let uuid = fileSystemEventsVolumeUUID(for: root.path)
                let journalValid = meta.eventId <= currentEventId && uuid != nil && uuid == meta.volumeUUIDs[root.path]
                if !journalValid || isLocalVolume(root.path) != true {
                    rescanRoots.insert(root.path)
                }
            }
        }
        let tasks = reconcileRoots()
        appliedEventId = since
        setReplayDone(loadedMeta == nil)
        startWatcher(since: since)
        if !tasks.isEmpty {
            let verb = loadedMeta == nil ? "Indexing" : "Checking"
            let prefix = loadProblem.map { "\($0) Rebuilding. " } ?? ""
            setState(.scanning, "\(prefix)\(verb) \(tasks.map(\.path).joined(separator: ", "))…")
            let started = Date()
            if runTasks(tasks) {
                for task in tasks {
                    rescanRoots.remove(task.path)
                }
                if loadedMeta == nil {
                    let objects = store.read { $0.liveCount }
                    let seconds = Date().timeIntervalSince(started)
                    liveMessage = "Up to date · indexed \(formatCount(objects)) objects from scratch in \(String(format: "%.1f", seconds)) s"
                }
            }
        }
        saveSnapshot()
        schedulePeriodicRescan()
        refreshIdlePhase()
    }

    /// Aligns indexed roots with configured roots. Returns scan tasks for roots
    /// that are new or need a full re-diff.
    private func reconcileRoots() -> [ScanTask] {
        let configured = roots
        var tasks: [ScanTask] = []
        do {
            try store.write { data in
                for root in data.roots where !configured.contains(root.path) {
                    _ = data.removeEntry(root.entryId)
                }
                for path in configured where !data.roots.contains(where: { $0.path == path }) {
                    let id = try data.addRoot(path: path, modified: modificationTime(path))
                    tasks.append(ScanTask(id: id, path: path, rootPath: path, mode: .fresh))
                    rescanRoots.insert(path)
                }
            }
        } catch {
            setState(.failed, error.localizedDescription)
            return []
        }
        rescanRoots = rescanRoots.filter { configured.contains($0) }
        let current = store.read { $0.roots }
        for root in current where rescanRoots.contains(root.path) && !tasks.contains(where: { $0.id == root.entryId }) {
            tasks.append(ScanTask(id: root.entryId, path: root.path, rootPath: root.path, mode: .diffRecursive))
        }
        return tasks
    }

    private func runTasks(_ tasks: [ScanTask]) -> Bool {
        progress.reset()
        do {
            return try runScan(store: store, tasks: tasks, progress: progress, threadCount: scanThreadCount)
        } catch {
            setState(.failed, error.localizedDescription)
            return false
        }
    }

    private func startWatcher(since: UInt64) {
        watcher?.stop()
        watcher = nil
        do {
            watcher = try FileWatcher(
                paths: roots + [barrierFolder],
                since: since,
                latency: watcherLatency,
                queue: eventQueue,
                fileEvents: false,
                handler: { [weak self] events in
                    self?.handleEvents(events)
                }
            )
        } catch {
            setState(.failed, error.localizedDescription)
        }
    }

    private func handleEvents(_ events: [WatchEvent]) {
        let recursiveFlags = kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
            | kFSEventStreamEventFlagEventIdsWrapped
        stateLock.lock()
        for event in events {
            pendingEventId = max(pendingEventId, event.id)
            lastDeliveredEventId = max(lastDeliveredEventId, event.id)
            if event.path == barrierFolder || event.path.hasPrefix(barrierFolder + "/") {
                continue
            }
            if event.has(kFSEventStreamEventFlagHistoryDone) {
                replayDone = true
                continue
            }
            if event.path.isEmpty {
                continue
            }
            pendingChanges[event.path] = (pendingChanges[event.path] ?? false) || event.has(recursiveFlags)
        }
        let schedule = !flushScheduled
        flushScheduled = true
        let waiting = pendingChanges.count
        stateLock.unlock()
        trace("events \(events.count) (last id \(events.last?.id ?? 0)), \(waiting) folders waiting")
        if schedule {
            enqueue { self.applyPendingChanges() }
        }
    }

    private func applyPendingChanges() {
        stateLock.lock()
        let changes = pendingChanges
        let eventId = pendingEventId
        pendingChanges = [:]
        flushScheduled = false
        stateLock.unlock()
        let started = DispatchTime.now()
        let tasks = store.read { data in resolveChangeTasks(changes, data: data) }
        if !tasks.isEmpty {
            let noun = tasks.count == 1 ? "folder" : "folders"
            setState(.updating, "Updating \(formatCount(tasks.count)) changed \(noun)…")
            if !runTasks(tasks) {
                return
            }
        }
        let totals = progress.current()
        trace("applied \(changes.count) paths as \(tasks.count) tasks in \((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000) ms: +\(totals.added) -\(totals.removed) ~\(totals.updated), \(totals.directories) dirs listed")
        appliedEventId = max(appliedEventId, eventId)
        compactIfWorthwhile()
        scheduleSave()
        refreshIdlePhase()
    }

    private func rescanNetworkRoots() {
        let targets = store.read { $0.roots }.filter { isLocalVolume($0.path) != true }
        if targets.isEmpty {
            return
        }
        stateLock.lock()
        operationCount += 1
        stateLock.unlock()
        defer {
            stateLock.lock()
            operationCount -= 1
            stateLock.unlock()
        }
        setState(.updating, "Re-checking network folders…")
        _ = runTasks(targets.map { ScanTask(id: $0.entryId, path: $0.path, rootPath: $0.path, mode: .diffRecursive) })
        scheduleSave()
        refreshIdlePhase()
    }

    private func schedulePeriodicRescan() {
        periodicTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: operations)
        timer.schedule(deadline: .now() + networkRescanInterval, repeating: networkRescanInterval)
        timer.setEventHandler { [weak self] in
            self?.rescanNetworkRoots()
        }
        timer.resume()
        periodicTimer = timer
    }

    /// Deleted entries are tombstones; renumber once they dominate the arrays.
    private func compactIfWorthwhile() {
        let counts = store.read { ($0.deletedCount, $0.liveCount) }
        if counts.0 < 100_000 || counts.0 < counts.1 / 2 {
            return
        }
        let compacted = store.read { compactIndex($0) }
        store.replace(compacted)
    }

    // MARK: - Snapshots

    private func scheduleSave() {
        let revision = store.read { $0.revision }
        if revision == savedRevision {
            return
        }
        let elapsed = Date().timeIntervalSince(lastSaveAt)
        if elapsed >= snapshotSaveInterval {
            saveSnapshot()
            return
        }
        if saveScheduled {
            return
        }
        saveScheduled = true
        operations.asyncAfter(deadline: .now() + (snapshotSaveInterval - elapsed)) {
            self.saveScheduled = false
            self.saveSnapshot()
        }
    }

    private func saveSnapshot() {
        let captured = store.read { $0 }
        if captured.revision == savedRevision || captured.roots.isEmpty {
            return
        }
        let eventId = appliedEventId
        let rescan = Array(rescanRoots).sorted()
        var uuids: [String: String] = [:]
        for root in captured.roots {
            if let uuid = fileSystemEventsVolumeUUID(for: root.path) {
                uuids[root.path] = uuid
            }
        }
        savedRevision = captured.revision
        lastSaveAt = Date()
        let url = snapshotURL
        snapshotQueue.async {
            let compacted = captured.deletedCount > 0 ? compactIndex(captured) : captured
            let meta = SnapshotMeta(
                eventId: eventId,
                roots: compacted.roots,
                volumeUUIDs: uuids,
                rescanRoots: rescan,
                savedAt: Date().timeIntervalSince1970
            )
            do {
                try writeSnapshot(compacted, meta: meta, to: url)
            } catch {
                fputs("Lumos: \(error.localizedDescription)\n", stderr)
                self.operations.async {
                    self.savedRevision = UInt64.max
                }
                self.reportProblem(error.localizedDescription)
            }
        }
    }

    private func removeLegacyDatabase() {
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "indexer.pid"] {
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                fputs("Lumos: could not remove legacy \(url.path): \(error.localizedDescription)\n", stderr)
            }
        }
    }

    // MARK: - State

    private func setState(_ next: IndexPhase, _ text: String) {
        stateLock.lock()
        if phase != .failed || next == .failed {
            phase = next
            message = text
        }
        stateLock.unlock()
    }

    private func reportProblem(_ text: String) {
        stateLock.lock()
        problem = text
        stateLock.unlock()
    }

    private func setReplayDone(_ done: Bool) {
        stateLock.lock()
        replayDone = done
        stateLock.unlock()
    }

    private func refreshIdlePhase() {
        stateLock.lock()
        let replayed = replayDone
        let failed = phase == .failed
        stateLock.unlock()
        if failed {
            return
        }
        if !replayed {
            setState(.catchingUp, "Catching up on changes made while Lumos was closed…")
            return
        }
        setState(.live, liveMessage)
    }
}

/// Turns coalesced FSEvents directory paths into scan tasks. Paths not yet in
/// the index resolve to their nearest indexed ancestor, which discovers them as
/// new entries. Tasks below a recursive task are dropped.
func resolveChangeTasks(_ changes: [String: Bool], data: IndexData) -> [ScanTask] {
    var byId: [Int32: ScanTask] = [:]
    func add(_ id: Int32, recursive: Bool) {
        if !data.isLive(id) || !data.isDirectory(id) || data.flags[Int(id)] & EntryFlag.opaque != 0 {
            return
        }
        let path = data.fullPath(id)
        guard let root = data.rootContaining(path) else {
            return
        }
        if let existing = byId[id], existing.mode == .diffRecursive {
            return
        }
        byId[id] = ScanTask(id: id, path: path, rootPath: root.path, mode: recursive ? .diffRecursive : .diff)
    }
    for (path, recursive) in changes {
        guard let root = data.rootContaining(path) else {
            if recursive {
                for root in data.roots where pathIsInside(root.path, root: path) {
                    add(root.entryId, recursive: true)
                }
            }
            continue
        }
        if isIgnoredChangePath(path, rootPath: root.path) {
            continue
        }
        switch data.lookup(path: path) {
        case .found(let id):
            if data.isDirectory(id) && data.flags[Int(id)] & EntryFlag.opaque == 0 {
                add(id, recursive: recursive)
            } else if data.parent[Int(id)] >= 0 {
                add(data.parent[Int(id)], recursive: false)
            }
        case .missing(let ancestor):
            add(ancestor, recursive: false)
        case .outsideRoots:
            continue
        }
    }
    let recursivePaths = collapsePathPrefixes(byId.values.filter { $0.mode == .diffRecursive }.map(\.path))
    return byId.values
        .filter { task in
            !recursivePaths.contains { $0 != task.path && pathIsInside(task.path, root: $0) }
        }
        .sorted { $0.path < $1.path }
}

func normalizeRoots(_ paths: [String]) -> [String] {
    let resolved = paths.map { path -> String in
        let standardized = (path as NSString).standardizingPath
        guard let real = realpath(standardized, nil) else {
            return standardized
        }
        defer { free(real) }
        return String(cString: real)
    }
    return collapsePathPrefixes(resolved)
}

func modificationTime(_ path: String) -> Int64 {
    var info = stat()
    if lstat(path, &info) != 0 {
        return 0
    }
    return Int64(info.st_mtimespec.tv_sec)
}

let indexRootsDefaultsKey = "indexRoots"
let appDefaultsDomain = "com.lumos.search"

/// Folders the user chose in the app, or home + /Applications when unset.
/// The daemon reads the app's domain so both index the same roots.
func configuredIndexRoots(_ defaults: UserDefaults) -> [String] {
    if let stored = defaults.array(forKey: indexRootsDefaultsKey) as? [String], !stored.isEmpty {
        return stored
    }
    return [FileManager.default.homeDirectoryForCurrentUser.path, "/Applications"]
}

/// Single-writer guard: two processes saving the same snapshot would race.
final class IndexLock {
    private let path: String
    private var fd: Int32 = -1

    init(directory: String) {
        path = (directory as NSString).appendingPathComponent("index.lock")
    }

    func acquire() throws {
        let opened = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        if opened < 0 {
            throw IndexServiceError.lockUnavailable("cannot create \(path): \(String(cString: strerror(errno)))")
        }
        if flock(opened, LOCK_EX | LOCK_NB) != 0 {
            var buffer = [CChar](repeating: 0, count: 64)
            _ = read(opened, &buffer, 63)
            close(opened)
            let holder = String(cString: buffer)
            throw IndexServiceError.alreadyRunning(holder.isEmpty ? "unknown" : holder)
        }
        if ftruncate(opened, 0) != 0 {
            flock(opened, LOCK_UN)
            close(opened)
            throw IndexServiceError.lockUnavailable("cannot reset \(path)")
        }
        let pid = "\(getpid())"
        let wrote = pid.withCString { pointer in
            write(opened, pointer, strlen(pointer))
        }
        if wrote < 0 {
            flock(opened, LOCK_UN)
            close(opened)
            throw IndexServiceError.lockUnavailable("cannot write \(path)")
        }
        fd = opened
    }

    deinit {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}
