import Foundation

func queryParserSuite() -> TestSuite {
    let suite = TestSuite(name: "QueryParser")

    suite.test("empty query") {
        let query = parseQuery("   ")
        try expect(query.isEmpty, "whitespace-only query should be empty")
    }

    suite.test("substring token") {
        try expectEqual(parseQuery("alpha").nameOrGroups, [["alpha"]], "substring")
    }

    suite.test("AND tokens") {
        try expectEqual(parseQuery("foo bar").nameOrGroups, [["foo"], ["bar"]], "AND")
    }

    suite.test("OR token") {
        try expectEqual(parseQuery("foo|bar").nameOrGroups, [["foo", "bar"]], "OR")
    }

    suite.test("quoted phrase") {
        try expectEqual(parseQuery("\"foo bar\"").nameOrGroups, [["foo bar"]], "quoted phrase stays one token")
    }

    suite.test("glob") {
        try expectEqual(parseQuery("*.pdf").extensions, ["pdf"], "star-dot-ext uses the ext index")
        try expectEqual(parseQuery("*.p").extensionPrefixes, ["p"], "partial ext is a prefix")
        try expect(parseQuery("*.").anyExtension, "star-dot means has an extension")
        try expectEqual(parseQuery("*pdf").extensions, ["pdf"], "star-letters is an extension")
        try expectEqual(parseQuery("*p").extensionPrefixes, ["p"], "star-p is an ext prefix")
        try expectEqual(parseQuery("note*").namePrefixes, ["note"], "prefix star")
        try expect(parseQuery("*").isEmpty, "bare star is all files")
        try expect(parseQuery("file?.txt").nameGlobs.contains("file?.txt"), "question glob stays raw")
    }

    suite.test("extension filter") {
        try expectEqual(parseQuery("ext:png;jpg").extensions, ["png", "jpg"], "ext list")
        try expectEqual(parseQuery("ext:.PNG").extensions, ["png"], "ext strips dot and case")
    }

    suite.test("path filter") {
        try expectEqual(parseQuery("path:Archive").pathSubstring, "Archive", "path")
    }

    suite.test("file and folder filters") {
        try expect(parseQuery("file:").filesOnly, "file:")
        try expect(parseQuery("folder:").foldersOnly, "folder:")
        try expect(parseQuery("type:directory").foldersOnly, "type:directory")
        try expect(parseQuery("type:file").filesOnly, "type:file")
    }

    suite.test("unknown type stays a name") {
        try expectEqual(parseQuery("type:weird").nameOrGroups, [["type:weird"]], "unknown type")
    }

    suite.test("unknown key stays a name") {
        try expectEqual(parseQuery("foo:bar").nameOrGroups, [["foo:bar"]], "unknown key")
    }

    suite.test("size greater than") {
        let query = parseQuery("size:>10mb")
        try expectNotNil(query.minSize, "size min")
        try expect(query.minSize! > 10_000_000, "size min is just above 10mb")
        try expectNil(query.maxSize, "no max")
        let flipped = parseQuery("size>:10mb")
        try expectEqual(flipped.minSize, query.minSize, "size>: is the same as size:>")
        let compact = parseQuery("size>10mb")
        try expectEqual(compact.minSize, query.minSize, "size>10mb")
        let combined = parseQuery("*.pdf size>:10mb")
        try expectEqual(combined.extensions, ["pdf"], "pdf ext")
        try expectEqual(combined.minSize, query.minSize, "size kept with glob")
        try expect(combined.nameOrGroups.isEmpty, "size token is not a filename")
    }

    suite.test("size less than") {
        let query = parseQuery("size:<1kb")
        try expectNotNil(query.maxSize, "size max")
        try expect(query.maxSize! < 1024, "size max is just below 1kb")
    }

    suite.test("size exact range") {
        let query = parseQuery("size:2kb")
        try expectEqual(query.minSize, 2048, "exact min")
        try expectNotNil(query.maxSize, "exact max")
    }

    suite.test("date today") {
        let query = parseQuery("dm:today")
        try expectNotNil(query.modifiedAfter, "today has a start")
        try expectNil(query.modifiedBefore, "today has no end")
    }

    suite.test("date yesterday") {
        let query = parseQuery("dm:yesterday")
        try expectNotNil(query.modifiedAfter, "yesterday start")
        try expectNotNil(query.modifiedBefore, "yesterday end")
        try expect(query.modifiedAfter! < query.modifiedBefore!, "yesterday window")
    }

    suite.test("iso date") {
        let query = parseQuery("dm:2020-01-15")
        try expectNotNil(query.modifiedAfter, "iso start")
        try expectNotNil(query.modifiedBefore, "iso end")
    }

    suite.test("this week month year aliases") {
        try expectNotNil(parseQuery("dm:this-week").modifiedAfter, "this-week")
        try expectNotNil(parseQuery("dm:thismonth").modifiedAfter, "thismonth")
        try expectNotNil(parseQuery("dm:thisyear").modifiedAfter, "thisyear")
    }

    suite.test("combined filters") {
        let query = parseQuery("alpha ext:pdf folder: path:Archive")
        try expectEqual(query.nameOrGroups, [["alpha"]], "name")
        try expectEqual(query.extensions, ["pdf"], "ext")
        try expect(query.foldersOnly, "folder")
        try expectEqual(query.pathSubstring, "Archive", "path")
    }

    return suite
}
