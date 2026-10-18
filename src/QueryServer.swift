import Darwin
import Foundation

enum FindError: Error, LocalizedError, Equatable {
    case notIndexed(String)
    case outsideRoots(String, [String])
    case invalidWindow(String)

    var errorDescription: String? {
        switch self {
        case .notIndexed(let path):
            return "\(path) is not in the index (it may not exist, or Lumos skips it: Library, caches, Trash, app bundle contents, recents)."
        case .outsideRoots(let path, let roots):
            return "\(path) is outside the indexed folders (\(roots.joined(separator: ", "))). Add it in Lumos → File → Add Folder to Index."
        case .invalidWindow(let detail):
            return detail
        }
    }
}

enum QueryServerError: Error, LocalizedError {
    case setupFailed(String)
    case takeoverFailed(String)

    var errorDescription: String? {
        switch self {
        case .setupFailed(let detail):
            return "Could not start the Lumos query socket: \(detail)"
        case .takeoverFailed(let detail):
            return "Could not take over the index from the background indexer: \(detail)"
        }
    }
}

/// Runs a find against one consistent view of the index. Paths are built only
/// for the returned window.
func executeFind(_ data: IndexData, request: FindRequest, trigrams: NameTrigramIndex?) throws -> (total: Int, entries: [FoundEntry]) {
    if request.limit < 0 || request.offset < 0 {
        throw FindError.invalidWindow("limit and offset must not be negative")
    }
    let kindFilter: String
    switch request.kind {
    case .any:
        kindFilter = ""
    case .files:
        kindFilter = " file:"
    case .folders:
        kindFilter = " folder:"
    }
    let ids = searchIndex(
        data,
        query: parseQuery(request.query + kindFilter),
        showHidden: request.includeHidden,
        sortColumn: sortColumn(for: request.sort),
        ascending: !request.descending,
        trigrams: trigrams
    )
    let scoped: [Int32]
    if request.within.isEmpty {
        scoped = ids
    } else {
        let mask = try scopeMask(data, within: request.within)
        scoped = ids.filter { mask[Int($0)] }
    }
    let entries = scoped.dropFirst(request.offset).prefix(request.limit).map { foundEntry(data, $0) }
    return (scoped.count, entries)
}

/// True for every entry inside one of `within` (a scoped file matches itself; a
/// scoped folder is not its own result). Relies on parent id < child id.
func scopeMask(_ data: IndexData, within: [String]) throws -> [Bool] {
    var mask = [Bool](repeating: false, count: data.count)
    var scopeFolders: [Int32] = []
    for path in within {
        switch data.lookup(path: path) {
        case .found(let id):
            mask[Int(id)] = true
            if data.isDirectory(id) {
                scopeFolders.append(id)
            }
        case .missing:
            throw FindError.notIndexed(path)
        case .outsideRoots:
            throw FindError.outsideRoots(path, data.roots.map(\.path))
        }
    }
    data.parent.withUnsafeBufferPointer { parents in
        mask.withUnsafeMutableBufferPointer { inside in
            for index in 0..<inside.count where !inside[index] {
                let parent = parents[index]
                if parent >= 0 && inside[Int(parent)] {
                    inside[index] = true
                }
            }
        }
    }
    for id in scopeFolders where !isInsideOtherScope(data, id: id, scopes: scopeFolders) {
        mask[Int(id)] = false
    }
    return mask
}

/// True when a scope folder sits inside another scope folder, so it stays a result.
private func isInsideOtherScope(_ data: IndexData, id: Int32, scopes: [Int32]) -> Bool {
    var current = data.parent[Int(id)]
    while current >= 0 {
        if scopes.contains(current) {
            return true
        }
        current = data.parent[Int(current)]
    }
    return false
}

func foundEntry(_ data: IndexData, _ id: Int32) -> FoundEntry {
    let flags = data.flags[Int(id)]
    let kind: FoundKind
    if flags & EntryFlag.directory != 0 {
        kind = flags & EntryFlag.opaque != 0 ? .package : .folder
    } else if flags & EntryFlag.symlink != 0 {
        kind = .symlink
    } else {
        kind = .file
    }
    return FoundEntry(
        path: data.fullPath(id),
        kind: kind,
        size: data.size[Int(id)],
        modified: Date(timeIntervalSince1970: TimeInterval(data.modified[Int(id)]))
    )
}

private func sortColumn(for sort: ResultSort) -> SortColumn {
    switch sort {
    case .name:
        return .name
    case .path:
        return .path
    case .size:
        return .size
    case .modified:
        return .modified
    }
}

func currentIndexState(_ service: IndexService, owner: IndexOwner, exact: Bool) -> IndexState {
    let status = service.status()
    return IndexState(
        phase: status.phase.rawValue,
        exact: exact,
        objects: status.objectCount,
        roots: service.store.read { $0.roots.map(\.path) },
        owner: owner,
        pid: getpid(),
        problem: status.problem
    )
}

/// Answers one request. Queries are never logged or stored.
func handleQueryRequest(
    _ request: QueryRequest,
    service: IndexService,
    owner: IndexOwner,
    shutdown: () -> Void
) -> QueryResponse {
    switch request {
    case .status:
        let exact = service.isIdle() && service.status().phase == .live
        return .status(currentIndexState(service, owner: owner, exact: exact))
    case .shutdown:
        if owner == .app {
            return .failure("The Lumos app owns the index; it stops when the app quits.")
        }
        shutdown()
        return .stopping
    case .find(let find):
        let exact = service.waitUntilExact(seconds: find.waitSeconds)
        let started = DispatchTime.now()
        do {
            let found = try service.store.readForSearch { data, _, trigrams in
                try executeFind(data, request: find, trigrams: trigrams)
            }
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            return .found(FindResult(
                total: found.total,
                offset: find.offset,
                entries: found.entries,
                index: currentIndexState(service, owner: owner, exact: exact),
                elapsedMs: elapsed
            ))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

/// Unix-socket listener (mode 0600, so only this user can query). The caller
/// must hold the index lock, which makes removing a stale socket file safe.
final class QueryServer {
    private let socketPath: String
    private let handler: (QueryRequest) -> QueryResponse
    private let acceptQueue = DispatchQueue(label: "lumos.query.accept", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "lumos.query.connections", qos: .userInitiated, attributes: .concurrent)
    private var source: DispatchSourceRead?

    init(socketPath: String, handler: @escaping (QueryRequest) -> QueryResponse) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        var address = try makeUnixAddress(socketPath)
        if unlink(socketPath) != 0 && errno != ENOENT {
            throw QueryServerError.setupFailed("cannot remove stale \(socketPath): \(String(cString: strerror(errno)))")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        if descriptor < 0 {
            throw QueryServerError.setupFailed("socket: \(String(cString: strerror(errno)))")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if bound != 0 {
            let code = errno
            close(descriptor)
            throw QueryServerError.setupFailed("bind \(socketPath): \(String(cString: strerror(code)))")
        }
        if chmod(socketPath, 0o600) != 0 || listen(descriptor, 64) != 0 {
            let code = errno
            close(descriptor)
            unlink(socketPath)
            throw QueryServerError.setupFailed("\(socketPath): \(String(cString: strerror(code)))")
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        readSource.setEventHandler { [weak self] in
            self?.acceptPending(descriptor)
        }
        readSource.setCancelHandler {
            close(descriptor)
        }
        source = readSource
        readSource.resume()
    }

    func stop() {
        guard let current = source else {
            return
        }
        source = nil
        current.cancel()
        unlink(socketPath)
    }

    private func acceptPending(_ descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    fputs("Lumos: query socket accept failed: \(String(cString: strerror(errno)))\n", stderr)
                }
                return
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            configureQuerySocket(client, timeout: 10)
            connectionQueue.async { [weak self] in
                self?.serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        let response: QueryResponse
        do {
            let message = try readQueryMessage(client)
            response = handler(try makeQueryDecoder().decode(QueryRequest.self, from: message))
        } catch {
            response = .failure("Bad request: \(error.localizedDescription)")
        }
        do {
            try writeQueryMessage(client, try makeQueryEncoder().encode(response))
        } catch {
            fputs("Lumos: could not send a query reply: \(error.localizedDescription)\n", stderr)
        }
    }
}

/// Serves queries for `service` on its index folder's socket. `onRequest` runs
/// before each request (the daemon uses it to track idleness).
func startQueryServer(
    _ service: IndexService,
    owner: IndexOwner,
    onRequest: @escaping () -> Void,
    shutdown: @escaping () -> Void
) throws -> QueryServer {
    let server = QueryServer(socketPath: querySocketPath(folder: service.indexFolder)) { request in
        onRequest()
        return handleQueryRequest(request, service: service, owner: owner, shutdown: shutdown)
    }
    try server.start()
    return server
}

/// When a headless daemon owns the index, asks it to save and exit so the app
/// can take over. Returns without doing anything when nothing is listening or
/// another app instance owns it (its lock then reports the conflict).
func retireBackgroundIndexer(folder: URL) throws {
    let socketPath = querySocketPath(folder: folder)
    let response: QueryResponse
    do {
        response = try sendQuery(.status, socketPath: socketPath, timeout: 5)
    } catch QueryClientError.notRunning {
        return
    }
    guard case .status(let state) = response, state.owner == .daemon else {
        return
    }
    let reply = try sendQuery(.shutdown, socketPath: socketPath, timeout: 5)
    guard case .stopping = reply else {
        throw QueryServerError.takeoverFailed("unexpected reply \(reply)")
    }
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if kill(state.pid, 0) != 0 && errno == ESRCH {
            return
        }
        usleep(50_000)
    }
    throw QueryServerError.takeoverFailed("process \(state.pid) did not exit within 30 seconds")
}
