import Foundation

struct CSVSyntax: SyntaxDefinition {
    static let language = NoteLanguage.csv
    static func confidence(in source: SyntaxSource) -> Int { DelimitedSyntax.confidence(in: source, delimiter: 44) }
    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] { DelimitedSyntax.scan(source, delimiter: 44, highlight: true).spans }
}

struct TSVSyntax: SyntaxDefinition {
    static let language = NoteLanguage.tsv
    static func confidence(in source: SyntaxSource) -> Int { DelimitedSyntax.confidence(in: source, delimiter: 9) }
    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] { DelimitedSyntax.scan(source, delimiter: 9, highlight: true).spans }
}

/// CSV-style quoting is shared by comma- and tab-separated text. Column colors follow
/// logical records, so quoted separators and embedded newlines never shift later fields.
private enum DelimitedSyntax {
    struct Scan {
        var spans: [SyntaxSpan] = []
        var widths: [Int] = []
        var valid = true
        var quoted = false
        var numeric = false
    }

    static func confidence(in source: SyntaxSource, delimiter: UInt16) -> Int {
        let result = scan(source, delimiter: delimiter, highlight: false)
        guard !source.cancelled(), result.valid, result.widths.count >= 2,
              let width = result.widths.first, width >= 2,
              result.widths.allSatisfy({ $0 == width }) else { return 0 }
        // Two short comma-separated prose lines are weak evidence. Tabs, a wider table,
        // quoted/numeric cells or a third consistent row make a table more plausible.
        guard delimiter == 9 || width >= 3 || result.quoted || result.numeric || result.widths.count >= 3 else { return 0 }
        // Structured languages outrank a coincidentally consistent set of commas/tabs.
        return delimiter == 9 ? 66 : 65
    }

    static func scan(_ source: SyntaxSource, delimiter: UInt16, highlight: Bool) -> Scan {
        let units = Array(source.text.utf16), text = source.text as NSString
        var result = Scan(), position = 0, start = 0, column = 0
        var quoted = false, closedQuote = false, rowHasContent = false
        if units.first == 0xFEFF { position = 1; start = 1 }
        func newline(_ c: UInt16) -> Bool { c == 10 || c == 13 }
        func field(end: Int) {
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            if highlight { result.spans.append(SyntaxSpan(range: range, kind: .column(column % 6))) }
            else if !result.numeric {
                let value = text.substring(with: range).trimmingCharacters(in: .whitespaces)
                result.numeric = Double(value) != nil
            }
        }
        while position < units.count && !source.cancelled() {
            let c = units[position]
            if quoted {
                rowHasContent = true
                if c == 34 {
                    if position + 1 < units.count && units[position + 1] == 34 { position += 2; continue }
                    quoted = false; closedQuote = true
                }
                position += 1; continue
            }
            if c == delimiter || newline(c) {
                field(end: position)
                if c == delimiter {
                    if highlight { result.spans.append(SyntaxSpan(range: NSRange(location: position, length: 1), kind: .marker)) }
                    column += 1; rowHasContent = true
                } else {
                    if rowHasContent { result.widths.append(column + 1) }
                    column = 0; rowHasContent = false
                    if c == 13 && position + 1 < units.count && units[position + 1] == 10 { position += 1 }
                }
                position += 1; start = position; closedQuote = false
                continue
            }
            if c == 34 && position == start {
                quoted = true; result.quoted = true
            } else if c == 34 || closedQuote && c != 32 && c != 9 {
                // Keep coloring malformed edits, but don't use them as detection evidence.
                result.valid = false
            }
            if c != 32 && c != 9 { rowHasContent = true }
            position += 1
        }
        field(end: position)
        if rowHasContent {
            // A bounded detection sample or an edit may end midway through the last row.
            // Only ignore that tail after at least two complete, consistent records.
            let partialTail = result.widths.count >= 2
                && (quoted || column + 1 < (result.widths.first ?? 0))
            if !highlight && partialTail { return result }
            result.widths.append(column + 1)
        }
        if quoted { result.valid = false }
        return result
    }
}
