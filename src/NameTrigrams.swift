import Foundation

private let trigramBucketBits = 20
private let trigramBucketCount = 1 << trigramBucketBits
/// Candidate lists larger than this share of the index are slower to verify
/// than a plain scan.
private let trigramMaxCandidateShare = 0.5

/// Hashed trigram postings over folded names, covering ids `0..<coveredCount`
/// of the index whose layout was `layout`. Entries appended after the build are
/// not covered and must be scanned. Bucket collisions only add candidates, and
/// every candidate is still checked by the normal matcher, so results never
/// change.
struct NameTrigramIndex {
    let layout: UInt64
    let coveredCount: Int
    /// `bucketCount + 1` offsets into `ids`; bucket `b` is `ids[offsets[b]..<offsets[b + 1]]`.
    let offsets: [Int]
    /// Ascending ids per bucket.
    let ids: [Int32]
}

@inline(__always)
private func trigramBucket(_ first: UInt8, _ second: UInt8, _ third: UInt8) -> Int {
    let key = (UInt32(first) << 16) | (UInt32(second) << 8) | UInt32(third)
    return Int((key &* 0x9E37_79B1) >> UInt32(32 - trigramBucketBits))
}

/// Calls `body` once per distinct bucket of `name` (folded bytes).
@inline(__always)
private func forEachBucket(
    _ name: UnsafeBufferPointer<UInt8>,
    id: Int32,
    lastSeen: UnsafeMutablePointer<Int32>,
    _ body: (Int) -> Void
) {
    if name.count < 3 {
        return
    }
    for offset in 0..<(name.count - 2) {
        let bucket = trigramBucket(name[offset], name[offset + 1], name[offset + 2])
        if lastSeen[bucket] != id {
            lastSeen[bucket] = id
            body(bucket)
        }
    }
}

func buildNameTrigramIndex(_ data: IndexData, layout: UInt64) -> NameTrigramIndex {
    let covered = data.count
    var offsets = [Int](repeating: 0, count: trigramBucketCount + 1)
    var ids: [Int32] = []
    let lastSeen = UnsafeMutablePointer<Int32>.allocate(capacity: trigramBucketCount)
    defer { lastSeen.deallocate() }
    withIndexView(data) { view in
        offsets.withUnsafeMutableBufferPointer { counts in
            lastSeen.initialize(repeating: -1, count: trigramBucketCount)
            for index in 0..<covered where view.flags[index] & EntryFlag.deleted == 0 {
                forEachBucket(view.foldedName(index), id: Int32(index), lastSeen: lastSeen) { bucket in
                    counts[bucket + 1] += 1
                }
            }
            for bucket in 0..<trigramBucketCount {
                counts[bucket + 1] += counts[bucket]
            }
        }
        let cursor = UnsafeMutablePointer<Int>.allocate(capacity: trigramBucketCount)
        defer { cursor.deallocate() }
        offsets.withUnsafeBufferPointer { starts in
            cursor.initialize(from: starts.baseAddress!, count: trigramBucketCount)
        }
        ids = [Int32](repeating: 0, count: offsets[trigramBucketCount])
        ids.withUnsafeMutableBufferPointer { output in
            lastSeen.update(repeating: -1, count: trigramBucketCount)
            for index in 0..<covered where view.flags[index] & EntryFlag.deleted == 0 {
                forEachBucket(view.foldedName(index), id: Int32(index), lastSeen: lastSeen) { bucket in
                    output[cursor[bucket]] = Int32(index)
                    cursor[bucket] += 1
                }
            }
        }
    }
    return NameTrigramIndex(layout: layout, coveredCount: covered, offsets: offsets, ids: ids)
}

private func needleBuckets(_ needle: [UInt8]) -> [Int] {
    var buckets: [Int] = []
    for offset in 0..<(needle.count - 2) {
        buckets.append(trigramBucket(needle[offset], needle[offset + 1], needle[offset + 2]))
    }
    return Array(Set(buckets))
}

private func postingCount(_ index: NameTrigramIndex, _ bucket: Int) -> Int {
    return index.offsets[bucket + 1] - index.offsets[bucket]
}

private func posting(_ index: NameTrigramIndex, _ bucket: Int) -> ArraySlice<Int32> {
    return index.ids[index.offsets[bucket]..<index.offsets[bucket + 1]]
}

/// Ascending ids present in both sorted lists. Gallops through `large`.
private func intersectSorted(_ small: ArraySlice<Int32>, _ large: ArraySlice<Int32>) -> [Int32] {
    var result: [Int32] = []
    var low = large.startIndex
    for value in small {
        // Everything before `low` is < value. Gallop until large[probe] >= value.
        var step = 1
        var probe = low
        while probe < large.endIndex && large[probe] < value {
            low = probe + 1
            probe = low + step
            step *= 2
        }
        var upper = min(probe, large.endIndex)
        while low < upper {
            let middle = (low + upper) / 2
            if large[middle] < value {
                low = middle + 1
            } else {
                upper = middle
            }
        }
        if low == large.endIndex {
            break
        }
        if large[low] == value {
            result.append(value)
            low += 1
        }
    }
    return result
}

private func unionSorted(_ left: [Int32], _ right: [Int32]) -> [Int32] {
    var result: [Int32] = []
    result.reserveCapacity(left.count + right.count)
    var leftIndex = 0
    var rightIndex = 0
    while leftIndex < left.count && rightIndex < right.count {
        let leftValue = left[leftIndex]
        let rightValue = right[rightIndex]
        if leftValue < rightValue {
            result.append(leftValue)
            leftIndex += 1
        } else if rightValue < leftValue {
            result.append(rightValue)
            rightIndex += 1
        } else {
            result.append(leftValue)
            leftIndex += 1
            rightIndex += 1
        }
    }
    result.append(contentsOf: left[leftIndex...])
    result.append(contentsOf: right[rightIndex...])
    return result
}

/// Ids whose folded name contains every trigram of `needle`.
private func needleCandidates(_ index: NameTrigramIndex, _ needle: [UInt8]) -> [Int32] {
    let buckets = needleBuckets(needle).sorted { postingCount(index, $0) < postingCount(index, $1) }
    var result = Array(posting(index, buckets[0]))
    for bucket in buckets.dropFirst() {
        if result.isEmpty {
            break
        }
        result = intersectSorted(result[...], posting(index, bucket))
    }
    return result
}

/// Ascending ids below `index.coveredCount` that can match `query`, or nil when
/// no name condition is long enough to narrow the search usefully. Every
/// condition is a list of needles where at least one must appear in the name.
func trigramCandidates(_ index: NameTrigramIndex, query: CompiledQuery) -> [Int32]? {
    var conditions: [[[UInt8]]] = query.nameGroups
    conditions += query.prefixes.map { [$0] }
    conditions += query.suffixes.map { [$0] }
    if !query.extensions.isEmpty {
        conditions.append(query.extensions.map { [0x2E] + $0 })
    }
    if !query.extensionPrefixes.isEmpty {
        conditions.append(query.extensionPrefixes.map { [0x2E] + $0 })
    }
    var best: [[UInt8]]?
    var bestCost = Int.max
    for condition in conditions where !condition.isEmpty && condition.allSatisfy({ $0.count >= 3 }) {
        let cost = condition.reduce(0) { total, needle in
            total + (needleBuckets(needle).map { postingCount(index, $0) }.min() ?? 0)
        }
        if cost < bestCost {
            best = condition
            bestCost = cost
        }
    }
    guard let chosen = best, Double(bestCost) <= Double(index.coveredCount) * trigramMaxCandidateShare else {
        return nil
    }
    var result: [Int32] = []
    for needle in chosen {
        result = unionSorted(result, needleCandidates(index, needle))
    }
    return result
}
