import Foundation

func privacySuite() -> TestSuite {
    let suite = TestSuite(name: "Privacy")

    suite.test("shared file list paths") {
        let recents = "/Users/sample/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl2"
        try expect(Privacy.isUsageTrackingPath(recents), "sfl2 recents")
        try expect(Privacy.isUsageTrackingPath("/tmp/com.apple.recentitems.plist"), "recentitems")
        try expect(Privacy.isUsageTrackingPath("/Users/sample/Recently Saved/note.txt"), "Recently Saved")
        try expect(Privacy.isUsageTrackingPath("/tmp/bookmarks.sfl"), "sfl suffix")
        try expect(Privacy.isUsageTrackingPath("/tmp/bookmarks.sfl3"), "sfl3 suffix")
    }

    suite.test("user files named recent stay searchable") {
        try expect(
            !Privacy.isUsageTrackingPath("/Users/sample/Projects/recent-notes.pdf"),
            "ordinary file"
        )
        try expect(
            !Privacy.isUsageTrackingPath("/Users/sample/Projects/folder-mark-open.svg"),
            "hyphenated name"
        )
    }

    suite.test("usage tracking file names") {
        func check(_ name: String) -> Bool {
            let bytes = Array(name.utf8)
            return bytes.withUnsafeBufferPointer { Privacy.isUsageTrackingFileName($0) }
        }
        try expect(check("com.apple.LSSharedFileList.RecentDocuments.SFL2"), "sfl2 any case")
        try expect(check("bookmarks.sfl"), "sfl")
        try expect(check("com.apple.recentitems.plist"), "recentitems")
        try expect(!check("recent-notes.pdf"), "ordinary file")
        try expect(!check("sfl.txt"), "sfl not a suffix")
    }

    suite.test("clearVolatileUserDefaults removes recents keys") {
        let defaults = UserDefaults.standard
        defaults.set(["/tmp"], forKey: "NSNavRecentPlaces")
        defaults.set(["old"], forKey: "recentSearches")
        Privacy.clearVolatileUserDefaults()
        try expectNil(defaults.array(forKey: "NSNavRecentPlaces"), "nav recents cleared")
        try expectNil(defaults.array(forKey: "recentSearches"), "search recents cleared")
    }

    suite.test("junk paths") {
        try expect(isJunkPath("/System/Library"), "system")
        try expect(isJunkPath("/dev/null"), "dev")
        try expect(isJunkPath("/private/var/folders/xx"), "var folders")
        try expect(isJunkPath("/Users/sample/Library/Caches/foo"), "caches")
        try expect(!isJunkPath("/Users/sample/Projects/a.txt"), "projects")
    }

    suite.test("home privacy folders") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try expect(
            isAutomaticHomePrivacyPath(home + "/Library", walkRootPath: home),
            "Library skipped from home"
        )
        try expect(
            !isAutomaticHomePrivacyPath(home + "/Library", walkRootPath: home + "/Library"),
            "Library allowed when it is the root"
        )
        try expect(
            !isAutomaticHomePrivacyPath(home + "/Documents", walkRootPath: home),
            "Documents kept"
        )
    }

    suite.test("watch ignore") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try expect(isIgnoredChangePath("/System/bin", rootPath: "/"), "junk")
        try expect(
            isIgnoredChangePath(
                home + "/Library/Application Support/com.apple.sharedfilelist",
                rootPath: home
            ),
            "recents under home"
        )
        try expect(isIgnoredChangePath(home + "/Documents/.Trash/x", rootPath: home), "trash")
        try expect(isIgnoredChangePath(home + "/Documents/Tool.app/Contents", rootPath: home), "bundle internals")
        try expect(!isIgnoredChangePath(home + "/Documents/Cases", rootPath: home), "documents kept")
        try expect(!isIgnoredChangePath(home, rootPath: home), "root kept")
    }

    return suite
}
