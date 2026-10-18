import Foundation

/// Deterministic generator so failures reproduce.
struct SplitMix64 {
    var state: UInt64

    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Int(value % UInt64(bound))
    }
}

private let syllables: [String] = [
    "re", "port", "Mem", "o", "draft", "FINAL", "v2", "caf\u{00E9}", "Na\u{00EF}ve", "\u{6587}\u{6863}",
    "ab", "x", "notes", "Brief", "letter", "en", "gage", "ment", "_", "-", " ", "2024", "q3", "deck"
]
private let extensions: [String] = ["pdf", "PDF", "docx", "txt", "md", "", "tar.gz", "p", "key"]

private func randomName(_ random: inout SplitMix64) -> String {
    var name = ""
    for _ in 0..<(1 + random.next(4)) {
        name += syllables[random.next(syllables.count)]
    }
    if random.next(10) == 0 {
        name = "." + name
    }
    let ext = extensions[random.next(extensions.count)]
    return ext.isEmpty ? name : name + "." + ext
}

private func syntheticIndex(entries: Int, seed: UInt64) throws -> IndexData {
    var random = SplitMix64(state: seed)
    var data = IndexData.empty()
    var folders: [Int32] = [try data.addRoot(path: "/r", modified: 0)]
    for _ in 0..<entries {
        let parent = folders[random.next(folders.count)]
        let isFolder = random.next(6) == 0
        let id = try appendTestEntry(
            &data,
            parent: parent,
            name: randomName(&random),
            size: Int64(random.next(5_000_000)),
            modified: Int64(random.next(1_000_000)),
            flags: isFolder ? EntryFlag.directory : 0
        )
        if isFolder {
            folders.append(id)
        }
    }
    return data
}

private let equivalenceQueries: [String] = [
    "report", "REPORT", "rep", "re", "x", "memo draft", "final|brief", "caf\u{00E9}", "cafe", "naive",
    "\u{6587}\u{6863}", "ext:pdf", "ext:pdf;docx", "ext:p", "*.pdf", "rep*", "*deck.key", "\"en gage\"",
    "engagement", "q3 deck ext:key", "path:notes", "path:brief report", "size:>1mb memo", "folder: draft",
    "file: notes", "zzqqxx", "", "tar.gz", "report|zzqqxx", "abab", "v2 FINAL"
]

private func expectEquivalent(_ data: IndexData, trigrams: NameTrigramIndex, label: String) throws {
    for text in equivalenceQueries {
        for showHidden in [false, true] {
            let query = parseQuery(text)
            let plain = searchIndex(data, query: query, showHidden: showHidden, sortColumn: .name, ascending: true, trigrams: nil)
            let fast = searchIndex(data, query: query, showHidden: showHidden, sortColumn: .name, ascending: true, trigrams: trigrams)
            try expectEqual(fast, plain, "\(label): \"\(text)\" hidden=\(showHidden)")
        }
    }
}

func trigramSuite() -> TestSuite {
    let suite = TestSuite(name: "Trigrams")

    suite.test("trigram search returns exactly the plain scan results") {
        let data = try syntheticIndex(entries: 6_000, seed: 42)
        let trigrams = buildNameTrigramIndex(data, layout: 0)
        try expectEqual(trigrams.coveredCount, data.count, "covers every entry")
        try expectEquivalent(data, trigrams: trigrams, label: "fresh")
        let narrowed = equivalenceQueries.filter { text in
            trigramCandidates(trigrams, query: compileQuery(parseQuery(text), showHidden: true)) != nil
        }
        try expect(narrowed.count >= 10, "most queries use the trigram index (\(narrowed.count) did)")
        try expect(trigramCandidates(trigrams, query: compileQuery(parseQuery("re"), showHidden: true)) == nil, "short words scan")
    }

    suite.test("entries added or deleted after the build are still exact") {
        var data = try syntheticIndex(entries: 4_000, seed: 7)
        let trigrams = buildNameTrigramIndex(data, layout: 0)
        var random = SplitMix64(state: 99)
        for _ in 0..<1_500 {
            _ = try appendTestEntry(&data, parent: data.roots[0].entryId, name: randomName(&random), size: 1, modified: 1, flags: 0)
        }
        _ = try appendTestEntry(&data, parent: data.roots[0].entryId, name: "fresh report.pdf", size: 1, modified: 1, flags: 0)
        for _ in 0..<300 {
            let id = Int32(1 + random.next(data.count - 1))
            if data.isLive(id) {
                _ = data.removeEntry(id)
            }
        }
        try expectEquivalent(data, trigrams: trigrams, label: "after churn")
        let found = searchIndex(data, query: parseQuery("fresh report"), showHidden: true, sortColumn: .name, ascending: true, trigrams: trigrams)
        try expectEqual(found.map { data.nameString($0) }, ["fresh report.pdf"], "uncovered tail is scanned")
    }

    suite.test("store hands out trigrams only for the current layout") {
        let store = IndexStore(data: try syntheticIndex(entries: 25_000, seed: 3))
        _ = store.readForSearch { _, _, trigrams in trigrams }
        try expect(waitUntil(timeout: 20) { store.readForSearch { _, _, trigrams in trigrams != nil } }, "built in the background")
        store.replace(try syntheticIndex(entries: 100, seed: 4))
        try expect(store.readForSearch { _, _, trigrams in trigrams == nil }, "dropped when ids are renumbered")
    }

    return suite
}
