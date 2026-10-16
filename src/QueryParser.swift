import Foundation

struct SearchQuery: Equatable, Sendable {
    let nameOrGroups: [[String]]
    let nameGlobs: [String]
    let namePrefixes: [String]
    let nameSuffixes: [String]
    let extensions: [String]
    let extensionPrefixes: [String]
    let anyExtension: Bool
    let pathSubstring: String?
    let filesOnly: Bool
    let foldersOnly: Bool
    let minSize: Int64?
    let maxSize: Int64?
    let modifiedAfter: TimeInterval?
    let modifiedBefore: TimeInterval?

    var isEmpty: Bool {
        return nameOrGroups.isEmpty
            && nameGlobs.isEmpty
            && namePrefixes.isEmpty
            && nameSuffixes.isEmpty
            && extensions.isEmpty
            && extensionPrefixes.isEmpty
            && !anyExtension
            && pathSubstring == nil
            && !filesOnly
            && !foldersOnly
            && minSize == nil
            && maxSize == nil
            && modifiedAfter == nil
            && modifiedBefore == nil
    }
}

func parseQuery(_ raw: String) -> SearchQuery {
    let tokens = tokenizeQuery(raw)
    var nameOrGroups: [[String]] = []
    var nameGlobs: [String] = []
    var namePrefixes: [String] = []
    var nameSuffixes: [String] = []
    var extensions: [String] = []
    var extensionPrefixes: [String] = []
    var anyExtension = false
    var pathSubstring: String?
    var filesOnly = false
    var foldersOnly = false
    var minSize: Int64?
    var maxSize: Int64?
    var modifiedAfter: TimeInterval?
    var modifiedBefore: TimeInterval?

    for token in tokens {
        let parsedFilter = parseFilterToken(token)
        switch parsedFilter.kind {
        case .name:
            applyNameToken(
                parsedFilter.value,
                nameOrGroups: &nameOrGroups,
                nameGlobs: &nameGlobs,
                namePrefixes: &namePrefixes,
                nameSuffixes: &nameSuffixes,
                extensions: &extensions,
                extensionPrefixes: &extensionPrefixes,
                anyExtension: &anyExtension
            )
        case .extensions:
            let parts = parsedFilter.value
                .split(separator: ";")
                .map { normalizeExtension(String($0)) }
                .filter { !$0.isEmpty }
            extensions.append(contentsOf: parts)
        case .path:
            pathSubstring = parsedFilter.value
        case .filesOnly:
            filesOnly = true
        case .foldersOnly:
            foldersOnly = true
        case .size:
            let bounds = parseSizeBounds(parsedFilter.value)
            minSize = combineMin(minSize, bounds.minSize)
            maxSize = combineMax(maxSize, bounds.maxSize)
        case .modified:
            let bounds = parseDateBounds(parsedFilter.value, now: Date())
            modifiedAfter = combineMinInterval(modifiedAfter, bounds.after)
            modifiedBefore = combineMaxInterval(modifiedBefore, bounds.before)
        }
    }

    return SearchQuery(
        nameOrGroups: nameOrGroups,
        nameGlobs: nameGlobs,
        namePrefixes: namePrefixes,
        nameSuffixes: nameSuffixes,
        extensions: extensions,
        extensionPrefixes: extensionPrefixes,
        anyExtension: anyExtension,
        pathSubstring: pathSubstring,
        filesOnly: filesOnly,
        foldersOnly: foldersOnly,
        minSize: minSize,
        maxSize: maxSize,
        modifiedAfter: modifiedAfter,
        modifiedBefore: modifiedBefore
    )
}

private struct FilterToken {
    enum Kind {
        case name
        case extensions
        case path
        case filesOnly
        case foldersOnly
        case size
        case modified
    }

    let kind: Kind
    let value: String
}

private func tokenizeQuery(_ raw: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var inQuotes = false
    for character in raw {
        if character == "\"" {
            inQuotes.toggle()
            continue
        }
        if character.isWhitespace && !inQuotes {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            continue
        }
        current.append(character)
    }
    if !current.isEmpty {
        tokens.append(current)
    }
    return tokens
}

private func parseFilterToken(_ token: String) -> FilterToken {
    if let sizeValue = sizeFilterValue(from: token) {
        return FilterToken(kind: .size, value: sizeValue)
    }
    guard let colon = token.firstIndex(of: ":") else {
        return FilterToken(kind: .name, value: token)
    }
    let key = token[token.startIndex..<colon].lowercased()
    let value = String(token[token.index(after: colon)...])
    switch key {
    case "ext":
        return FilterToken(kind: .extensions, value: value)
    case "path":
        return FilterToken(kind: .path, value: value)
    case "size":
        return FilterToken(kind: .size, value: value)
    case "dm", "datemodified", "date-modified":
        return FilterToken(kind: .modified, value: value)
    case "file":
        return FilterToken(kind: .filesOnly, value: "")
    case "folder":
        return FilterToken(kind: .foldersOnly, value: "")
    case "type":
        let normalized = value.lowercased()
        if normalized == "folder" || normalized == "dir" || normalized == "directory" {
            return FilterToken(kind: .foldersOnly, value: "")
        }
        if normalized == "file" {
            return FilterToken(kind: .filesOnly, value: "")
        }
        return FilterToken(kind: .name, value: token)
    default:
        return FilterToken(kind: .name, value: token)
    }
}

private func tokenContainsGlob(_ token: String) -> Bool {
    return token.contains("*") || token.contains("?")
}

private func applyNameToken(
    _ token: String,
    nameOrGroups: inout [[String]],
    nameGlobs: inout [String],
    namePrefixes: inout [String],
    nameSuffixes: inout [String],
    extensions: inout [String],
    extensionPrefixes: inout [String],
    anyExtension: inout Bool
) {
    if !tokenContainsGlob(token) {
        let orParts = token
            .split(separator: "|")
            .map { String($0) }
            .filter { !$0.isEmpty }
        if !orParts.isEmpty {
            nameOrGroups.append(orParts)
        }
        return
    }
    let compiled = compileGlob(token)
    switch compiled {
    case .all:
        return
    case .anyExtension:
        anyExtension = true
    case .exactExtension(let ext):
        extensions.append(ext)
    case .extensionPrefix(let prefix):
        extensionPrefixes.append(prefix)
    case .namePrefix(let prefix):
        namePrefixes.append(prefix)
    case .nameSuffix(let suffix):
        nameSuffixes.append(suffix)
    case .contains(let term):
        nameOrGroups.append([term])
    case .raw(let glob):
        nameGlobs.append(glob)
    }
}

private enum CompiledGlob: Equatable {
    case all
    case anyExtension
    case exactExtension(String)
    case extensionPrefix(String)
    case namePrefix(String)
    case nameSuffix(String)
    case contains(String)
    case raw(String)
}

private func compileGlob(_ raw: String) -> CompiledGlob {
    let glob = raw.lowercased()
    if glob == "*" {
        return .all
    }
    if glob == "*." || glob == "*.*" {
        return .anyExtension
    }
    if glob.hasPrefix("*.") {
        let rest = String(glob.dropFirst(2))
        if !rest.isEmpty && !tokenContainsGlob(rest) {
            if rest.count >= 3 {
                return .exactExtension(normalizeExtension(rest))
            }
            return .extensionPrefix(normalizeExtension(rest))
        }
    }
    if glob.hasPrefix("*") && glob.hasSuffix("*") && glob.count >= 3 {
        let inner = String(glob.dropFirst().dropLast())
        if !inner.isEmpty && !tokenContainsGlob(inner) {
            return .contains(inner)
        }
    }
    if glob.hasPrefix("*") && !tokenContainsGlob(String(glob.dropFirst())) {
        let suffix = String(glob.dropFirst())
        if !suffix.isEmpty && suffix.count <= 8 && suffix.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
            if suffix.count >= 3 {
                return .exactExtension(normalizeExtension(suffix))
            }
            return .extensionPrefix(normalizeExtension(suffix))
        }
        if !suffix.isEmpty {
            return .nameSuffix(suffix)
        }
    }
    if glob.hasSuffix("*") && !tokenContainsGlob(String(glob.dropLast())) {
        let prefix = String(glob.dropLast())
        if !prefix.isEmpty {
            return .namePrefix(prefix)
        }
    }
    return .raw(glob)
}

private func normalizeExtension(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasPrefix(".") {
        value.removeFirst()
    }
    return value
}

private struct SizeBounds {
    let minSize: Int64?
    let maxSize: Int64?
}

private func sizeFilterValue(from token: String) -> String? {
    let lower = token.lowercased()
    guard lower.hasPrefix("size") else {
        return nil
    }
    var rest = String(lower.dropFirst(4))
    if rest.hasPrefix(":") {
        rest = String(rest.dropFirst())
    }
    if rest.hasPrefix(">=:") {
        rest = ">=" + rest.dropFirst(3)
    } else if rest.hasPrefix("<=:") {
        rest = "<=" + rest.dropFirst(3)
    } else if rest.hasPrefix(">:") {
        rest = ">" + rest.dropFirst(2)
    } else if rest.hasPrefix("<:") {
        rest = "<" + rest.dropFirst(2)
    }
    if rest.isEmpty {
        return nil
    }
    if rest.hasPrefix(">") || rest.hasPrefix("<") || rest.hasPrefix("=") || rest.first?.isNumber == true {
        return rest
    }
    return nil
}

private func parseSizeBounds(_ raw: String) -> SizeBounds {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    trimmed = trimmed.replacingOccurrences(of: ">:", with: ">")
    trimmed = trimmed.replacingOccurrences(of: "<:", with: "<")
    if trimmed.isEmpty {
        return SizeBounds(minSize: nil, maxSize: nil)
    }
    var comparison = ""
    var rest = trimmed
    if trimmed.hasPrefix(">=") || trimmed.hasPrefix("<=") {
        comparison = String(trimmed.prefix(2))
        rest = String(trimmed.dropFirst(2))
    } else if trimmed.hasPrefix(">") || trimmed.hasPrefix("<") {
        comparison = String(trimmed.prefix(1))
        rest = String(trimmed.dropFirst(1))
    }
    guard let bytes = parseByteCount(rest) else {
        return SizeBounds(minSize: nil, maxSize: nil)
    }
    switch comparison {
    case ">":
        return SizeBounds(minSize: bytes + 1, maxSize: nil)
    case ">=":
        return SizeBounds(minSize: bytes, maxSize: nil)
    case "<":
        return SizeBounds(minSize: nil, maxSize: bytes - 1)
    case "<=":
        return SizeBounds(minSize: nil, maxSize: bytes)
    default:
        return SizeBounds(minSize: bytes, maxSize: bytes * 2 - 1)
    }
}

private func parseByteCount(_ raw: String) -> Int64? {
    let pattern = #"^([0-9]+(?:\.[0-9]+)?)(b|kb|mb|gb|tb)?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return nil
    }
    let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    guard let match = regex.firstMatch(in: raw, options: [], range: range) else {
        return nil
    }
    guard let numberRange = Range(match.range(at: 1), in: raw) else {
        return nil
    }
    guard let number = Double(raw[numberRange]) else {
        return nil
    }
    var multiplier: Double = 1
    if match.range(at: 2).location != NSNotFound, let unitRange = Range(match.range(at: 2), in: raw) {
        switch raw[unitRange] {
        case "kb":
            multiplier = 1024
        case "mb":
            multiplier = 1024 * 1024
        case "gb":
            multiplier = 1024 * 1024 * 1024
        case "tb":
            multiplier = 1024 * 1024 * 1024 * 1024
        default:
            multiplier = 1
        }
    }
    return Int64((number * multiplier).rounded())
}

private struct DateBounds {
    let after: TimeInterval?
    let before: TimeInterval?
}

private func parseDateBounds(_ raw: String, now: Date) -> DateBounds {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: now)
    switch trimmed {
    case "today":
        return DateBounds(after: startOfToday.timeIntervalSince1970, before: nil)
    case "yesterday":
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
            return DateBounds(after: nil, before: nil)
        }
        return DateBounds(
            after: yesterday.timeIntervalSince1970,
            before: startOfToday.timeIntervalSince1970
        )
    case "thisweek", "this-week":
        guard let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return DateBounds(after: nil, before: nil)
        }
        return DateBounds(after: start.timeIntervalSince1970, before: nil)
    case "thismonth", "this-month":
        guard let start = calendar.dateInterval(of: .month, for: now)?.start else {
            return DateBounds(after: nil, before: nil)
        }
        return DateBounds(after: start.timeIntervalSince1970, before: nil)
    case "thisyear", "this-year":
        guard let start = calendar.dateInterval(of: .year, for: now)?.start else {
            return DateBounds(after: nil, before: nil)
        }
        return DateBounds(after: start.timeIntervalSince1970, before: nil)
    default:
        break
    }
    if let date = parseISODate(trimmed, calendar: calendar) {
        guard let next = calendar.date(byAdding: .day, value: 1, to: date) else {
            return DateBounds(after: date.timeIntervalSince1970, before: nil)
        }
        return DateBounds(after: date.timeIntervalSince1970, before: next.timeIntervalSince1970)
    }
    return DateBounds(after: nil, before: nil)
}

private func parseISODate(_ raw: String, calendar: Calendar) -> Date? {
    let parts = raw.split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
        return nil
    }
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return calendar.date(from: components)
}

private func combineMin(_ left: Int64?, _ right: Int64?) -> Int64? {
    if let left, let right {
        return max(left, right)
    }
    return left ?? right
}

private func combineMax(_ left: Int64?, _ right: Int64?) -> Int64? {
    if let left, let right {
        return min(left, right)
    }
    return left ?? right
}

private func combineMinInterval(_ left: TimeInterval?, _ right: TimeInterval?) -> TimeInterval? {
    if let left, let right {
        return max(left, right)
    }
    return left ?? right
}

private func combineMaxInterval(_ left: TimeInterval?, _ right: TimeInterval?) -> TimeInterval? {
    if let left, let right {
        return min(left, right)
    }
    return left ?? right
}
