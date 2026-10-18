import Darwin
import Foundation

private let defaultLimit = 50
private let maxLimit = 100_000
private let defaultWaitSeconds = 10.0
private let daemonStartTimeout: TimeInterval = 20

enum OutputFormat {
    case paths
    case long
    case json
    case count
}

struct FindOptions {
    let request: FindRequest
    let format: OutputFormat
    let autoStart: Bool
}

enum CLICommand {
    case find(FindOptions)
    case status(json: Bool, autoStart: Bool)
    case stop
    case guide
    case mcp
    case help
}

enum CLIError: Error, LocalizedError {
    case usage(String)
    case daemonMissing(String)
    case daemonFailed(String)
    case unexpectedReply(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .usage(let detail):
            return "\(detail)\nRun `lumos help` for usage."
        case .daemonMissing(let path):
            return "The background indexer is missing (expected \(path)). Rebuild with `make cli`."
        case .daemonFailed(let detail):
            return "The background indexer failed to start: \(detail)"
        case .unexpectedReply(let detail):
            return "Unexpected reply from Lumos: \(detail)"
        case .server(let message):
            return message
        }
    }
}

/// JSON shape printed by `lumos find --json`.
struct FindOutput: Encodable {
    let query: String
    let total: Int
    let offset: Int
    let returned: Int
    let nextOffset: Int?
    let index: IndexState
    let results: [FoundEntry]
}

@main
struct LumosCLI {
    static func main() {
        do {
            exit(try run(Array(CommandLine.arguments.dropFirst())))
        } catch {
            fputs("lumos: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }
}

func run(_ arguments: [String]) throws -> Int32 {
    switch try parseCommand(arguments) {
    case .help:
        print(helpText)
        return 0
    case .guide:
        print(guideText)
        return 0
    case .mcp:
        return runMCPServer(backend: MCPBackend(
            find: { find in
                let response = try request(.find(find), autoStart: true, timeout: find.waitSeconds + 60)
                guard case .found(let result) = response else {
                    throw replyError(response)
                }
                return result
            },
            status: {
                let response = try request(.status, autoStart: true, timeout: 15)
                guard case .status(let state) = response else {
                    throw replyError(response)
                }
                return state
            }
        ))
    case .status(let json, let autoStart):
        let response = try request(.status, autoStart: autoStart, timeout: 15)
        guard case .status(let state) = response else {
            throw replyError(response)
        }
        if json {
            print(try encodeJSON(state))
        } else {
            print("Lumos index: \(describeIndex(state, style: .cli))")
            print("Indexed folders: \(state.roots.joined(separator: ", "))")
        }
        return 0
    case .stop:
        let response: QueryResponse
        do {
            response = try sendQuery(.shutdown, socketPath: querySocketPath(folder: try lumosSupportFolder()), timeout: 15)
        } catch QueryClientError.notRunning {
            print("Lumos is not running.")
            return 0
        }
        guard case .stopping = response else {
            throw replyError(response)
        }
        print("Stopped the Lumos background indexer.")
        return 0
    case .find(let options):
        let response = try request(.find(options.request), autoStart: options.autoStart, timeout: options.request.waitSeconds + 60)
        guard case .found(let result) = response else {
            throw replyError(response)
        }
        try printFind(result, options: options)
        return result.total == 0 ? 1 : 0
    }
}

private func replyError(_ response: QueryResponse) -> CLIError {
    if case .failure(let message) = response {
        return .server(message)
    }
    return .unexpectedReply("\(response)")
}

// MARK: - Arguments

func parseCommand(_ arguments: [String]) throws -> CLICommand {
    guard let first = arguments.first else {
        return .help
    }
    let rest = Array(arguments.dropFirst())
    switch first {
    case "help", "-h", "--help":
        return .help
    case "guide":
        return .guide
    case "status":
        return .status(json: rest.contains("--json"), autoStart: !rest.contains("--no-start"))
    case "stop":
        return .stop
    case "mcp":
        return .mcp
    case "find":
        return .find(try parseFind(rest))
    default:
        return .find(try parseFind(arguments))
    }
}

func parseFind(_ arguments: [String]) throws -> FindOptions {
    var terms: [String] = []
    var limit = defaultLimit
    var offset = 0
    var sort = ResultSort.name
    var descending = false
    var includeHidden = false
    var within: [String] = []
    var kind = ResultKind.any
    var waitSeconds = defaultWaitSeconds
    var format = OutputFormat.paths
    var autoStart = true
    var literal = false

    var queue = arguments[...]
    func value(for option: String) throws -> String {
        guard let next = queue.popFirst() else {
            throw CLIError.usage("\(option) needs a value")
        }
        return next
    }
    while let raw = queue.popFirst() {
        if literal || !raw.hasPrefix("-") || raw == "-" {
            terms.append(raw)
            continue
        }
        var option = raw
        if raw.hasPrefix("--"), let equals = raw.firstIndex(of: "=") {
            option = String(raw[raw.startIndex..<equals])
            queue.insert(String(raw[raw.index(after: equals)...]), at: queue.startIndex)
        }
        switch option {
        case "--":
            literal = true
        case "-n", "--limit":
            limit = try integer(try value(for: option), option: option)
        case "--offset":
            offset = try integer(try value(for: option), option: option)
        case "--sort":
            let name = try value(for: option)
            guard let parsed = ResultSort(rawValue: name) else {
                throw CLIError.usage("--sort must be one of \(ResultSort.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            sort = parsed
        case "--desc":
            descending = true
        case "--newest":
            sort = .modified
            descending = true
        case "--largest":
            sort = .size
            descending = true
        case "--in":
            do {
                within.append(try resolveExistingPath(try value(for: option)))
            } catch let error as PathResolutionError {
                throw CLIError.usage("--in \(error.localizedDescription)")
            }
        case "--files":
            kind = .files
        case "--folders":
            kind = .folders
        case "--hidden":
            includeHidden = true
        case "--wait":
            guard let seconds = Double(try value(for: option)), seconds >= 0 else {
                throw CLIError.usage("--wait needs a number of seconds")
            }
            waitSeconds = seconds
        case "--json":
            format = .json
        case "--long":
            format = .long
        case "--count":
            format = .count
        case "--no-start":
            autoStart = false
        default:
            throw CLIError.usage("Unknown option \(raw). Put search terms that start with '-' after --.")
        }
    }
    if limit > maxLimit {
        throw CLIError.usage("--limit must be at most \(maxLimit); page with --offset")
    }
    let request = FindRequest(
        query: terms.joined(separator: " "),
        limit: format == .count ? 0 : limit,
        offset: offset,
        sort: sort,
        descending: descending,
        includeHidden: includeHidden,
        within: within,
        kind: kind,
        waitSeconds: waitSeconds
    )
    return FindOptions(request: request, format: format, autoStart: autoStart)
}

private func integer(_ text: String, option: String) throws -> Int {
    guard let value = Int(text), value >= 0 else {
        throw CLIError.usage("\(option) needs a whole number")
    }
    return value
}

// MARK: - Talking to the index

func request(_ query: QueryRequest, autoStart: Bool, timeout: TimeInterval) throws -> QueryResponse {
    let folder = try lumosSupportFolder()
    let socketPath = querySocketPath(folder: folder)
    do {
        return try sendQuery(query, socketPath: socketPath, timeout: timeout)
    } catch QueryClientError.notRunning {
        if !autoStart {
            throw QueryClientError.notRunning(socketPath)
        }
        try startDaemon(folder: folder, socketPath: socketPath)
        return try sendQuery(query, socketPath: socketPath, timeout: timeout)
    }
}

private func startDaemon(folder: URL, socketPath: String) throws {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        throw CLIError.daemonMissing("lumos-index next to the lumos executable")
    }
    let binary = executable.deletingLastPathComponent().appendingPathComponent("lumos-index").path
    if !FileManager.default.isExecutableFile(atPath: binary) {
        throw CLIError.daemonMissing(binary)
    }
    let logPath = folder.appendingPathComponent("daemon.log").path
    fputs("lumos: starting the background indexer (loads the saved index, or scans your folders on first run)\n", stderr)
    let pid = try spawnDetached(binary, arguments: ["--serve"], logPath: logPath)
    let deadline = Date().addingTimeInterval(daemonStartTimeout)
    while Date() < deadline {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            throw CLIError.daemonFailed(log.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            _ = try sendQuery(.status, socketPath: socketPath, timeout: 5)
            return
        } catch QueryClientError.notRunning {
            usleep(50_000)
        }
    }
    throw CLIError.daemonFailed("not listening after \(Int(daemonStartTimeout)) seconds; see \(logPath)")
}

/// Starts `binary` in its own session with stdin from /dev/null, output to
/// `logPath`, and no other inherited descriptors, so a caller reading this
/// process's output through a pipe is never held open by the daemon.
private func spawnDetached(_ binary: String, arguments: [String], logPath: String) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    let argv: [UnsafeMutablePointer<CChar>?] = ([binary] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, binary, &actions, &attributes, argv, environ)
    if result != 0 {
        throw CLIError.daemonFailed("\(binary): \(String(cString: strerror(result)))")
    }
    return pid
}

// MARK: - Output

func printFind(_ result: FindResult, options: FindOptions) throws {
    let request = options.request
    switch options.format {
    case .json:
        let next = result.offset + result.entries.count
        print(try encodeJSON(FindOutput(
            query: request.query,
            total: result.total,
            offset: result.offset,
            returned: result.entries.count,
            nextOffset: next < result.total ? next : nil,
            index: result.index,
            results: result.entries
        )))
    case .count:
        print(result.total)
        print("# \(describeIndex(result.index, style: .cli))")
    case .paths, .long:
        for line in findLines(result, request: request, style: .cli, details: options.format == .long) {
            print(line)
        }
    }
}

private func encodeJSON<Value: Encodable>(_ value: Value) throws -> String {
    let data = try makeQueryEncoder().encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
        throw CLIError.unexpectedReply("JSON output is not UTF-8")
    }
    return text
}

// MARK: - Help

let helpText = """
lumos: instant filename search over the folders Lumos indexes.

Usage:
  lumos find QUERY [options]     (or just: lumos QUERY [options])
  lumos status [--json]
  lumos stop                     stop the background indexer (not the app)
  lumos guide                    instructions to paste into an agent's AGENTS.md
  lumos mcp                      run as an MCP server over stdio (for Claude, Cursor, and others)

Find options:
  --in PATH        only results inside PATH (repeatable)
  --files          files only            --folders     folders only
  --newest         newest first          --largest     largest first
  --sort name|path|size|modified [--desc]
  -n, --limit N    results to print (default \(defaultLimit))
  --offset N       skip the first N results (paging)
  --count          print only the number of matches
  --long           date, size, kind and path, tab separated
  --json           structured output
  --hidden         include hidden files
  --wait SECONDS   wait up to this long for pending disk changes (default \(Int(defaultWaitSeconds)))
  --no-start       fail instead of starting the background indexer
  --               everything after this is search text

Query syntax: words are ANDed; a|b either; "exact phrase"; *.pdf or ext:pdf;docx;
path:Clients/Acme; size:>10mb; dm:today, dm:thisweek, dm:2026-10-15; file: or folder:.

Exit codes: 0 matches, 1 no matches, 2 error.
"""

let guideText = """
## Finding files on this Mac: use `lumos`

`lumos` searches an always-current index of every file and folder NAME in the
user's indexed folders (usually the home folder and /Applications). It answers in
milliseconds, so prefer it over `find`, `fd`, `mdfind` or `ls -R` for locating files.
It does not search file contents.

    lumos find QUERY [options]

Output: one absolute path per line. Lines starting with `#` are metadata: the
match count and whether the index is exact.

Query (case- and accent-insensitive, matches file and folder names):
- `engagement letter`: names containing both words, in any order
- `'"engagement letter"'`: the exact phrase (inner quotes reach Lumos)
- `smith|jones`: either word
- `*.pdf` or `ext:pdf;docx`: by extension
- `path:Clients/Acme`: text anywhere in the full path
- `size:>10mb`, `dm:today`, `dm:thisweek`, `dm:2026-10-15`: size and date modified

Options:
- `--in PATH`: only inside a folder (repeatable). Cheaper than a broad query.
- `--files` / `--folders`
- `--newest`, `--largest`, or `--sort name|path|size|modified [--desc]`
- `-n N` and `--offset N`: page through results (default 50 per call)
- `--count`: only the number of matches
- `--long`: date, size, kind and path (tab separated); `--json`: structured
- `--hidden`: include dotfiles (excluded by default)

Reading results:
- `# Index exact`: every change on disk has been applied. "No matches" then
  means the item does not exist in the indexed folders. Do not re-check with `find`.
- `# Index NOT exact`: Lumos is still catching up. Retry with `--wait 60`.
- Exit codes: 0 matches, 1 no matches, 2 error (message on stderr).

Not indexed: file contents, ~/Library, caches, Trash, the inside of app bundles,
and macOS recents lists. Use `lumos status` to see the indexed folders.

Tips:
- Common words also match code files (e.g. `RESUME_EVENT.js` in node_modules).
  Add `ext:pdf;docx` or `--in PATH` to keep only documents, `--files` to drop folders.
- Fall back to `find`, `mdfind` or your own file search only when `lumos` is
  missing, exits 2, or the folder is not indexed. Use `rg` for file contents.
- In a sandboxed shell `lumos` may report that no index is running because the
  sandbox blocks its socket. Run it outside the sandbox, or use the MCP server
  (`lumos mcp`, tools `find_files` and `index_status`).

Examples:
    lumos find engagement letter --in ~/Documents/Clients --newest -n 10
    lumos find resume 'ext:pdf;docx;pages' --newest -n 100
    lumos find 'ext:pdf;docx' path:Acme dm:thisweek --long
    lumos find --folders "matter 2024" --count
"""
