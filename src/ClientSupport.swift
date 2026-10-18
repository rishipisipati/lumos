import Darwin
import Foundation

/// Who reads the text: the `lumos` command line or an MCP client. Only the
/// hints differ (option names vs tool argument names).
enum ClientStyle {
    case cli
    case mcp

    var hiddenHint: String {
        switch self {
        case .cli:
            return "add --hidden"
        case .mcp:
            return "set include_hidden"
        }
    }

    var waitHint: String {
        switch self {
        case .cli:
            return "retry with --wait 60"
        case .mcp:
            return "retry with wait_seconds 60"
        }
    }

    func nextPageHint(_ offset: Int) -> String {
        switch self {
        case .cli:
            return "rerun with --offset \(offset)"
        case .mcp:
            return "call again with offset \(offset)"
        }
    }
}

enum PathResolutionError: Error, LocalizedError {
    case unresolvable(String, String)

    var errorDescription: String? {
        switch self {
        case .unresolvable(let path, let reason):
            return "\(path): \(reason)"
        }
    }
}

/// Absolute, symlink-resolved path, as stored in the index.
func resolveExistingPath(_ raw: String) throws -> String {
    let expanded = (raw as NSString).expandingTildeInPath
    let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    guard let resolved = realpath(absolute, nil) else {
        throw PathResolutionError.unresolvable(raw, String(cString: strerror(errno)))
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// `#` header lines, one path per entry (tab-separated details when
/// `details`), and a paging hint.
func findLines(_ result: FindResult, request: FindRequest, style: ClientStyle, details: Bool) -> [String] {
    var lines = ["# \(describeMatches(result, request: request, style: style))", "# \(describeIndex(result.index, style: style))"]
    for entry in result.entries {
        if details {
            let size = entry.kind == .file ? formatFileSize(entry.size, isDirectory: false) : "-"
            lines.append("\(formatModifiedDate(entry.modified.timeIntervalSince1970))\t\(size)\t\(entry.kind.rawValue)\t\(entry.path)")
        } else {
            lines.append(entry.path)
        }
    }
    let shown = result.offset + result.entries.count
    if shown < result.total {
        lines.append("# \(formatCount(result.total - shown)) more: \(style.nextPageHint(shown))")
    }
    return lines
}

func describeMatches(_ result: FindResult, request: FindRequest, style: ClientStyle) -> String {
    let subject = request.query.isEmpty ? "" : " for \"\(request.query)\""
    let scope = request.within.isEmpty ? "" : " in \(request.within.joined(separator: ", "))"
    let hiddenNote = request.includeHidden ? "" : " (hidden files excluded; \(style.hiddenHint))"
    if result.total == 0 {
        let place = request.within.isEmpty ? "in the indexed folders" : "there"
        let conclusion = result.index.exact ? ". No such item exists \(place)" : ""
        return "No matches\(subject)\(scope)\(hiddenNote)\(conclusion)."
    }
    let noun = result.total == 1 ? "match" : "matches"
    var text = "\(formatCount(result.total)) \(noun)\(subject)\(scope), \(describeOrder(request))"
    if !result.entries.isEmpty {
        text += ", showing \(formatCount(result.offset + 1))–\(formatCount(result.offset + result.entries.count))"
    } else if request.limit > 0 {
        text += ", none at offset \(formatCount(result.offset))"
    }
    return text + "."
}

private func describeOrder(_ request: FindRequest) -> String {
    switch (request.sort, request.descending) {
    case (.name, false):
        return "by name"
    case (.name, true):
        return "by name (Z–A)"
    case (.path, false):
        return "by folder"
    case (.path, true):
        return "by folder (Z–A)"
    case (.size, false):
        return "smallest first"
    case (.size, true):
        return "largest first"
    case (.modified, false):
        return "oldest first"
    case (.modified, true):
        return "newest first"
    }
}

func describeIndex(_ state: IndexState, style: ClientStyle) -> String {
    var text: String
    if state.exact {
        text = "Index exact"
    } else {
        text = "Index NOT exact (\(describePhase(state.phase))): results may be incomplete; \(style.waitHint)"
    }
    let owner = state.owner == .app ? "Lumos app" : "background indexer"
    text += " · \(formatCount(state.objects)) objects · \(owner)"
    if let problem = state.problem {
        text += " · problem: \(problem)"
    }
    return text
}

private func describePhase(_ phase: String) -> String {
    switch phase {
    case "starting":
        return "loading"
    case "scanning":
        return "scanning folders"
    case "catchingUp":
        return "catching up on changes made while Lumos was closed"
    case "updating":
        return "applying recent changes"
    case "failed":
        return "indexing failed"
    default:
        return "applying recent changes"
    }
}
