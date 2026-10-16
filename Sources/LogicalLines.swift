import Foundation

/// UTF-16 offsets match TextKit. Soft wrapping never changes this index.
struct LogicalLines {
    private(set) var starts: [Int] = [0]
    private(set) var length = 0

    init(_ text: String) { rebuild(text as NSString) }

    mutating func rebuild(_ text: NSString) {
        length = text.length
        starts = Self.scan(text, from: 0, through: length, includeTrailingEmpty: true)
    }

    func line(at offset: Int) -> Int {
        let value = min(length, max(0, offset))
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    mutating func edited(_ text: NSString, range: NSRange, changeInLength delta: Int) {
        guard range.location != NSNotFound, text.length == length + delta else { rebuild(text); return }
        // Include neighboring lines so edits at either half of a CRLF are handled correctly.
        let first = line(at: max(0, range.location - 1))
        let oldEnd = range.location + range.length - delta
        let suffix = min(starts.count, line(at: min(length, oldEnd + 1)) + 2)
        let start = starts[first]
        let boundary = suffix < starts.count ? starts[suffix] + delta : text.length
        guard start <= boundary, boundary <= text.length else { rebuild(text); return }
        let repaired = Self.scan(text, from: start, through: boundary, includeTrailingEmpty: suffix == starts.count)
        starts = Array(starts[..<first]) + repaired + starts[suffix...].map { $0 + delta }
        length = text.length
    }

    private static func scan(_ text: NSString, from start: Int, through end: Int, includeTrailingEmpty: Bool) -> [Int] {
        var offsets = [start]
        var position = start
        while position < end {
            var lineEnd = 0, contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
            guard lineEnd > position else { break }
            if lineEnd < end || (includeTrailingEmpty && lineEnd == end && contentsEnd < lineEnd) {
                offsets.append(lineEnd)
            }
            position = lineEnd
        }
        return offsets
    }
}
