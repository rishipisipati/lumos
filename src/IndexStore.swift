import Foundation

/// Smaller indexes scan faster than the trigram index pays for itself.
private let trigramMinimumEntries = 20_000
/// Entries appended since the last trigram build are scanned linearly; rebuild
/// once they exceed this many, or a quarter of the covered entries.
private let trigramMinimumTail = 65_536

/// Reader/writer-locked owner of the live `IndexData`. Searches take the read
/// lock concurrently; the indexer takes the write lock only for in-memory
/// mutations (never while doing file system I/O).
final class IndexStore {
    private var data: IndexData
    private var layoutValue: UInt64 = 0
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    private let trigramLock = NSLock()
    private var trigrams: NameTrigramIndex?
    private var trigramBuildRunning = false
    private let trigramQueue = DispatchQueue(label: "lumos.index.trigrams", qos: .utility)

    init(data: IndexData) {
        self.data = data
        lock = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }

    func read<Result>(_ body: (IndexData) throws -> Result) rethrows -> Result {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body(data)
    }

    func write<Result>(_ body: (inout IndexData) throws -> Result) rethrows -> Result {
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body(&data)
    }

    /// Replaces the whole index. Entry ids from before the call become invalid,
    /// which callers detect through `layout`.
    func replace(_ next: IndexData) {
        pthread_rwlock_wrlock(lock)
        data = next
        layoutValue &+= 1
        pthread_rwlock_unlock(lock)
        trigramLock.lock()
        trigrams = nil
        trigramLock.unlock()
    }

    /// Changes whenever entry ids are renumbered (load, compaction).
    var layout: UInt64 {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return layoutValue
    }

    func readWithLayout<Result>(_ body: (IndexData, UInt64) throws -> Result) rethrows -> Result {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body(data, layoutValue)
    }

    /// Like `readWithLayout`, plus the trigram index when it was built from the
    /// current layout. Schedules a background rebuild when it is missing or
    /// too far behind.
    func readForSearch<Result>(_ body: (IndexData, UInt64, NameTrigramIndex?) throws -> Result) rethrows -> Result {
        trigramLock.lock()
        let current = trigrams
        trigramLock.unlock()
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        let usable = current.flatMap { $0.layout == layoutValue && $0.coveredCount <= data.count ? $0 : nil }
        let tail = data.count - (usable?.coveredCount ?? 0)
        if data.count >= trigramMinimumEntries
            && (usable == nil || tail > max(trigramMinimumTail, (usable?.coveredCount ?? 0) / 4)) {
            scheduleTrigramBuild()
        }
        return try body(data, layoutValue, usable)
    }

    /// Builds from a copy of the index so writers and searches are never blocked.
    private func scheduleTrigramBuild() {
        trigramLock.lock()
        if trigramBuildRunning {
            trigramLock.unlock()
            return
        }
        trigramBuildRunning = true
        trigramLock.unlock()
        trigramQueue.async {
            let (snapshot, layout) = self.readWithLayout { ($0, $1) }
            let built = buildNameTrigramIndex(snapshot, layout: layout)
            self.trigramLock.lock()
            self.trigrams = built
            self.trigramBuildRunning = false
            self.trigramLock.unlock()
        }
    }
}
