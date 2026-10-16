import Darwin
import Foundation

// Wire protocol between the `lumos` CLI and the process that owns the index
// (the app or the headless `lumos-index --serve` daemon). One newline-terminated
// JSON request per connection, answered by one newline-terminated JSON response.
// Shared by the CLI, so it must not depend on engine types.

enum ResultSort: String, Codable, CaseIterable, Sendable {
    case name
    case path
    case size
    case modified
}

enum ResultKind: String, Codable, Sendable {
    case any
    case files
    case folders
}

enum FoundKind: String, Codable, Sendable {
    case file
    case folder
    case package
    case symlink
}

enum IndexOwner: String, Codable, Sendable {
    case app
    case daemon
}

struct FindRequest: Codable, Equatable, Sendable {
    let query: String
    let limit: Int
    let offset: Int
    let sort: ResultSort
    let descending: Bool
    let includeHidden: Bool
    /// Absolute, symlink-resolved folders (or files) results must be inside.
    let within: [String]
    let kind: ResultKind
    /// How long to wait for pending file system changes to be applied.
    let waitSeconds: Double
}

struct IndexState: Codable, Equatable, Sendable {
    let phase: String
    /// True when every change macOS reported has been applied, so a missing
    /// result means the file does not exist under the indexed folders.
    let exact: Bool
    let objects: Int
    let roots: [String]
    let owner: IndexOwner
    let pid: Int32
    let problem: String?
}

struct FoundEntry: Codable, Equatable, Sendable {
    let path: String
    let kind: FoundKind
    let size: Int64
    let modified: Date
}

struct FindResult: Codable, Equatable, Sendable {
    let total: Int
    let offset: Int
    let entries: [FoundEntry]
    let index: IndexState
    let elapsedMs: Int
}

enum QueryRequest: Codable, Equatable, Sendable {
    case find(FindRequest)
    case status
    case shutdown
}

enum QueryResponse: Codable, Equatable, Sendable {
    case found(FindResult)
    case status(IndexState)
    case stopping
    case failure(String)
}

enum QueryClientError: Error, LocalizedError {
    case notRunning(String)
    case socketPathTooLong(String)
    case io(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notRunning(let path):
            return "No Lumos index is running (nothing is listening on \(path))."
        case .socketPathTooLong(let path):
            return "The Lumos socket path is too long for a Unix socket: \(path)"
        case .io(let detail):
            return "Lumos connection failed: \(detail)"
        case .badResponse(let detail):
            return "Lumos sent an unreadable response: \(detail)"
        }
    }
}

let maxQueryMessageBytes = 64 * 1024 * 1024

func lumosSupportFolder() throws -> URL {
    if let custom = ProcessInfo.processInfo.environment["LUMOS_HOME"], !custom.isEmpty {
        let folder = URL(fileURLWithPath: custom, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let folder = support.appendingPathComponent("Lumos", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

func querySocketPath(folder: URL) -> String {
    return folder.appendingPathComponent("lumos.sock").path
}

func makeQueryEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

func makeQueryDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

func makeUnixAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    if bytes.count >= capacity {
        throw QueryClientError.socketPathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    return address
}

func configureQuerySocket(_ descriptor: Int32, timeout: TimeInterval) {
    var enabled: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
}

func writeQueryMessage(_ descriptor: Int32, _ data: Data) throws {
    var payload = data
    payload.append(0x0A)
    try payload.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                throw QueryClientError.io("write failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }
}

/// Reads up to the first newline. Throws if the peer closes early or the
/// message exceeds `maxQueryMessageBytes`.
func readQueryMessage(_ descriptor: Int32) throws -> Data {
    var message = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
        if count < 0 {
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw QueryClientError.io("timed out waiting for a reply")
            }
            throw QueryClientError.io("read failed: \(String(cString: strerror(errno)))")
        }
        if count == 0 {
            throw QueryClientError.io("connection closed before a full message arrived")
        }
        if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
            message.append(contentsOf: chunk[0..<newline])
            return message
        }
        message.append(contentsOf: chunk[0..<count])
        if message.count > maxQueryMessageBytes {
            throw QueryClientError.io("message larger than \(maxQueryMessageBytes) bytes")
        }
    }
}

func connectQuerySocket(_ path: String, timeout: TimeInterval) throws -> Int32 {
    var address = try makeUnixAddress(path)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    if descriptor < 0 {
        throw QueryClientError.io("socket failed: \(String(cString: strerror(errno)))")
    }
    configureQuerySocket(descriptor, timeout: timeout)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if result != 0 {
        let code = errno
        close(descriptor)
        if code == ENOENT || code == ECONNREFUSED {
            throw QueryClientError.notRunning(path)
        }
        throw QueryClientError.io("connect to \(path) failed: \(String(cString: strerror(code)))")
    }
    return descriptor
}

func sendQuery(_ request: QueryRequest, socketPath: String, timeout: TimeInterval) throws -> QueryResponse {
    let descriptor = try connectQuerySocket(socketPath, timeout: timeout)
    defer { close(descriptor) }
    try writeQueryMessage(descriptor, try makeQueryEncoder().encode(request))
    let reply = try readQueryMessage(descriptor)
    do {
        return try makeQueryDecoder().decode(QueryResponse.self, from: reply)
    } catch {
        throw QueryClientError.badResponse(error.localizedDescription)
    }
}
