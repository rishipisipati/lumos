import CoreServices
import Foundation

struct WatchEvent: Equatable {
    let path: String
    let flags: FSEventStreamEventFlags
    let id: FSEventStreamEventId

    func has(_ flag: Int) -> Bool {
        return flags & FSEventStreamEventFlags(flag) != 0
    }
}

enum WatcherError: Error, LocalizedError {
    case createFailed([String])
    case startFailed([String])

    var errorDescription: String? {
        switch self {
        case .createFailed(let paths):
            return "macOS refused to watch \(paths.joined(separator: ", ")) for changes."
        case .startFailed(let paths):
            return "Could not start watching \(paths.joined(separator: ", ")) for changes."
        }
    }
}

/// FSEvents stream. The index uses directory-level events (`fileEvents` false),
/// which keep a million-file burst down to roughly one event per folder, and
/// `since` lets a relaunch replay the journal from the last applied event.
/// File-level events are only for the small query barrier folder.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let box: WatcherBox

    init(
        paths: [String],
        since: FSEventStreamEventId,
        latency: CFTimeInterval,
        queue: DispatchQueue,
        fileEvents: Bool,
        handler: @escaping ([WatchEvent]) -> Void
    ) throws {
        box = WatcherBox(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        var rawFlags = kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer
        if fileEvents {
            rawFlags |= kFSEventStreamCreateFlagFileEvents
        }
        let flags = FSEventStreamCreateFlags(rawFlags)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            watcherCallback,
            &context,
            paths as CFArray,
            since,
            latency,
            flags
        ) else {
            throw WatcherError.createFailed(paths)
        }
        FSEventStreamSetDispatchQueue(created, queue)
        if !FSEventStreamStart(created) {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw WatcherError.startFailed(paths)
        }
        stream = created
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    /// Delivers any events FSEvents is still holding back because of latency.
    func flush() {
        if let stream {
            FSEventStreamFlushSync(stream)
        }
    }

    deinit {
        stop()
    }
}

private final class WatcherBox {
    let handler: ([WatchEvent]) -> Void

    init(handler: @escaping ([WatchEvent]) -> Void) {
        self.handler = handler
    }
}

private func watcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else {
        return
    }
    let box = Unmanaged<WatcherBox>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    var events: [WatchEvent] = []
    events.reserveCapacity(numEvents)
    for index in 0..<numEvents {
        var path = index < paths.count ? (paths[index] as? String ?? "") : ""
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        events.append(WatchEvent(path: path, flags: eventFlags[index], id: eventIds[index]))
    }
    box.handler(events)
}

func currentFileSystemEventId() -> FSEventStreamEventId {
    return FSEventsGetCurrentEventId()
}

/// FSEvents journal identity for the volume holding `path`. A different value
/// than the one saved with the index means stored event ids are meaningless.
func fileSystemEventsVolumeUUID(for path: String) -> String? {
    var info = stat()
    if stat(path, &info) != 0 {
        return nil
    }
    guard let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else {
        return nil
    }
    return CFUUIDCreateString(nil, uuid) as String
}

/// FSEvents only reports changes made through this Mac's kernel, so network
/// volumes (SMB/NFS/AFP) need periodic re-diffing instead. Nil when the path is
/// currently unavailable (unmounted share, unplugged drive).
func isLocalVolume(_ path: String) -> Bool? {
    var info = statfs()
    if statfs(path, &info) != 0 {
        return nil
    }
    return info.f_flags & UInt32(MNT_LOCAL) != 0
}
