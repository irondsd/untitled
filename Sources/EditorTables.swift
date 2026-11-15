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
    /// The offset each row was last laid out with; NaN when unknown. Scrolling re-lays only visible
    /// rows, and the others catch up as they scroll into view.
    var laidOut: [CGFloat]
    /// Measured cells per row, kept so an edit re-measures only the rows it touched.
    var metrics: [[CellMetric]?]

    init(_ table: MarkdownTable) {
        self.table = table
        laidOut = Array(repeating: .nan, count: table.rows.count)
        metrics = Array(repeating: nil, count: table.rows.count)
    }
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
            let range = tables[index].range
            if let previous = old.first(where: { $0.range.location == range.location }) {
                tables[index].offset = previous.offset
                if previous.range == range && previous.laidOut.count == tables[index].laidOut.count {
                    tables[index].laidOut = previous.laidOut
                    continue
                }
            }
            // Laid out again below, with the current offset.
            tables[index].laidOut = Array(repeating: tables[index].offset, count: tables[index].laidOut.count)
        }
        guard let storage = editor?.textStorage else { return }
        // Rows of new or changed tables stop wrapping; rows of old tables wrap again.
        let oldRanges = Set(old.map { RangeKey($0.range) }), newRanges = Set(tables.map { RangeKey($0.range) })
        invalidateLayout(oldRanges.symmetricDifference(newRanges).map(\.range))
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
        // Measure and compare every table before writing any of them.
        let writes = tables.indices.flatMap { layoutTable($0, storage: storage).writes }
        guard !writes.isEmpty else { return }
        isApplying = true
        storage.beginEditing()
        write(writes, storage: storage)
        storage.endEditing()
        isApplying = false
        editor?.needsDisplay = true
    }

    /// Measures the table's cells, then kerns each row so its pipes land on shared column boundaries.
    /// Returns whether the column geometry changed.
    private func layoutTable(_ index: Int, storage: NSTextStorage) -> (changed: Bool, writes: [KernWrite]) {
        let table = tables[index].table
        let rows = table.rows
        var metrics: [[EditorTable.CellMetric]] = []
        var widths = [CGFloat](repeating: spaceWidth, count: table.columnCount)
        for (rowIndex, row) in rows.enumerated() {
            guard !row.isDelimiter else { metrics.append([]); continue }
            let measured = tables[index].metrics[rowIndex] ?? measure(row, header: rowIndex == 0, storage: storage)
            tables[index].metrics[rowIndex] = measured
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
        var wanted: [(line: NSRange, kerns: [(range: NSRange, value: CGFloat)])] = []
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
            wanted.append((row.line, kerns.sorted { $0.range.location < $1.range.location }))
        }
        return (changed, kernWrites(wanted, storage: storage))
    }

    /// Rows whose kerning differs from `wanted`. Only reads: reading attributes between writes makes
    /// the storage fix attributes over a growing edited range, which is quadratic on large tables.
    private func kernWrites(_ wanted: [(line: NSRange, kerns: [(range: NSRange, value: CGFloat)])],
                            storage: NSTextStorage) -> [KernWrite] {
        guard let first = wanted.first, let last = wanted.last else { return [] }
        let span = NSRange(location: first.line.location, length: NSMaxRange(last.line) - first.line.location)
        var current: [(range: NSRange, value: CGFloat)] = []
        storage.enumerateAttribute(.kern, in: span) { value, run, _ in
            if let number = value as? NSNumber, number.doubleValue != 0 { current.append((run, CGFloat(number.doubleValue))) }
        }
        var writes: [KernWrite] = [], cursor = 0
        for row in wanted {
            while cursor < current.count && current[cursor].range.location < row.line.location { cursor += 1 }
            var existing: [(range: NSRange, value: CGFloat)] = []
            while cursor < current.count && current[cursor].range.location < NSMaxRange(row.line) {
                existing.append(current[cursor]); cursor += 1
            }
            var merged: [(range: NSRange, value: CGFloat)] = []
            for kern in row.kerns where abs(kern.value) > 0.01 {
                // Storage merges neighbouring runs of equal value.
                if let previous = merged.last, NSMaxRange(previous.range) == kern.range.location, abs(previous.value - kern.value) < 0.01 {
                    merged[merged.count - 1].range.length += kern.range.length
                } else { merged.append(kern) }
            }
            let same = existing.count == merged.count && zip(existing, merged).allSatisfy {
                $0.range == $1.range && abs($0.value - $1.value) < 0.01
            }
            if !same { writes.append(KernWrite(line: row.line, clears: !existing.isEmpty, kerns: merged)) }
        }
        return writes
    }

    struct KernWrite {
        let line: NSRange, clears: Bool
        let kerns: [(range: NSRange, value: CGFloat)]
    }

    private func write(_ writes: [KernWrite], storage: NSTextStorage) {
        for write in writes {
            if write.clears { storage.removeAttribute(.kern, range: write.line) }
            for kern in write.kerns { storage.addAttribute(.kern, value: kern.value, range: kern.range) }
        }
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
            let previous = tables[index]
            tables[index] = EditorTable(parsed)
            tables[index].offset = previous.offset
            if previous.laidOut.count == parsed.rows.count { tables[index].laidOut = previous.laidOut }
            // Rows before and after the edit are unchanged, so keep their measurements.
            if parsed.range.location == previous.range.location {
                let rows = parsed.rows, added = rows.count - previous.table.rows.count
                for row in rows.indices {
                    let line = rows[row].line
                    if NSMaxRange(line) < inserted.location {
                        if row < previous.metrics.count { tables[index].metrics[row] = previous.metrics[row] }
                    } else if line.location > NSMaxRange(inserted), row - added >= 0, row - added < previous.metrics.count {
                        tables[index].metrics[row] = previous.metrics[row - added]
                    }
                }
            }
            clearKerns(NSRange(location: lines.location, length: parsed.range.location - lines.location), storage: storage)
            clearKerns(NSRange(location: NSMaxRange(parsed.range), length: end - NSMaxRange(parsed.range)), storage: storage)
            if !composing {
                let layout = layoutTable(index, storage: storage)
                // Writing attributes while the storage processes an edit is slow; a widened column
                // rewrites every row, so leave that to a pass right after, before the next display.
                if layout.writes.count <= 64 { write(layout.writes, storage: storage) } else { deferredLayout = true }
                if layout.changed { editor?.needsDisplay = true }
            }
        }
        let dropped = removed.map { tables[$0].range }
        for index in removed.reversed() { tables.remove(at: index) }
        if deferredLayout {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.deferredLayout else { return }
                self.deferredLayout = false
                self.layoutTables()
            }
        }
        if !removed.isEmpty {
            editor?.needsDisplay = true
            // Layout cannot be invalidated while the storage processes an edit; rewrap those rows right after.
            DispatchQueue.main.async { [weak self] in self?.invalidateLayout(dropped) }
        }
    }

    private struct RangeKey: Hashable {
        let location: Int, length: Int
        init(_ range: NSRange) { location = range.location; length = range.length }
        var range: NSRange { NSRange(location: location, length: length) }
    }

    func invalidateLayout(_ ranges: [NSRange]) {
        guard let editor, let manager = editor.layoutManager, let storage = editor.textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        for range in ranges {
            let clamped = NSIntersectionRange(range, all)
            guard clamped.location < storage.length else { continue }
            manager.invalidateLayout(forCharacterRange: storage.mutableString.paragraphRange(for: clamped), actualCharacterRange: nil)
        }
        if !ranges.isEmpty { editor.needsDisplay = true }
    }

    // MARK: Sideways scrolling

    /// The scroll offset of the table containing `index`, used by the text container while laying out.
    func tableOffset(at index: Int) -> CGFloat? {
        tableIndex(containing: index).map { tables[$0].offset }
    }

    func tableIndex(containing index: Int) -> Int? {
        var low = 0, high = tables.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(tables[mid].range) < index { low = mid + 1 } else { high = mid }
        }
        guard low < tables.count, NSLocationInRange(index, tables[low].range) || NSMaxRange(tables[low].range) == index else { return nil }
        return low
    }

    /// How far a table can scroll before its right border reaches the editor's edge.
    private func maxOffset(_ index: Int) -> CGFloat {
        guard let editor, let manager = editor.layoutManager, let storage = editor.textStorage,
              let container = editor.textContainer, NSMaxRange(tables[index].range) <= storage.length else { return 0 }
        let origin = editor.textContainerOrigin
        guard let right = tableGeometry(tables[index], manager: manager, storage: storage, origin: origin).columns.last else { return 0 }
        return max(0, (right - origin.x + tables[index].offset + 1 - container.size.width).rounded(.up))
    }

    private func setOffset(_ index: Int, _ value: CGFloat) {
        let clamped = min(max(0, value), maxOffset(index)).rounded()
        guard clamped != tables[index].offset else { return }
        tables[index].offset = clamped
        relayoutVisibleRows(of: index)
    }

    /// Re-lays rows near the visible area whose layout predates the table's current offset.
    func relayoutVisibleRows() {
        guard let editor else { return }
        for index in visibleTables(in: editor.visibleRect) { relayoutVisibleRows(of: index) }
    }

    private func relayoutVisibleRows(of index: Int) {
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer,
              let storage = editor.textStorage, NSMaxRange(tables[index].range) <= storage.length else { return }
        let visible = editor.visibleRect
        let window = visible.insetBy(dx: 0, dy: -visible.height / 2).offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
        let characters = manager.characterRange(forGlyphRange: manager.glyphRange(forBoundingRect: window, in: container), actualGlyphRange: nil)
        let table = tables[index], rows = table.table.rows
        var low = 0, high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(table.line(mid)) < characters.location { low = mid + 1 } else { high = mid }
        }
        var first: Int?, last = 0, row = low
        while row < rows.count, table.line(row).location <= NSMaxRange(characters) {
            if table.laidOut[row] != table.offset {
                if first == nil { first = row }
                last = row
                tables[index].laidOut[row] = table.offset
            }
            row += 1
        }
        guard let first else { return }
        let range = NSRange(location: table.line(first).location, length: NSMaxRange(table.line(last)) - table.line(first).location)
        manager.invalidateLayout(forCharacterRange: storage.mutableString.paragraphRange(for: range), actualCharacterRange: nil)
        editor.needsDisplay = true
    }

    func clampTableOffsets() {
        for index in tables.indices where tables[index].offset > 0 { setOffset(index, tables[index].offset) }
    }

    /// The editor area a table's rows occupy, including their spacing.
    private func tableBand(_ index: Int, manager: NSLayoutManager, origin: NSPoint) -> NSRect? {
        let table = tables[index]
        let first = table.line(0), last = table.line(table.table.rows.count - 1)
        guard let storage = editor?.textStorage, NSMaxRange(last) <= storage.length else { return nil }
        let top = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: first.location), effectiveRange: nil)
        let bottom = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: last.location), effectiveRange: nil)
        return NSRect(x: 0, y: origin.y + top.minY, width: 0, height: bottom.maxY - top.minY)
    }

    private func visibleTables(in rect: NSRect) -> [Int] {
        guard !tables.isEmpty, let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return [] }
        let origin = editor.textContainerOrigin
        let glyphs = manager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return tables.indices.filter {
            NSMaxRange(tables[$0].range) >= visible.location && tables[$0].range.location <= NSMaxRange(visible)
        }
    }

    /// Beside each table, the strips outside the text area: scrolled rows must not draw into the margins.
    func tableMargins(in dirty: NSRect) -> [NSRect] {
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return [] }
        let origin = editor.textContainerOrigin, bounds = editor.bounds
        let right = origin.x + container.size.width
        return visibleTables(in: dirty).flatMap { index -> [NSRect] in
            guard let band = tableBand(index, manager: manager, origin: origin) else { return [] }
            return [NSRect(x: bounds.minX, y: band.minY, width: origin.x - bounds.minX, height: band.height),
                    NSRect(x: right, y: band.minY, width: max(0, bounds.maxX - right), height: band.height)]
        }
    }

    /// Scrolls a wide table sideways with a horizontal swipe or Shift-scroll over it. A gesture
    /// commits to one direction when it starts, so scrolling the note never nudges a table.
    func scrollTable(with event: NSEvent) -> Bool {
        guard !tables.isEmpty, let editor, let manager = editor.layoutManager else { return false }
        let legacy = event.phase.isEmpty && event.momentumPhase.isEmpty
        if legacy || event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            scrollingTable = nil
            scrollGestureDecided = false
        }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        return scrollTable(at: editor.convert(event.locationInWindow, from: nil),
                           deltaX: event.scrollingDeltaX * scale, deltaY: event.scrollingDeltaY * scale)
    }

    /// One scroll step at `point` in editor coordinates; the first step of a gesture picks its direction.
    func scrollTable(at point: NSPoint, deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        guard let editor, let manager = editor.layoutManager else { return false }
        if !scrollGestureDecided {
            guard deltaX != 0 || deltaY != 0 else { return false }
            scrollGestureDecided = true
            guard abs(deltaX) > abs(deltaY) else { return false }
            let origin = editor.textContainerOrigin
            let hit = visibleTables(in: editor.visibleRect).first { index in
                tableBand(index, manager: manager, origin: origin).map { $0.minY <= point.y && point.y <= $0.maxY } ?? false
            }
            guard let hit, maxOffset(hit) > 0 else { return false }
            scrollingTable = tables[hit].range.location
        }
        guard let location = scrollingTable, let index = tables.firstIndex(where: { $0.range.location == location }) else { return false }
        setOffset(index, tables[index].offset - deltaX)
        return true
    }

    /// Keeps the insertion point visible inside a scrolled table, for typing and arrow keys.
    func revealSelectionInTable() {
        guard !tables.isEmpty, let editor, let manager = editor.layoutManager, let storage = editor.textStorage,
              let container = editor.textContainer else { return }
        let selection = editor.selectedRange()
        let location = selection.length == 0 ? selection.location : NSMaxRange(selection)
        guard let index = tableIndex(containing: location), NSMaxRange(tables[index].range) <= storage.length else { return }
        let x: CGFloat
        if location < storage.length {
            let glyph = manager.glyphIndexForCharacter(at: location)
            x = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + manager.location(forGlyphAt: glyph).x
        } else {
            let glyph = manager.glyphIndexForCharacter(at: location - 1)
            x = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
        }
        let margin = cellPadding * 2, width = container.size.width
        if x < margin { setOffset(index, tables[index].offset - (margin - x)) }
        else if x > width - margin { setOffset(index, tables[index].offset + (x - (width - margin))) }
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
        guard let container = editor?.textContainer else { return }
        let geometry = tableGeometry(table, manager: manager, storage: storage, origin: origin)
        guard let left = geometry.columns.first, let right = geometry.columns.last, let firstRow = geometry.rows.first,
              let lastRow = geometry.rows.last else { return }
        let padding = tableRowPadding
        let top = firstRow.top - padding
        let bottom = geometry.rows.count == 1 ? geometry.rule : lastRow.bottom + padding
        let frame = NSRect(x: left, y: top, width: right - left, height: bottom - top)
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        // A scrolled table is cut at the text area's edges, like its rows.
        let viewport = NSRect(x: origin.x, y: top - 1, width: container.size.width, height: bottom - top + 2)
        NSGraphicsContext.saveGraphicsState()
        viewport.clip()
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
        // A thin bar shows that a table is wider than the editor, and how far it is scrolled.
        let total = right - origin.x + table.offset, overflow = total + 1 - container.size.width
        if overflow > 0 {
            let track = container.size.width - 8
            let knob = max(24, track * container.size.width / (total + 1))
            let x = origin.x + 4 + (track - knob) * min(1, table.offset / overflow)
            NSColor(calibratedWhite: 1, alpha: 0.28).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: bottom - 3.5, width: knob, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
