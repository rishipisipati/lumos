import Foundation

/// Model Context Protocol server for `lumos mcp`: newline-delimited JSON-RPC 2.0
/// over stdin/stdout. Runs on the user's machine as a child of the AI client.

private let mcpDefaultLimit = 50
private let mcpMaxLimit = 1_000
private let mcpDefaultWaitSeconds = 10.0
private let mcpLatestVersion = "2025-06-18"
private let mcpSupportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
private let mcpServerVersion = "1.0.0"

/// How the server reaches the index. The CLI wires these to the Lumos socket.
struct MCPBackend {
    let find: (FindRequest) throws -> FindResult
    let status: () throws -> IndexState
}

enum RPCId: Codable, Equatable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
            return
        }
        self = .string(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number):
            try container.encode(number)
        case .string(let text):
            try container.encode(text)
        }
    }
}

enum RPCErrorCode: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
}

private struct RPCEnvelope: Decodable {
    let jsonrpc: String
    let id: RPCId?
    let method: String?
}

private struct InitializeMessage: Decodable {
    struct Params: Decodable {
        let protocolVersion: String
    }
    let params: Params
}

private struct ToolNameMessage: Decodable {
    struct Params: Decodable {
        let name: String
    }
    let params: Params
}

struct FindFilesArguments: Decodable {
    let query: String
    let within: [String]?
    let kind: ResultKind?
    let sort: ResultSort?
    let descending: Bool?
    let limit: Int?
    let offset: Int?
    let includeHidden: Bool?
    let details: Bool?
    let waitSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case query
        case within
        case kind
        case sort
        case descending
        case limit
        case offset
        case includeHidden = "include_hidden"
        case details
        case waitSeconds = "wait_seconds"
    }
}

private struct FindFilesMessage: Decodable {
    struct Params: Decodable {
        let arguments: FindFilesArguments
    }
    let params: Params
}

private struct RPCResult<Result: Encodable>: Encodable {
    let jsonrpc: String
    let id: RPCId
    let result: Result
}

private struct RPCErrorReply: Encodable {
    struct Body: Encodable {
        let code: Int
        let message: String
    }
    let id: RPCId?
    let error: Body

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case error
    }

    /// JSON-RPC requires `"id": null` when the request id is unknown.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        try container.encode(error, forKey: .error)
    }
}

private struct EmptyResult: Encodable {}

private struct InitializeResult: Encodable {
    struct Capabilities: Encodable {
        struct Tools: Encodable {
            let listChanged: Bool
        }
        let tools: Tools
    }
    struct ServerInfo: Encodable {
        let name: String
        let version: String
    }
    let protocolVersion: String
    let capabilities: Capabilities
    let serverInfo: ServerInfo
    let instructions: String
}

struct SchemaProperty: Encodable {
    struct Items: Encodable {
        let type: String
    }
    let type: String
    let description: String
    let enumValues: [String]?
    let items: Items?
    let minimum: Int?
    let maximum: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
        case items
        case minimum
        case maximum
    }
}

struct InputSchema: Encodable {
    let type: String
    let properties: [String: SchemaProperty]
    let required: [String]
    let additionalProperties: Bool
}

struct ToolDescription: Encodable {
    let name: String
    let description: String
    let inputSchema: InputSchema
}

private struct ToolsListResult: Encodable {
    let tools: [ToolDescription]
}

struct TextContent: Encodable {
    let type: String
    let text: String
}

struct ToolCallResult: Encodable {
    let content: [TextContent]
    let isError: Bool
}

private enum MCPCallError: Error {
    case invalidParams(String)
}

private func property(_ type: String, _ description: String) -> SchemaProperty {
    return SchemaProperty(type: type, description: description, enumValues: nil, items: nil, minimum: nil, maximum: nil)
}

let mcpTools: [ToolDescription] = [
    ToolDescription(
        name: "find_files",
        description: """
        Find files and folders on this Mac by NAME (never contents) in the always-current Lumos index of the \
        user's indexed folders (usually the home folder and /Applications). Answers in milliseconds, so prefer it \
        over find, mdfind or ls -R. Query syntax: words are ANDed in any order, case- and accent-insensitive; \
        a|b either; "exact phrase"; *.pdf or ext:pdf;docx; path:Clients/Acme matches the full path; size:>10mb; \
        dm:today, dm:thisweek, dm:2026-10-15. Output: '#' metadata lines, then one absolute path per line. \
        '# Index exact' with no matches means the item does not exist in the indexed folders; do not re-check \
        with find. Common words also match code files (for example in node_modules); narrow with ext:, within or kind.
        """,
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "query": property("string", "Search text in the syntax above. Empty lists everything (use with within)."),
                "within": SchemaProperty(
                    type: "array",
                    description: "Only results inside these folders (absolute or ~ paths).",
                    enumValues: nil,
                    items: SchemaProperty.Items(type: "string"),
                    minimum: nil,
                    maximum: nil
                ),
                "kind": SchemaProperty(type: "string", description: "files, folders, or any (default).", enumValues: ["any", "files", "folders"], items: nil, minimum: nil, maximum: nil),
                "sort": SchemaProperty(type: "string", description: "Order (default name).", enumValues: ResultSort.allCases.map(\.rawValue), items: nil, minimum: nil, maximum: nil),
                "descending": property("boolean", "Reverse the order. sort=modified with descending=true is newest first; sort=size is largest first."),
                "limit": SchemaProperty(type: "integer", description: "Results to return (default \(mcpDefaultLimit)). 0 returns only the count.", enumValues: nil, items: nil, minimum: 0, maximum: mcpMaxLimit),
                "offset": SchemaProperty(type: "integer", description: "Skip this many results (paging).", enumValues: nil, items: nil, minimum: 0, maximum: nil),
                "include_hidden": property("boolean", "Include hidden files and folders (excluded by default)."),
                "details": property("boolean", "Prefix each path with modified date, size and kind, tab separated."),
                "wait_seconds": property("number", "Wait up to this long for recent disk changes to be applied (default 10).")
            ],
            required: ["query"],
            additionalProperties: false
        )
    ),
    ToolDescription(
        name: "index_status",
        description: "Whether the Lumos index is exact, how many objects it holds, which folders are indexed, and whether the Lumos app or the background indexer serves it.",
        inputSchema: InputSchema(type: "object", properties: [:], required: [], additionalProperties: false)
    )
]

private let mcpInstructions = """
Lumos finds files and folders on this Mac by name in milliseconds. Use find_files for questions like \
"where is X", "does X exist", or "what changed today". It never reads file contents; use other tools for that.
"""

private func encodeLine<Value: Encodable>(_ value: Value) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    do {
        return try encoder.encode(value)
    } catch {
        fputs("lumos mcp: could not encode a reply: \(error.localizedDescription)\n", stderr)
        return Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Lumos could not encode the reply; see stderr.\"}}".utf8)
    }
}

private func errorLine(_ id: RPCId?, _ code: RPCErrorCode, _ message: String) -> Data {
    return encodeLine(RPCErrorReply(id: id, error: RPCErrorReply.Body(code: code.rawValue, message: message)))
}

private func resultLine<Result: Encodable>(_ id: RPCId, _ result: Result) -> Data {
    return encodeLine(RPCResult(jsonrpc: "2.0", id: id, result: result))
}

/// The reply line for one JSON-RPC message, or nil for notifications.
func handleMCPMessage(_ line: Data, backend: MCPBackend) -> Data? {
    let decoder = JSONDecoder()
    let envelope: RPCEnvelope
    do {
        envelope = try decoder.decode(RPCEnvelope.self, from: line)
    } catch {
        return errorLine(nil, .parseError, "Not a JSON-RPC message: \(error.localizedDescription)")
    }
    guard let method = envelope.method else {
        return nil
    }
    guard let id = envelope.id else {
        return nil
    }
    if envelope.jsonrpc != "2.0" {
        return errorLine(id, .invalidRequest, "jsonrpc must be \"2.0\"")
    }
    do {
        switch method {
        case "initialize":
            let requested = try decoder.decode(InitializeMessage.self, from: line).params.protocolVersion
            return resultLine(id, InitializeResult(
                protocolVersion: mcpSupportedVersions.contains(requested) ? requested : mcpLatestVersion,
                capabilities: InitializeResult.Capabilities(tools: InitializeResult.Capabilities.Tools(listChanged: false)),
                serverInfo: InitializeResult.ServerInfo(name: "lumos", version: mcpServerVersion),
                instructions: mcpInstructions
            ))
        case "ping":
            return resultLine(id, EmptyResult())
        case "tools/list":
            return resultLine(id, ToolsListResult(tools: mcpTools))
        case "tools/call":
            let name = try decoder.decode(ToolNameMessage.self, from: line).params.name
            switch name {
            case "find_files":
                let arguments = try decoder.decode(FindFilesMessage.self, from: line).params.arguments
                return resultLine(id, try callFindFiles(arguments, backend: backend))
            case "index_status":
                return resultLine(id, callIndexStatus(backend: backend))
            default:
                return errorLine(id, .invalidParams, "Unknown tool \(name). Available: \(mcpTools.map(\.name).joined(separator: ", ")).")
            }
        default:
            return errorLine(id, .methodNotFound, "Method \(method) is not supported.")
        }
    } catch MCPCallError.invalidParams(let message) {
        return errorLine(id, .invalidParams, message)
    } catch let error as DecodingError {
        return errorLine(id, .invalidParams, "Invalid parameters for \(method): \(describeDecodingError(error))")
    } catch {
        return errorLine(id, .internalError, error.localizedDescription)
    }
}

private func describeDecodingError(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, let context):
        return "missing \((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))"
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
        return "\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
    @unknown default:
        return error.localizedDescription
    }
}

private func toolError(_ message: String) -> ToolCallResult {
    return ToolCallResult(content: [TextContent(type: "text", text: message)], isError: true)
}

private func callFindFiles(_ arguments: FindFilesArguments, backend: MCPBackend) throws -> ToolCallResult {
    let limit = arguments.limit ?? mcpDefaultLimit
    let offset = arguments.offset ?? 0
    let waitSeconds = arguments.waitSeconds ?? mcpDefaultWaitSeconds
    if limit < 0 || limit > mcpMaxLimit {
        throw MCPCallError.invalidParams("limit must be between 0 and \(mcpMaxLimit); page with offset")
    }
    if offset < 0 {
        throw MCPCallError.invalidParams("offset must not be negative")
    }
    if waitSeconds < 0 {
        throw MCPCallError.invalidParams("wait_seconds must not be negative")
    }
    var within: [String] = []
    for path in arguments.within ?? [] {
        do {
            within.append(try resolveExistingPath(path))
        } catch {
            return toolError("within \(error.localizedDescription)")
        }
    }
    let request = FindRequest(
        query: arguments.query,
        limit: limit,
        offset: offset,
        sort: arguments.sort ?? .name,
        descending: arguments.descending ?? false,
        includeHidden: arguments.includeHidden ?? false,
        within: within,
        kind: arguments.kind ?? .any,
        waitSeconds: waitSeconds
    )
    let result: FindResult
    do {
        result = try backend.find(request)
    } catch {
        return toolError(error.localizedDescription)
    }
    let lines = findLines(result, request: request, style: .mcp, details: arguments.details ?? false)
    let text = limit == 0 ? lines.prefix(2).joined(separator: "\n") : lines.joined(separator: "\n")
    return ToolCallResult(content: [TextContent(type: "text", text: text)], isError: false)
}

private func callIndexStatus(backend: MCPBackend) -> ToolCallResult {
    do {
        let state = try backend.status()
        let text = "\(describeIndex(state, style: .mcp))\nIndexed folders: \(state.roots.joined(separator: ", "))"
        return ToolCallResult(content: [TextContent(type: "text", text: text)], isError: false)
    } catch {
        return toolError(error.localizedDescription)
    }
}

/// Serves MCP until stdin closes. Diagnostics go to stderr; stdout carries
/// only protocol messages.
func runMCPServer(backend: MCPBackend) -> Int32 {
    while let line = readLine(strippingNewline: true) {
        if line.allSatisfy(\.isWhitespace) {
            continue
        }
        if let reply = handleMCPMessage(Data(line.utf8), backend: backend) {
            FileHandle.standardOutput.write(reply + Data([0x0A]))
        }
    }
    return 0
}
