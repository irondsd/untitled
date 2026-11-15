import AppKit

/// A Markdown pipe table as the editor lays it out: the parsed rows, measured column widths
/// and, for tables wider than the editor, how far the table is scrolled sideways.
struct EditorTable {
    struct CellMetric: Equatable {
        /// Leading whitespace, trimmed content and trailing whitespace widths.
        let lead: CGFloat, content: CGFloat, trail: CGFloat
    }
    /// Rows as they were when parsed; edits before the table only move it by `shift`.
    private(set) var table: MarkdownTable
    var shift = 0
    var widths: [CGFloat] = []
    /// Column boundaries at pipe centers, relative to the first one.
    var boundaries: [CGFloat] = []
    /// Horizontal scroll position of a table wider than the editor.
    var offset: CGFloat = 0

    init(_ table: MarkdownTable) { self.table = table }
    var range: NSRange { NSRange(location: table.range.location + shift, length: table.range.length) }
    func line(_ row: Int) -> NSRange {
        let line = table.rows[row].line
        return NSRange(location: line.location + shift, length: line.length)
    }
    var hasLeadingPipe: Bool { table.rows[0].cells.first?.open != nil }
    var width: CGFloat { boundaries.last ?? 0 }
}

extension EditorStyler {
    /// Space between a cell's text and its grid lines.
    var cellPadding: CGFloat { (baseFont.pointSize * 0.6).rounded() }
    /// Space above and below each row's text; grid lines sit in the middle of the gap.
    var tableRowPadding: CGFloat { (baseFont.pointSize * 0.3).rounded() }
    /// Extra space between a table and the surrounding text.
    var tableMargin: CGFloat { (baseFont.pointSize * 0.45).rounded() }
    var pipeWidth: CGFloat { ("|" as NSString).size(withAttributes: [.font: baseFont]).width }
    private var spaceWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: baseFont]).width }

    func parseTables(_ spans: [SyntaxStyleSpan]) -> [EditorTable] {
        guard let storage = editor?.textStorage else { return [] }
        let text = storage.mutableString
        return spans.sorted { $0.range.location < $1.range.location }.compactMap { span in
            MarkdownTables.parse(text, header: span.range.location, limit: NSMaxRange(span.range)).map(EditorTable.init)
        }
    }

    /// Takes newly analyzed tables, keeping the scroll position of a table that is still there
    /// and clearing alignment from text that is no longer a table.
    func replaceTables(with new: [EditorTable]) {
        let old = tables
        tables = new
        for index in tables.indices {
            let location = tables[index].range.location
            if let previous = old.first(where: { $0.range.location == location }) { tables[index].offset = previous.offset }
        }
        guard let storage = editor?.textStorage else { return }
        let stale = old.map(\.range).filter { range in !tables.contains { NSIntersectionRange($0.range, range).length > 0 } }
        guard !stale.isEmpty else { return }
        isApplying = true
        storage.beginEditing()
        for range in stale { clearKerns(range, storage: storage) }
        storage.endEditing()
        isApplying = false
        editor?.needsDisplay = true
    }

    /// Aligns every table's columns. Rows whose kerning is already right are left alone.
    func layoutTables() {
        guard let storage = editor?.textStorage, !tables.isEmpty else { return }
        guard editor?.hasMarkedText() != true else { return }
        isApplying = true
        storage.beginEditing()
        for index in tables.indices { layoutTable(index, storage: storage) }
        storage.endEditing()
        isApplying = false
        editor?.needsDisplay = true
    }

    /// Measures the table's cells, then kerns each row so its pipes land on shared column boundaries.
    /// Returns whether the column geometry changed.
    @discardableResult
    private func layoutTable(_ index: Int, storage: NSTextStorage) -> Bool {
        let table = tables[index].table
        let rows = table.rows
        var metrics: [[EditorTable.CellMetric]] = []
        var widths = [CGFloat](repeating: spaceWidth, count: table.columnCount)
        for (rowIndex, row) in rows.enumerated() {
            guard !row.isDelimiter else { metrics.append([]); continue }
            let measured = measure(row, header: rowIndex == 0, storage: storage)
            metrics.append(measured)
            for (column, metric) in measured.enumerated() {
                let cell = row.cells[column]
                widths[column] = max(widths[column], metric.content + (cell.open == nil ? metric.lead : 0))
            }
        }
        let padding = cellPadding, pipe = pipeWidth
        var boundaries: [CGFloat] = [0]
        for width in widths { boundaries.append(boundaries[boundaries.count - 1] + pipe + width + 2 * padding) }
        let changed = widths != tables[index].widths
        tables[index].widths = widths
        tables[index].boundaries = boundaries

        let text = storage.mutableString
        for (rowIndex, row) in rows.enumerated() where !row.isDelimiter {
            var kerns: [(range: NSRange, value: CGFloat)] = []
            for (column, cell) in row.cells.enumerated() {
                let metric = metrics[rowIndex][column], width = widths[column]
                let alignment = column < table.alignments.count ? table.alignments[column] : .left
                let slack = width - metric.content
                let shift = alignment == .right ? slack : alignment == .center ? (slack / 2).rounded() : 0
                let last = cell.range.length > 0
                    ? text.rangeOfComposedCharacterSequence(at: NSMaxRange(cell.range) - 1) : nil
                if let open = cell.open {
                    if let last {
                        kerns.append((NSRange(location: open, length: 1), padding + shift - metric.lead))
                        if cell.close != nil { kerns.append((last, width + padding - shift - metric.content - metric.trail)) }
                    } else {
                        kerns.append((NSRange(location: open, length: 1), width + 2 * padding))
                    }
                } else if let last, cell.close != nil {
                    kerns.append((last, width + padding - metric.lead - metric.content - metric.trail))
                }
            }
            syncKerns(row.line, kerns.sorted { $0.range.location < $1.range.location }, storage: storage)
        }
        return changed
    }

    private func measure(_ row: MarkdownTableRow, header: Bool, storage: NSTextStorage) -> [EditorTable.CellMetric] {
        let text = storage.mutableString
        // Fonts follow the text and its roles, so both identify a row's measurements.
        var key = (header ? "h" : "b") + text.substring(with: row.line)
        storage.enumerateAttribute(Self.fontRole, in: row.line) { value, run, _ in
            if let role = value as? Int { key += "\u{0}\(run.location - row.line.location),\(run.length),\(role)" }
        }
        if let cached = cellMetrics[key] { return cached }
        let space = spaceWidth
        func whitespace(_ range: NSRange) -> CGFloat {
            var width: CGFloat = 0
            for index in range.location..<NSMaxRange(range) { width += text.character(at: index) == 0x09 ? space * 4 : space }
            return width
        }
        let metrics: [EditorTable.CellMetric] = row.cells.map { cell in
            var start = cell.range.location, end = NSMaxRange(cell.range)
            while start < end, [0x20, 0x09].contains(text.character(at: start)) { start += 1 }
            while end > start, [0x20, 0x09].contains(text.character(at: end - 1)) { end -= 1 }
            guard end > start else {
                return EditorTable.CellMetric(lead: whitespace(cell.range), content: 0, trail: 0)
            }
            let content = NSRange(location: start, length: end - start)
            let attributed = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: content))
            attributed.removeAttribute(.kern, range: NSRange(location: 0, length: attributed.length))
            let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
            return EditorTable.CellMetric(lead: whitespace(NSRange(location: cell.range.location, length: start - cell.range.location)),
                                          content: width,
                                          trail: whitespace(NSRange(location: end, length: NSMaxRange(cell.range) - end)))
        }
        if cellMetrics.count > 4_000 { cellMetrics = [:] }
        cellMetrics[key] = metrics
        return metrics
    }

    /// Rewrites a row's kerning only when it differs, so unchanged rows keep their layout.
    private func syncKerns(_ line: NSRange, _ kerns: [(range: NSRange, value: CGFloat)], storage: NSTextStorage) {
        var current: [(range: NSRange, value: CGFloat)] = []
        storage.enumerateAttribute(.kern, in: line) { value, run, _ in
            if let number = value as? NSNumber, number.doubleValue != 0 { current.append((run, CGFloat(number.doubleValue))) }
        }
        var wanted: [(range: NSRange, value: CGFloat)] = []
        for kern in kerns where abs(kern.value) > 0.01 {
            // Storage merges neighbouring runs of equal value.
            if let last = wanted.last, NSMaxRange(last.range) == kern.range.location, abs(last.value - kern.value) < 0.01 {
                wanted[wanted.count - 1].range.length += kern.range.length
            } else { wanted.append(kern) }
        }
        let same = current.count == wanted.count && zip(current, wanted).allSatisfy {
            $0.range == $1.range && abs($0.value - $1.value) < 0.01
        }
        guard !same else { return }
        if !current.isEmpty { storage.removeAttribute(.kern, range: line) }
        for kern in wanted { storage.addAttribute(.kern, value: kern.value, range: kern.range) }
    }

    func clearKerns(_ range: NSRange, storage: NSTextStorage) {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        var kerned = false
        storage.enumerateAttribute(.kern, in: range) { value, _, stop in
            if value != nil { kerned = true; stop.pointee = true }
        }
        if kerned { storage.removeAttribute(.kern, range: range) }
    }

    // MARK: Editing

    /// Moves tables after an edit and returns the tables it touched, with their span after the edit.
    func moveTables(after range: NSRange, changeInLength delta: Int) -> [(index: Int, span: NSRange)] {
        guard !tables.isEmpty else { return [] }
        let oldEnd = NSMaxRange(range) - delta
        var touched: [(index: Int, span: NSRange)] = []
        for index in tables.indices {
            let start = tables[index].range.location, end = NSMaxRange(tables[index].range)
            if end < range.location { continue }
            if start > oldEnd { tables[index].shift += delta; continue }
            // The edit is inside the table or joins one of its lines to the text next to it.
            let newStart = start < range.location ? start : range.location
            let newEnd = end >= oldEnd ? end + delta : NSMaxRange(range)
            touched.append((index, NSRange(location: newStart, length: max(0, newEnd - newStart))))
        }
        return touched
    }

    /// Re-parses tables an edit touched and realigns them; a table whose syntax broke is dropped
    /// until the next analysis. Runs while the storage processes the edit.
    func relayoutTables(_ touched: [(index: Int, span: NSRange)], inserted: NSRange, changeInLength delta: Int,
                        storage: NSTextStorage) {
        let text = storage.mutableString
        // Typed text adopts its neighbour's attributes, including a cell's alignment kerning.
        if inserted.length > 0 { clearKerns(inserted, storage: storage) }
        let composing = editor?.hasMarkedText() == true
        var removed: [Int] = []
        for (index, span) in touched {
            let lines = text.paragraphRange(for: NSIntersectionRange(span, NSRange(location: 0, length: text.length)))
            // Return typed at the start of the header moves the table down rather than breaking it.
            var candidates = [lines.location]
            if delta > 0, inserted.location == span.location, NSMaxRange(inserted) < text.length {
                candidates.append(text.paragraphRange(for: NSRange(location: NSMaxRange(inserted), length: 0)).location)
            }
            let end = NSMaxRange(lines)
            guard let parsed = candidates.lazy.compactMap({ MarkdownTables.parse(text, header: $0, limit: end) }).first else {
                clearKerns(lines, storage: storage)
                removed.append(index)
                continue
            }
            let offset = tables[index].offset
            tables[index] = EditorTable(parsed)
            tables[index].offset = offset
            clearKerns(NSRange(location: lines.location, length: parsed.range.location - lines.location), storage: storage)
            clearKerns(NSRange(location: NSMaxRange(parsed.range), length: end - NSMaxRange(parsed.range)), storage: storage)
            if !composing, layoutTable(index, storage: storage) { editor?.needsDisplay = true }
        }
        for index in removed.reversed() { tables.remove(at: index) }
        if !removed.isEmpty { editor?.needsDisplay = true }
    }

    // MARK: Drawing

    func drawTables(visible: NSRange, manager: NSLayoutManager, storage: NSTextStorage, origin: NSPoint) {
        for table in tables {
            let range = table.range
            if NSMaxRange(range) < visible.location { continue }
            if range.location > NSMaxRange(visible) { break }
            guard NSMaxRange(range) <= storage.length, !table.boundaries.isEmpty else { continue }
            drawTable(table, manager: manager, storage: storage, origin: origin)
        }
    }

    /// The table's grid in text view coordinates: column boundaries and each row's top and bottom.
    func tableGeometry(_ table: EditorTable, manager: NSLayoutManager, storage: NSTextStorage, origin: NSPoint)
        -> (columns: [CGFloat], rows: [(top: CGFloat, bottom: CGFloat)], rule: CGFloat) {
        let header = table.line(0)
        let glyph = manager.glyphIndexForCharacter(at: header.location)
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let start = origin.x + fragment.minX + manager.location(forGlyphAt: glyph).x
        // Rows without outer pipes are indented by a pipe and its padding, so the grid starts at the text margin.
        let left = table.hasLeadingPipe ? start + pipeWidth / 2 : start - cellPadding - pipeWidth / 2
        var rows: [(top: CGFloat, bottom: CGFloat)] = [], rule: CGFloat = 0
        for index in table.table.rows.indices {
            let line = table.line(index)
            let first = usedRect(at: line.location, manager: manager)
            let last = usedRect(at: max(line.location, NSMaxRange(line) - 1), manager: manager)
            if index == 1 { rule = origin.y + (first.minY + last.maxY) / 2; continue }
            rows.append((origin.y + first.minY, origin.y + last.maxY - lineSpacing(at: line.location, storage: storage)))
        }
        return (table.boundaries.map { left + $0 }, rows, rule)
    }

    private func drawTable(_ table: EditorTable, manager: NSLayoutManager, storage: NSTextStorage, origin: NSPoint) {
        let geometry = tableGeometry(table, manager: manager, storage: storage, origin: origin)
        guard let left = geometry.columns.first, let right = geometry.columns.last, let firstRow = geometry.rows.first,
              let lastRow = geometry.rows.last else { return }
        let padding = tableRowPadding
        let top = firstRow.top - padding
        let bottom = geometry.rows.count == 1 ? geometry.rule : lastRow.bottom + padding
        let frame = NSRect(x: left, y: top, width: right - left, height: bottom - top)
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor(calibratedWhite: 1, alpha: 0.03).setFill()
        frame.fill()
        NSColor(calibratedWhite: 1, alpha: 0.05).setFill()
        NSRect(x: left, y: top, width: right - left, height: geometry.rule - top).fill()
        let line = NSColor(calibratedWhite: 1, alpha: 0.12)
        line.setFill()
        for x in geometry.columns.dropFirst().dropLast() {
            NSRect(x: x.rounded() - 0.5, y: top, width: 1, height: bottom - top).fill()
        }
        for index in geometry.rows.indices.dropFirst(2) {
            let y = ((geometry.rows[index - 1].bottom + geometry.rows[index].top) / 2).rounded()
            NSRect(x: left, y: y - 0.5, width: right - left, height: 1).fill()
        }
        NSColor(calibratedWhite: 1, alpha: 0.22).setFill()
        NSRect(x: left, y: geometry.rule.rounded() - 0.5, width: right - left, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        line.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}
