import Foundation

func formatFileSize(_ bytes: Int64, isDirectory: Bool) -> String {
    if isDirectory {
        return ""
    }
    if bytes < 1024 {
        return "\(bytes) B"
    }
    let units = ["KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unitIndex = -1
    while value >= 1024.0 && unitIndex < units.count - 1 {
        value /= 1024.0
        unitIndex += 1
    }
    if unitIndex < 0 {
        return "\(bytes) B"
    }
    if value >= 100.0 {
        return "\(Int(value.rounded())) \(units[unitIndex])"
    }
    if value >= 10.0 {
        return String(format: "%.1f %@", value, units[unitIndex])
    }
    return String(format: "%.2f %@", value, units[unitIndex])
}

func formatModifiedDate(_ timestamp: TimeInterval) -> String {
    let date = Date(timeIntervalSince1970: timestamp)
    return modifiedDateFormatter.string(from: date)
}

func formatCount(_ value: Int) -> String {
    return countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func fileExtension(fromName name: String) -> String {
    let nsName = name as NSString
    let ext = nsName.pathExtension.lowercased()
    return ext
}

func isDotHidden(name: String) -> Bool {
    return name.hasPrefix(".")
}

private let modifiedDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

private let countFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter
}()
