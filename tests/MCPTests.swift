import Foundation

private struct ReplyError: Decodable {
    let code: Int
    let message: String
}

private struct InitializeReply: Decodable {
    struct Result: Decodable {
        struct ServerInfo: Decodable {
            let name: String
        }
        let protocolVersion: String
        let serverInfo: ServerInfo
    }
    let result: Result
}

private struct ToolsReply: Decodable {
    struct Result: Decodable {
        struct Tool: Decodable {
            struct Schema: Decodable {
                let type: String
                let required: [String]
            }
            let name: String
            let inputSchema: Schema
        }
        let tools: [Tool]
    }
    let result: Result
}

private struct CallReply: Decodable {
    struct Result: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String
        }
        let content: [Content]
        let isError: Bool
    }
    let id: RPCId
    let result: Result
}

private struct ErrorReply: Decodable {
    let id: RPCId?
    let error: ReplyError
}

private func decodeReply<Reply: Decodable>(_ type: Reply.Type, _ data: Data?) throws -> Reply {
    guard let data else {
        throw ExpectationFailure.failed("expected a reply")
    }
    return try JSONDecoder().decode(type, from: data)
}

private func message(_ json: String) -> Data {
    return Data(json.utf8)
}

func mcpSuite() -> TestSuite {
    let suite = TestSuite(name: "MCP")
    let exactState = IndexState(phase: "live", exact: true, objects: 12, roots: ["/r"], owner: .app, pid: 1, problem: nil)

    func backend(_ captured: @escaping (FindRequest) -> Void) -> MCPBackend {
        return MCPBackend(
            find: { request in
                captured(request)
                return FindResult(
                    total: 10,
                    offset: request.offset,
                    entries: [FoundEntry(path: "/r/Clients/Acme/brief.docx", kind: .file, size: 2048, modified: Date(timeIntervalSince1970: 1_700_000_000))],
                    index: exactState,
                    elapsedMs: 1
                )
            },
            status: { exactState }
        )
    }

    suite.test("initialize negotiates the protocol version") {
        let idle = backend { _ in }
        let known = try decodeReply(InitializeReply.self, handleMCPMessage(message(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        ), backend: idle))
        try expectEqual(known.result.protocolVersion, "2025-03-26", "echo a supported version")
        try expectEqual(known.result.serverInfo.name, "lumos", "server name")
        let future = try decodeReply(InitializeReply.self, handleMCPMessage(message(
            #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#
        ), backend: idle))
        try expectEqual(future.result.protocolVersion, "2025-06-18", "offer the latest otherwise")
        try expect(handleMCPMessage(message(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), backend: idle) == nil, "notifications get no reply")
    }

    suite.test("tools/list describes find_files and index_status") {
        let tools = try decodeReply(ToolsReply.self, handleMCPMessage(message(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#), backend: backend { _ in }))
        try expectEqual(tools.result.tools.map(\.name), ["find_files", "index_status"], "tool names")
        try expectEqual(tools.result.tools[0].inputSchema.type, "object", "schema type")
        try expectEqual(tools.result.tools[0].inputSchema.required, ["query"], "query required")
    }

    suite.test("find_files maps arguments and returns paths with index state") {
        let folder = try makeTempFolder("mcp-within")
        defer { try? FileManager.default.removeItem(at: folder) }
        var seen: FindRequest?
        let reply = try decodeReply(CallReply.self, handleMCPMessage(message("""
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"find_files","arguments":\
        {"query":"brief","within":["\(folder.path)"],"kind":"files","sort":"modified","descending":true,\
        "limit":1,"offset":2,"include_hidden":true,"wait_seconds":0}}}
        """), backend: backend { seen = $0 }))
        try expectEqual(reply.id, .number(3), "id echoed")
        try expect(!reply.result.isError, "not an error")
        try expectEqual(seen, FindRequest(
            query: "brief", limit: 1, offset: 2, sort: .modified, descending: true,
            includeHidden: true, within: [folder.path], kind: .files, waitSeconds: 0
        ), "request mapped")
        let text = reply.result.content[0].text
        try expect(text.contains("# Index exact"), "exactness line")
        try expect(text.contains("/r/Clients/Acme/brief.docx"), "path listed")
        try expect(text.contains("call again with offset 3"), "paging hint uses tool arguments")

        let count = try decodeReply(CallReply.self, handleMCPMessage(message(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"find_files","arguments":{"query":"brief","limit":0}}}"#
        ), backend: backend { _ in }))
        try expect(!count.result.content[0].text.contains("/r/Clients"), "limit 0 returns only the count")
    }

    suite.test("errors are reported, never swallowed") {
        let idle = backend { _ in }
        let parse = try decodeReply(ErrorReply.self, handleMCPMessage(message("{not json"), backend: idle))
        try expectEqual(parse.error.code, -32700, "parse error")
        try expect(parse.id == nil, "null id for unparseable input")
        let method = try decodeReply(ErrorReply.self, handleMCPMessage(message(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#), backend: idle))
        try expectEqual(method.error.code, -32601, "unknown method")
        let tool = try decodeReply(ErrorReply.self, handleMCPMessage(message(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#), backend: idle))
        try expectEqual(tool.error.code, -32602, "unknown tool")
        let limit = try decodeReply(ErrorReply.self, handleMCPMessage(message(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"find_files","arguments":{"query":"x","limit":5000}}}"#
        ), backend: idle))
        try expectEqual(limit.error.code, -32602, "limit out of range")
        let missing = try decodeReply(ErrorReply.self, handleMCPMessage(message(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"find_files","arguments":{}}}"#
        ), backend: idle))
        try expect(missing.error.message.contains("query"), "names the missing argument")

        let down = MCPBackend(find: { _ in throw QueryClientError.notRunning("/x/lumos.sock") }, status: { throw QueryClientError.notRunning("/x/lumos.sock") })
        let failed = try decodeReply(CallReply.self, handleMCPMessage(message(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"find_files","arguments":{"query":"x"}}}"#
        ), backend: down))
        try expect(failed.result.isError, "backend failure is a tool error")
        try expect(failed.result.content[0].text.contains("lumos.sock"), "with the reason")
        let badPath = try decodeReply(CallReply.self, handleMCPMessage(message(
            #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"find_files","arguments":{"query":"x","within":["/no/such/folder"]}}}"#
        ), backend: idle))
        try expect(badPath.result.isError && badPath.result.content[0].text.contains("/no/such/folder"), "bad within path")
    }

    return suite
}
