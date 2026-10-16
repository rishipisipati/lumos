import Foundation

func specialCharacterSuite() -> TestSuite {
    let suite = TestSuite(name: "SpecialCharacters")

    suite.test("every query runs and literals are found") {
        let queries = specialQueries()
        var data = IndexData.empty()
        let root = try data.addRoot(path: "/lumos-special", modified: 0)
        var seen: Set<String> = []
        for query in queries where isLiteralNameQuery(query) && !query.contains("/") {
            let name = "hit \(query).txt"
            if seen.insert(name).inserted {
                _ = try appendTestEntry(&data, parent: root, name: name, size: 1, modified: 1, flags: 0)
            }
        }
        for code in 32...126 where code != 47 {
            let character = String(UnicodeScalar(code)!)
            _ = try appendTestEntry(&data, parent: root, name: "ascii-\(code)-zz\(character)zz.txt", size: 1, modified: 1, flags: 0)
        }

        var misses: [String] = []
        for query in queries {
            let hits = searchNames(data, query, showHidden: true)
            if isLiteralNameQuery(query) && !query.contains("/") && !hits.contains("hit \(query).txt") {
                misses.append(query.debugDescription)
            }
        }
        try expect(misses.isEmpty, "literal misses: \(misses.joined(separator: ", "))")
    }

    return suite
}

private func isLiteralNameQuery(_ query: String) -> Bool {
    if query.contains(where: { $0.isWhitespace }) {
        return false
    }
    if query.contains("|") || query.contains("\"") || query.contains("*") || query.contains("?") {
        return false
    }
    let parsed = parseQuery(query)
    return parsed.nameOrGroups == [[query]] && parsed.nameGlobs.isEmpty
}

private func specialQueries() -> [String] {
    var queries: [String] = []
    for code in 1...31 {
        let character = String(UnicodeScalar(code)!)
        queries.append(character)
        queries.append("zz" + character + "zz")
    }
    queries.append("\u{7F}")
    queries.append("\u{FEFF}")
    queries.append("\u{200B}")
    queries.append("\u{202E}")
    for code in 32...126 {
        let character = String(UnicodeScalar(code)!)
        queries.append(character)
        queries.append(String(repeating: character, count: 2))
        queries.append(String(repeating: character, count: 3))
        queries.append("zz" + character)
        queries.append(character + "zz")
        queries.append("zz" + character + "zz")
        queries.append("file" + character + "name")
    }
    queries.append(contentsOf: [
        "mark-",
        "c++",
        "C#",
        "foo)",
        "foo(",
        "foo[]",
        "foo{}",
        "100%",
        "a_b",
        "foo/bar",
        "foo\\bar",
        "foo&bar",
        "foo=bar",
        "foo#bar",
        "foo@bar",
        "foo!bar",
        "foo~bar",
        "foo`bar",
        "foo,bar",
        "foo;bar",
        "foo.bar",
        "foo:bar",
        "foo^bar",
        "foo$bar",
        "foo'bar",
        ".gitignore",
        "..",
        "...",
        "---",
        "+++",
        "***",
        "???",
        "(((",
        ")))",
        "{{{",
        "}}}",
        "^^^",
        "file[1]",
        "file(1)",
        "^mark",
        "中文文件",
        "日本語",
        "🙂🙂🙂",
        "café",
        "em—dash",
        "en–dash",
        "ext:",
        "path:",
        "size:",
        "dm:",
        "folder:",
        "file:",
        "type:",
        "path:foo/bar",
        "path:100%",
        "path:a_b",
        "ext:c++"
    ])
    return queries
}
