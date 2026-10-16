import Foundation

struct FileRecord: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let parent: String
    let size: Int64
    let modified: TimeInterval
    let isDirectory: Bool
    let ext: String
    let isHidden: Bool
}
