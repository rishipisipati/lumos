import Foundation

enum Privacy {
    static func clearVolatileUserDefaults() {
        let keys = [
            "NSNavRecentPlaces",
            "NSNavRecentPlacesWithErrors",
            "NSNavRecentServers",
            "NSRecentDocumentRecords",
            "NSRecentDocuments",
            "recentSearches",
            "RecentSearchStrings"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func isUsageTrackingPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        let markers = [
            "/com.apple.sharedfilelist",
            "lssharedfilelist",
            "/recently saved",
            "com.apple.recentitems"
        ]
        for marker in markers {
            if lowered.contains(marker) {
                return true
            }
        }
        return lowered.hasSuffix(".sfl")
            || lowered.hasSuffix(".sfl2")
            || lowered.hasSuffix(".sfl3")
    }

    /// Byte-level variant of `isUsageTrackingPath` for a single file name, used on
    /// every scanned file without allocating strings.
    static func isUsageTrackingFileName(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        for suffix in fileSuffixes where asciiHasSuffixIgnoringCase(name, suffix) {
            return true
        }
        for marker in fileMarkers where asciiContainsIgnoringCase(name, marker) {
            return true
        }
        return false
    }

    private static let fileSuffixes: [[UInt8]] = [".sfl", ".sfl2", ".sfl3"].map { Array($0.utf8) }
    private static let fileMarkers: [[UInt8]] = [
        "com.apple.sharedfilelist",
        "lssharedfilelist",
        "com.apple.recentitems"
    ].map { Array($0.utf8) }
}

@inline(__always)
private func asciiLower(_ byte: UInt8) -> UInt8 {
    return byte >= 65 && byte <= 90 ? byte + 32 : byte
}

private func asciiHasSuffixIgnoringCase(_ name: UnsafeBufferPointer<UInt8>, _ suffix: [UInt8]) -> Bool {
    if suffix.count > name.count {
        return false
    }
    let offset = name.count - suffix.count
    for index in 0..<suffix.count where asciiLower(name[offset + index]) != suffix[index] {
        return false
    }
    return true
}

private func asciiContainsIgnoringCase(_ name: UnsafeBufferPointer<UInt8>, _ marker: [UInt8]) -> Bool {
    if marker.count > name.count {
        return false
    }
    var start = 0
    while start + marker.count <= name.count {
        var matched = true
        for index in 0..<marker.count where asciiLower(name[start + index]) != marker[index] {
            matched = false
            break
        }
        if matched {
            return true
        }
        start += 1
    }
    return false
}
