import Darwin
import Foundation

/// Everything needed to resume after a relaunch: the FSEvents id the data is
/// consistent with, the per-volume FSEvents UUIDs (a changed UUID means the
/// journal was reset and the root must be re-diffed) and roots whose scan did
/// not finish.
struct SnapshotMeta: Codable, Equatable {
    let eventId: UInt64
    let roots: [IndexRoot]
    let volumeUUIDs: [String: String]
    let rescanRoots: [String]
    let savedAt: TimeInterval
}

enum SnapshotError: Error, LocalizedError {
    case missing
    case truncated(Int)
    case badMagic
    case versionMismatch(UInt32)
    case checksumMismatch
    case inconsistent(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "No saved index."
        case .truncated(let size):
            return "The saved index is truncated (\(size) bytes)."
        case .badMagic:
            return "The saved index is not a Lumos index file."
        case .versionMismatch(let found):
            return "The saved index uses format \(found); this build uses format \(snapshotFormatVersion)."
        case .checksumMismatch:
            return "The saved index is corrupted (checksum mismatch)."
        case .inconsistent(let detail):
            return "The saved index is inconsistent: \(detail)"
        case .writeFailed(let detail):
            return "Could not save the index: \(detail)"
        }
    }
}

let snapshotFormatVersion: UInt32 = 1
private let snapshotMagic: [UInt8] = Array("LUMOSIDX".utf8)
private let headerSize = 8 + 4 + 4 + 8 * 4

/// Streaming 64-bit checksum over arbitrary chunk boundaries.
struct Checksum64 {
    private(set) var state: UInt64
    private var carry: [UInt8]

    static func start() -> Checksum64 {
        return Checksum64(state: 0xCBF2_9CE4_8422_2325, carry: [])
    }

    private mutating func mix(_ word: UInt64) {
        state = (state ^ word) &* 0x9E37_79B9_7F4A_7C15
        state ^= state >> 29
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var offset = 0
        if !carry.isEmpty {
            while carry.count < 8 && offset < bytes.count {
                carry.append(bytes[offset])
                offset += 1
            }
            if carry.count == 8 {
                mix(carry.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
                carry.removeAll(keepingCapacity: true)
            }
        }
        while offset + 8 <= bytes.count {
            mix(bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            offset += 8
        }
        while offset < bytes.count {
            carry.append(bytes[offset])
            offset += 1
        }
    }

    func finish() -> UInt64 {
        var copy = self
        if !carry.isEmpty {
            var tail = carry
            while tail.count < 8 {
                tail.append(0)
            }
            copy.mix(tail.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
            copy.mix(UInt64(carry.count))
        }
        return copy.state
    }
}

private final class SnapshotWriter {
    private let handle: FileHandle
    private(set) var checksum = Checksum64.start()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        if bytes.isEmpty {
            return
        }
        checksum.update(bytes)
        try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), count: bytes.count, deallocator: .none))
    }

    func write<Element>(array: [Element]) throws {
        try array.withUnsafeBytes { try write($0) }
    }

    func write(integer: UInt64) throws {
        var value = integer.littleEndian
        try withUnsafeBytes(of: &value) { try write($0) }
    }

    func write(integer: UInt32) throws {
        var value = integer.littleEndian
        try withUnsafeBytes(of: &value) { try write($0) }
    }
}

/// Writes a compacted index atomically (temp file + fsync + rename).
func writeSnapshot(_ data: IndexData, meta: SnapshotMeta, to url: URL) throws {
    if data.deletedCount != 0 {
        throw SnapshotError.writeFailed("internal error: snapshot data must be compacted first")
    }
    let metaBytes = try JSONEncoder().encode(meta)
    let temporary = url.appendingPathExtension("tmp")
    FileManager.default.createFile(atPath: temporary.path, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: temporary.path) else {
        throw SnapshotError.writeFailed("cannot create \(temporary.path)")
    }
    do {
        let writer = SnapshotWriter(handle: handle)
        try snapshotMagic.withUnsafeBytes { try writer.write($0) }
        try writer.write(integer: snapshotFormatVersion)
        try writer.write(integer: UInt32(0))
        try writer.write(integer: UInt64(data.count))
        try writer.write(integer: UInt64(data.names.count))
        try writer.write(integer: UInt64(data.folded.count))
        try writer.write(integer: UInt64(metaBytes.count))
        try metaBytes.withUnsafeBytes { try writer.write($0) }
        try writer.write(array: data.parent)
        try writer.write(array: data.nameStart)
        try writer.write(array: data.nameLength)
        try writer.write(array: data.foldStart)
        try writer.write(array: data.foldLength)
        try writer.write(array: data.size)
        try writer.write(array: data.modified)
        try writer.write(array: data.flags)
        try writer.write(array: data.names)
        try writer.write(array: data.folded)
        var digest = writer.checksum.finish().littleEndian
        try handle.write(contentsOf: Data(bytes: &digest, count: 8))
        try handle.synchronize()
        try handle.close()
    } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
        throw SnapshotError.writeFailed(error.localizedDescription)
    }
    if rename(temporary.path, url.path) != 0 {
        let code = errno
        try? FileManager.default.removeItem(at: temporary)
        throw SnapshotError.writeFailed("rename failed: \(String(cString: strerror(code)))")
    }
}

private struct SnapshotReader {
    let bytes: UnsafeRawBufferPointer
    var offset: Int

    mutating func integer64() throws -> UInt64 {
        try require(8)
        defer { offset += 8 }
        return UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    mutating func integer32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    mutating func array<Element>(count: Int, of type: Element.Type) throws -> [Element] {
        let byteCount = count * MemoryLayout<Element>.stride
        try require(byteCount)
        let source = bytes.baseAddress! + offset
        offset += byteCount
        return [Element](unsafeUninitializedCapacity: count) { buffer, initialized in
            if byteCount > 0 {
                memcpy(buffer.baseAddress!, source, byteCount)
            }
            initialized = count
        }
    }

    mutating func data(count: Int) throws -> Data {
        try require(count)
        defer { offset += count }
        return Data(bytes: bytes.baseAddress! + offset, count: count)
    }

    func require(_ count: Int) throws {
        if count < 0 || offset + count > bytes.count {
            throw SnapshotError.truncated(bytes.count)
        }
    }
}

func readSnapshot(from url: URL) throws -> (data: IndexData, meta: SnapshotMeta) {
    if !FileManager.default.fileExists(atPath: url.path) {
        throw SnapshotError.missing
    }
    let file = try Data(contentsOf: url, options: .alwaysMapped)
    if file.count < headerSize + 8 {
        throw SnapshotError.truncated(file.count)
    }
    return try file.withUnsafeBytes { raw -> (data: IndexData, meta: SnapshotMeta) in
        if !raw.prefix(8).elementsEqual(snapshotMagic) {
            throw SnapshotError.badMagic
        }
        var checksum = Checksum64.start()
        checksum.update(UnsafeRawBufferPointer(rebasing: raw[0..<(raw.count - 8)]))
        let stored = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: raw.count - 8, as: UInt64.self))
        var reader = SnapshotReader(bytes: UnsafeRawBufferPointer(rebasing: raw[0..<(raw.count - 8)]), offset: 8)
        let version = try reader.integer32()
        if version != snapshotFormatVersion {
            throw SnapshotError.versionMismatch(version)
        }
        if checksum.finish() != stored {
            throw SnapshotError.checksumMismatch
        }
        _ = try reader.integer32()
        let count = Int(try reader.integer64())
        let namesCount = Int(try reader.integer64())
        let foldedCount = Int(try reader.integer64())
        let metaCount = Int(try reader.integer64())
        let meta = try JSONDecoder().decode(SnapshotMeta.self, from: try reader.data(count: metaCount))
        var data = IndexData.empty()
        data.parent = try reader.array(count: count, of: Int32.self)
        data.nameStart = try reader.array(count: count, of: UInt32.self)
        data.nameLength = try reader.array(count: count, of: UInt16.self)
        data.foldStart = try reader.array(count: count, of: UInt32.self)
        data.foldLength = try reader.array(count: count, of: UInt16.self)
        data.size = try reader.array(count: count, of: Int64.self)
        data.modified = try reader.array(count: count, of: Int64.self)
        data.flags = try reader.array(count: count, of: UInt8.self)
        data.names = try reader.array(count: namesCount, of: UInt8.self)
        data.folded = try reader.array(count: foldedCount, of: UInt8.self)
        if reader.offset != reader.bytes.count {
            throw SnapshotError.inconsistent("\(reader.bytes.count - reader.offset) unexpected trailing bytes")
        }
        try validateSnapshotData(data, roots: meta.roots)
        let links = rebuildChildLinks(parent: data.parent)
        data.firstChild = links.firstChild
        data.nextSibling = links.nextSibling
        data.roots = meta.roots
        data.liveCount = count
        data.deletedCount = 0
        return (data, meta)
    }
}

private func validateSnapshotData(_ data: IndexData, roots: [IndexRoot]) throws {
    for index in 0..<data.count {
        let parentId = Int(data.parent[index])
        if parentId >= index {
            throw SnapshotError.inconsistent("entry \(index) has parent \(parentId)")
        }
        if parentId < 0 && data.flags[index] & EntryFlag.root == 0 {
            throw SnapshotError.inconsistent("entry \(index) has no parent and is not a root")
        }
        if parentId >= 0 && data.flags[parentId] & EntryFlag.directory == 0 {
            throw SnapshotError.inconsistent("entry \(index) has a parent that is not a folder")
        }
        if Int(data.nameStart[index]) + Int(data.nameLength[index]) > data.names.count
            || Int(data.foldStart[index]) + Int(data.foldLength[index]) > data.folded.count {
            throw SnapshotError.inconsistent("entry \(index) name is out of range")
        }
        if data.flags[index] & EntryFlag.deleted != 0 {
            throw SnapshotError.inconsistent("entry \(index) is marked deleted")
        }
    }
    for root in roots {
        let id = Int(root.entryId)
        if id < 0 || id >= data.count || data.flags[id] & EntryFlag.root == 0 {
            throw SnapshotError.inconsistent("root \(root.path) points at entry \(id)")
        }
    }
}
