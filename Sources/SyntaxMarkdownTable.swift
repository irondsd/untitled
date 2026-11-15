import Foundation

/// GitHub-flavored Markdown pipe tables, parsed from UTF-16 text. The tokenizer finds them;
/// the editor re-parses a known table while it is edited to keep its columns aligned.
enum MarkdownTableAlignment: Equatable { case left, center, right }

struct MarkdownTableCell: Equatable {
    /// The text between two pipes, or between a pipe and the line edge when a row omits its outer pipe.
    let range: NSRange
    /// The `|` before and after the cell, when present.
    let open: Int?, close: Int?
}

struct MarkdownTableRow: Equatable {
    /// The line without its terminator.
    let line: NSRange
    /// Unescaped `|` positions.
    let pipes: [Int]
    let cells: [MarkdownTableCell]
    let isDelimiter: Bool
}

struct MarkdownTable: Equatable {
    /// The header row, the delimiter row, then body rows.
    let rows: [MarkdownTableRow]
    let alignments: [MarkdownTableAlignment]
    var range: NSRange {
        NSRange(location: rows[0].line.location, length: NSMaxRange(rows[rows.count - 1].line) - rows[0].line.location)
    }
    var columnCount: Int { rows.lazy.filter { !$0.isDelimiter }.map(\.cells.count).max() ?? 0 }
}

enum MarkdownTables {
    private static let delimiterCell = SyntaxRegex.compile(#"^[ \t]*:?-+:?[ \t]*$"#)
    private static let interrupt = SyntaxRegex.compile(#"^ {0,3}(?:#{1,6}(?:[ \t]|$)|>|`{3,}|~{3,})"#)

    /// The pipes and cells of one line, or nil when it has no unescaped pipe.
    static func row(_ text: NSString, line: NSRange) -> MarkdownTableRow? {
        var pipes: [Int] = [], escaped = false, firstContent: Int?
        for index in line.location..<NSMaxRange(line) {
            let character = text.character(at: index)
            if firstContent == nil && character != 0x20 && character != 0x09 { firstContent = index }
            if escaped { escaped = false; continue }
            if character == 0x5C { escaped = true }
            else if character == 0x7C { pipes.append(index) }
        }
        guard let first = pipes.first else { return nil }
        var cells: [MarkdownTableCell] = []
        let leading = firstContent == first
        if !leading { cells.append(MarkdownTableCell(range: NSRange(location: line.location, length: first - line.location), open: nil, close: first)) }
        for (index, pipe) in pipes.enumerated() {
            let start = pipe + 1
            if index + 1 < pipes.count {
                cells.append(MarkdownTableCell(range: NSRange(location: start, length: pipes[index + 1] - start), open: pipe, close: pipes[index + 1]))
            } else {
                let rest = NSRange(location: start, length: NSMaxRange(line) - start)
                if !isBlank(text, rest) { cells.append(MarkdownTableCell(range: rest, open: pipe, close: nil)) }
            }
        }
        let delimiter = !cells.isEmpty && cells.allSatisfy {
            matches(delimiterCell, text.substring(with: $0.range))
        }
        return MarkdownTableRow(line: line, pipes: pipes, cells: cells, isDelimiter: delimiter)
    }

    /// Parses a table whose header line starts at `header`, reading body rows no further than `limit`.
    static func parse(_ text: NSString, header: Int, limit: Int? = nil) -> MarkdownTable? {
        let end = min(limit ?? text.length, text.length)
        guard header < end, let headerLine = lineRange(text, at: header), indent(text, headerLine) < 4,
              let headerRow = row(text, line: headerLine), !headerRow.isDelimiter, !headerRow.cells.isEmpty,
              let next = nextLine(text, after: headerLine), next.location < end,
              let delimiter = row(text, line: next), delimiter.isDelimiter,
              delimiter.cells.count == headerRow.cells.count else { return nil }
        let alignments: [MarkdownTableAlignment] = delimiter.cells.map {
            let cell = text.substring(with: $0.range).trimmingCharacters(in: .whitespaces)
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .right
            default: return .left
            }
        }
        var rows = [headerRow, delimiter], line = nextLine(text, after: next)
        while let current = line, current.location < end, !isBlank(text, current),
              !matches(interrupt, text.substring(with: current)),
              let body = row(text, line: current) {
            rows.append(body)
            line = nextLine(text, after: current)
        }
        return MarkdownTable(rows: rows, alignments: alignments)
    }

    /// The line containing `index`, without its terminator.
    static func lineRange(_ text: NSString, at index: Int) -> NSRange? {
        guard index <= text.length else { return nil }
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    private static func nextLine(_ text: NSString, after line: NSRange) -> NSRange? {
        var end = 0
        text.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: line.location, length: 0))
        guard end < text.length else { return nil }
        return lineRange(text, at: end)
    }

    /// Matching a small substring: bridging a mutable note to String would copy all of it.
    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        expression.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    private static func isBlank(_ text: NSString, _ range: NSRange) -> Bool {
        for index in range.location..<NSMaxRange(range) {
            let character = text.character(at: index)
            if character != 0x20 && character != 0x09 { return false }
        }
        return true
    }

    private static func indent(_ text: NSString, _ line: NSRange) -> Int {
        var count = 0
        while count < line.length && text.character(at: line.location + count) == 0x20 { count += 1 }
        return count
    }
}
