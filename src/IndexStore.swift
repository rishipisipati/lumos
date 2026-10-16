import Foundation

/// Reader/writer-locked owner of the live `IndexData`. Searches take the read
/// lock concurrently; the indexer takes the write lock only for in-memory
/// mutations (never while doing file system I/O).
final class IndexStore {
    private var data: IndexData
    private var layoutValue: UInt64 = 0
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>

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
        defer { pthread_rwlock_unlock(lock) }
        data = next
        layoutValue &+= 1
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
}
