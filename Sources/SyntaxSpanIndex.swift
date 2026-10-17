import Foundation

/// Answers "which spans touch this range" without walking the whole note, so the editor
/// can color only what is on screen. Later overlapping spans still override earlier ones.
struct SyntaxSpanIndex {
    /// Ordered by location; ties keep their original order.
    private let spans: [SyntaxSpan]
    /// Original positions, kept only when spans overlap and their override order matters.
    private let order: [Int]
    /// Running maximum span end, kept only when spans overlap; otherwise each end already ascends.
    private let reach: [Int]

    var count: Int { spans.count }

    init(_ input: [SyntaxSpan] = []) {
        let isSorted = zip(input, input.dropFirst()).allSatisfy { $0.range.location <= $1.range.location }
        let positions = isSorted ? nil : input.indices.sorted {
            (input[$0].range.location, $0) < (input[$1].range.location, $1)
        }
        let sorted = positions.map { $0.map { input[$0] } } ?? input
        var end = 0, overlapping = false
        for span in sorted {
            if span.range.location < end { overlapping = true; break }
            end = NSMaxRange(span.range)
        }
        var reach: [Int] = []
        if overlapping {
            reach.reserveCapacity(sorted.count)
            end = 0
            for span in sorted { end = max(end, NSMaxRange(span.range)); reach.append(end) }
        }
        spans = sorted
        order = overlapping ? positions ?? Array(sorted.indices) : []
        self.reach = reach
    }

    /// Spans clipped to `range`, in their original override order.
    func spans(in range: NSRange) -> [SyntaxSpan] {
        let upper = NSMaxRange(range)
        let high = firstIndex { spans[$0].range.location >= upper }
        let low = firstIndex { (reach.isEmpty ? NSMaxRange(spans[$0].range) : reach[$0]) > range.location }
        guard low < high else { return [] }
        var picked = (low..<high).filter { NSMaxRange(spans[$0].range) > range.location }
        if !order.isEmpty { picked.sort { order[$0] < order[$1] } }
        return picked.compactMap {
            let part = NSIntersectionRange(spans[$0].range, range)
            return part.length > 0 ? SyntaxSpan(range: part, kind: spans[$0].kind) : nil
        }
    }

    /// Binary search for the first position where a monotonic predicate becomes true.
    private func firstIndex(where predicate: (Int) -> Bool) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
