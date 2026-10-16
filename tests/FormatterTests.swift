import Foundation

func formatterSuite() -> TestSuite {
    let suite = TestSuite(name: "Formatters")

    suite.test("directory size is blank") {
        try expectEqual(formatFileSize(999, isDirectory: true), "", "dir")
    }

    suite.test("bytes") {
        try expectEqual(formatFileSize(0, isDirectory: false), "0 B", "zero")
        try expectEqual(formatFileSize(512, isDirectory: false), "512 B", "bytes")
    }

    suite.test("kilobytes") {
        try expectEqual(formatFileSize(1024, isDirectory: false), "1.00 KB", "1kb")
        try expectEqual(formatFileSize(15_360, isDirectory: false), "15.0 KB", "15kb")
        try expectEqual(formatFileSize(153_600, isDirectory: false), "150 KB", "150kb")
    }

    suite.test("megabytes") {
        let label = formatFileSize(2_000_000, isDirectory: false)
        try expect(label.contains("MB"), "MB unit")
    }

    suite.test("extension") {
        try expectEqual(fileExtension(fromName: "File.PNG"), "png", "lowercased")
        try expectEqual(fileExtension(fromName: "Makefile"), "", "no extension")
        try expectEqual(fileExtension(fromName: ".hidden"), "", "leading dot is not an extension")
    }

    suite.test("dot hidden") {
        try expect(isDotHidden(name: ".gitignore"), "dotfile")
        try expect(!isDotHidden(name: "gitignore"), "normal")
    }

    suite.test("modified date posix") {
        let stamp = formatModifiedDate(0)
        let ok = stamp.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil
        try expect(ok, "expected yyyy-MM-dd HH:mm:ss, got \(stamp)")
    }

    suite.test("count formatting contains digits") {
        let label = formatCount(1234)
        try expect(label.contains("1") && label.contains("234"), "1234 visible")
    }

    return suite
}
