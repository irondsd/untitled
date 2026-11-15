import AppKit

/// Typography that colors alone cannot express, driven by a format's `SyntaxStyle` spans.
///
/// Code backgrounds are drawn behind the text and never stored. Heading sizes, bold/italic
/// and paragraph spacing must affect layout, so they are real text storage attributes, each
/// tagged with a role so they can be diffed and cleared. They never reach the file, the
/// clipboard (the editor is plain text) or the undo stack, and edits keep them consistent
/// until the next analysis replaces them.
final class EditorStyler: NSObject, NSTextStorageDelegate {
    /// Font role: heading level in the low bits, plus bold and italic flags. Zero is the base font.
    static let fontRole = NSAttributedString.Key("local.untitled.fontRole")
    /// Paragraph role: which spacing a paragraph carries. Zero is the base paragraph style.
    static let paragraphRole = NSAttributedString.Key("local.untitled.paragraphRole")
    private static let bold = 1 << 3, italic = 1 << 4, levelMask = 7
    private enum Paragraph {
        static func heading(_ level: Int) -> Int { 10 + level }
        static func setextTitle(_ level: Int) -> Int { 20 + level }
        static let setextUnderline = 30, fenceOpen = 31, fenceClose = 32, fenceBoth = 33
        static let tableRow = 40, tableHeader = 41, tableLast = 42, tableDelimiter = 43, tableDelimiterLast = 44
        /// Added to a table role when rows omit their outer pipes: the indent stands in for the missing `|`.
        static let tableIndented = 10
    }
    /// About a quarter second for the first pass on a large note; beyond this, typography is skipped.
    static let maximumTypographySpans = 20_000
    private static let headingLine = SyntaxRegex.compile(#"^ {0,3}#{1,6}(?:[ \t]|$)"#)
    private static let fenceLine = SyntaxRegex.compile(#"^ {0,3}(?:`{3,}|~{3,})"#)
    private static let underlineLine = SyntaxRegex.compile(#"^ {0,3}(?:=+|-+)[ \t]*$"#)

    weak var editor: NSTextView?
    private(set) var baseFont: NSFont = Theme.font(14)
    private(set) var baseParagraph: NSParagraphStyle = .default
    private var fonts: [Int: NSFont] = [:]
    private var paragraphs: [Int: NSParagraphStyle] = [:]
    /// Code block and inline code ranges, sorted by location and non-overlapping.
    private(set) var backgrounds: [SyntaxStyleSpan] = []
    /// The latest typographic styles, kept so a base font change can rebuild them.
    private var typography: [SyntaxStyleSpan] = []
    /// Pipe tables, sorted by location. Columns are aligned with kerning and drawn as a grid.
    var tables: [EditorTable] = []
    /// Measured cells per row text and font roles; widths only change with the base font.
    var cellMetrics: [String: [EditorTable.CellMetric]] = [:]
    /// Whether any role attribute may be present; plain notes skip edit-time fixes entirely.
    private var hasRoles = false
    var isApplying = false

    init(editor: NSTextView) {
        self.editor = editor
        super.init()
        editor.textStorage?.delegate = self
    }

    // MARK: Base appearance

    func setBase(font: NSFont, paragraph: NSParagraphStyle) {
        baseFont = font
        baseParagraph = paragraph
        fonts = [:]
        paragraphs = [:]
        cellMetrics = [:]
        // Setting the editor font replaced every font, so rebuild all roles, not just the changed ones.
        applyTypography(force: true)
        layoutTables()
    }

    func font(for role: Int) -> NSFont {
        if role == 0 { return baseFont }
        if let cached = fonts[role] { return cached }
        let manager = NSFontManager.shared
        var font = baseFont
        let level = role & Self.levelMask
        if level > 0 || role & Self.bold != 0 { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if role & Self.italic != 0 { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        if level > 0 {
            let scale: CGFloat = [1.45, 1.25, 1.12, 1, 1, 1][min(level, 6) - 1]
            font = manager.convert(font, toSize: (baseFont.pointSize * scale * 2).rounded() / 2)
        }
        fonts[role] = font
        return font
    }

    private func paragraph(for role: Int) -> NSParagraphStyle {
        if role == 0 { return baseParagraph }
        if let cached = paragraphs[role] { return cached }
        if (50...54).contains(role) {
            let style = paragraph(for: role - Paragraph.tableIndented).mutableCopy() as! NSMutableParagraphStyle
            style.firstLineHeadIndent = cellPadding + pipeWidth
            style.headIndent = style.firstLineHeadIndent
            paragraphs[role] = style
            return style
        }
        let style = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
        let size = baseFont.pointSize
        func heading(_ level: Int) -> (before: CGFloat, after: CGFloat) {
            switch level { case 1: return (0.9, 0.35); case 2: return (0.8, 0.3); default: return (0.6, 0.2) }
        }
        switch role {
        case Paragraph.setextUnderline: style.paragraphSpacing = heading(2).after * size
        case Paragraph.fenceOpen: style.paragraphSpacingBefore = 0.3 * size
        case Paragraph.fenceClose: style.paragraphSpacing = 0.3 * size
        case Paragraph.fenceBoth: style.paragraphSpacingBefore = 0.3 * size; style.paragraphSpacing = 0.3 * size
        case Paragraph.tableRow, Paragraph.tableHeader, Paragraph.tableLast:
            style.paragraphSpacingBefore = tableRowPadding + (role == Paragraph.tableHeader ? tableMargin : 0)
            style.paragraphSpacing = tableRowPadding + (role == Paragraph.tableLast ? tableMargin : 0)
        case Paragraph.tableDelimiter, Paragraph.tableDelimiterLast:
            // The delimiter row's characters are hidden behind the header rule, so it only needs a sliver of height.
            let height = (size * 0.5).rounded()
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            style.lineSpacing = 0
            if role == Paragraph.tableDelimiterLast { style.paragraphSpacing = tableRowPadding + tableMargin }
        case 21...26: style.paragraphSpacingBefore = heading(role - 20).before * size
        case 11...16:
            let spacing = heading(role - 10)
            style.paragraphSpacingBefore = spacing.before * size
            style.paragraphSpacing = spacing.after * size
        default: break
        }
        paragraphs[role] = style
        return style
    }

    // MARK: Applying analysis results

    func apply(_ styles: [SyntaxStyleSpan]) {
        let drawn = styles.filter { $0.style == .codeBlock || $0.style == .inlineCode }
            .sorted { $0.range.location < $1.range.location }
        if drawn.map(\.range) != backgrounds.map(\.range) || drawn.map(\.style) != backgrounds.map(\.style) {
            backgrounds = drawn
            editor?.needsDisplay = true
        }
        let typographic = styles.filter { $0.style != .inlineCode && $0.style != .table }
        let parsed = parseTables(styles.filter { $0.style == .table })
        // Fonts and spacing cost layout work per span or table row; a huge note keeps colors and drawn backgrounds only.
        let cost = typographic.count + parsed.reduce(0) { $0 + $1.table.rows.count }
        let within = cost <= Self.maximumTypographySpans
        typography = within ? typographic : []
        replaceTables(with: within ? parsed : [])
        applyTypography(force: false)
        layoutTables()
    }

    /// Sets fonts and paragraph styles where their roles differ from the analysis. Unchanged
    /// text keeps its attributes, so TextKit only lays out what actually changed.
    private func applyTypography(force: Bool) {
        guard let editor, let storage = editor.textStorage else { return }
        // Restyling during input method composition would disturb the marked text; the next analysis catches up.
        guard !editor.hasMarkedText() else { return }
        let text = storage.mutableString, length = storage.length
        guard hasRoles || !typography.isEmpty || !tables.isEmpty || force else { return }

        // Font roles: sweep span boundaries, since emphasis can sit inside a heading.
        var events: [(position: Int, delta: Int, style: SyntaxStyle)] = []
        // Paragraph roles never overlap: each line has at most one.
        var paragraphRuns: [(range: NSRange, role: Int)] = []
        for span in typography {
            let range = NSIntersectionRange(span.range, NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            switch span.style {
            case .heading(let level):
                events += [(range.location, 1, span.style), (NSMaxRange(range), -1, span.style)]
                paragraphRuns.append((text.paragraphRange(for: range), Paragraph.heading(level)))
            case .setextHeading(let level):
                events += [(range.location, 1, span.style), (NSMaxRange(range), -1, span.style)]
                paragraphRuns.append((text.paragraphRange(for: range), Paragraph.setextTitle(level)))
            case .setextUnderline:
                paragraphRuns.append((text.paragraphRange(for: range), Paragraph.setextUnderline))
            case .codeBlock:
                let open = text.paragraphRange(for: NSRange(location: range.location, length: 0))
                let close = text.paragraphRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
                if open == close { paragraphRuns.append((open, Paragraph.fenceBoth)) }
                else { paragraphRuns += [(open, Paragraph.fenceOpen), (close, Paragraph.fenceClose)] }
            case .strong, .emphasis:
                events += [(range.location, 1, span.style), (NSMaxRange(range), -1, span.style)]
            case .inlineCode, .table: break
            }
        }
        for table in tables {
            let rows = table.table.rows
            for index in rows.indices {
                let line = table.line(index)
                let role: Int
                switch index {
                case 0: role = Paragraph.tableHeader
                case 1: role = rows.count == 2 ? Paragraph.tableDelimiterLast : Paragraph.tableDelimiter
                case rows.count - 1: role = Paragraph.tableLast
                default: role = Paragraph.tableRow
                }
                paragraphRuns.append((text.paragraphRange(for: line), role + (table.hasLeadingPipe ? 0 : Paragraph.tableIndented)))
            }
            let header = table.line(0)
            events += [(header.location, 1, .strong), (NSMaxRange(header), -1, .strong)]
        }
        events.sort { $0.position < $1.position }
        var fontRuns: [(range: NSRange, role: Int)] = []
        var level = 0, bold = 0, italic = 0, position = 0, index = 0
        while index < events.count {
            let at = events[index].position
            let role = level | (bold > 0 ? Self.bold : 0) | (italic > 0 ? Self.italic : 0)
            if at > position, role != 0 { fontRuns.append((NSRange(location: position, length: at - position), role)) }
            while index < events.count && events[index].position == at {
                let event = events[index]
                switch event.style {
                case .heading(let value), .setextHeading(let value): level = event.delta > 0 ? min(value, 6) : 0
                case .strong: bold += event.delta
                case .emphasis: italic += event.delta
                default: break
                }
                index += 1
            }
            position = at
        }
        paragraphRuns.sort { $0.range.location < $1.range.location }

        // Read everything before writing: reading attributes after a write makes the storage
        // fix attributes over the growing edited range, which is quadratic on large notes.
        let fontChanges = changes(Self.fontRole, runs: fontRuns, force: force, storage: storage)
        let paragraphChanges = changes(Self.paragraphRole, runs: paragraphRuns, force: force, storage: storage)
        if !fontChanges.isEmpty || !paragraphChanges.isEmpty {
            isApplying = true
            storage.beginEditing()
            // Write front to back across both keys. Storage keeps attribute runs in an array, so a
            // second full pass would shift every already split run on each write.
            var fontIndex = 0, paragraphIndex = 0
            while fontIndex < fontChanges.count || paragraphIndex < paragraphChanges.count {
                let takeFont = paragraphIndex == paragraphChanges.count || (fontIndex < fontChanges.count
                    && fontChanges[fontIndex].range.location < paragraphChanges[paragraphIndex].range.location)
                if takeFont {
                    let change = fontChanges[fontIndex]; fontIndex += 1
                    set(Self.fontRole, change.role, [.font: font(for: change.role)], change.range, storage)
                } else {
                    let change = paragraphChanges[paragraphIndex]; paragraphIndex += 1
                    set(Self.paragraphRole, change.role, [.paragraphStyle: paragraph(for: change.role)], change.range, storage)
                }
            }
            storage.endEditing()
            isApplying = false
        }
        hasRoles = !fontRuns.isEmpty || !paragraphRuns.isEmpty
    }

    /// The segments where `key` differs from `runs` (everything else is role zero).
    private func changes(_ key: NSAttributedString.Key, runs: [(range: NSRange, role: Int)], force: Bool,
                         storage: NSTextStorage) -> [(range: NSRange, role: Int)] {
        let length = storage.length
        guard length > 0 else { return [] }
        var segments: [(range: NSRange, role: Int)] = [], position = 0
        for run in runs where run.range.location >= position {
            if run.range.location > position { segments.append((NSRange(location: position, length: run.range.location - position), 0)) }
            segments.append(run)
            position = NSMaxRange(run.range)
        }
        if position < length { segments.append((NSRange(location: position, length: length - position), 0)) }
        return segments.filter { segment in
            guard segment.range.length > 0 else { return false }
            // A forced pass still skips untagged text: the editor font already reset it to the base.
            if force && segment.role != 0 { return true }
            var effective = NSRange()
            let current = storage.attribute(key, at: segment.range.location, longestEffectiveRange: &effective, in: segment.range) as? Int ?? 0
            return current != segment.role || effective != segment.range
        }
    }

    private func set(_ key: NSAttributedString.Key, _ role: Int, _ attributes: [NSAttributedString.Key: Any],
                     _ range: NSRange, _ storage: NSTextStorage) {
        storage.addAttributes(attributes, range: range)
        if role == 0 { storage.removeAttribute(key, range: range) }
        else { storage.addAttribute(key, value: role, range: range) }
    }

    // MARK: Keeping styles consistent while typing

    /// Runs before TextKit lays out an edit, the one point where layout attributes may still change.
    func textStorage(_ storage: NSTextStorage, willProcessEditing mask: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters), !isApplying else { return }
        moveBackgrounds(after: range, changeInLength: delta)
        let edited = moveTables(after: range, changeInLength: delta)
        guard hasRoles, storage.length > 0 else { return }
        // `mutableString` avoids copying the whole note on every keystroke.
        let undoing = editor?.undoManager?.isUndoing == true || editor?.undoManager?.isRedoing == true
        // Undo restores the attributes the text had; new text adopts its surroundings.
        if range.length > 0 && !undoing { styleInsertion(range, storage: storage) }
        let text = storage.mutableString
        let first = text.paragraphRange(for: NSRange(location: min(range.location, text.length), length: 0))
        fixParagraph(first, storage: storage)
        if NSMaxRange(range) >= NSMaxRange(first), NSMaxRange(range) < text.length {
            fixParagraph(text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)), storage: storage)
        }
        // Realign the edited table now, so its columns never lag behind typing.
        if !edited.isEmpty { relayoutTables(edited, inserted: range, changeInLength: delta, storage: storage) }
    }

    /// Typed text continues a run it sits inside, such as a bold word; otherwise it takes the
    /// line's heading size or the base font. The next analysis settles anything else.
    private func styleInsertion(_ range: NSRange, storage: NSTextStorage) {
        let text = storage.mutableString
        func role(at index: Int) -> Int? {
            index >= 0 && index < storage.length ? storage.attribute(Self.fontRole, at: index, effectiveRange: nil) as? Int ?? 0 : nil
        }
        var value = 0
        if text.rangeOfCharacter(from: .newlines, options: [], range: range).location == NSNotFound {
            if let before = role(at: range.location - 1), let after = role(at: NSMaxRange(range)), before == after,
               !isNewline(text, NSMaxRange(range)) {
                value = before
            } else {
                let line = text.paragraphRange(for: NSRange(location: range.location, length: 0))
                let start = line.location == range.location ? NSMaxRange(range) : line.location
                if let lineRole = role(at: start), start < NSMaxRange(line) { value = lineRole & Self.levelMask }
            }
        }
        storage.addAttribute(.font, value: font(for: value), range: range)
        if value == 0 { storage.removeAttribute(Self.fontRole, range: range) }
        else { storage.addAttribute(Self.fontRole, value: value, range: range) }
    }

    private func isNewline(_ text: NSString, _ index: Int) -> Bool {
        index < text.length && CharacterSet.newlines.contains(UnicodeScalar(text.character(at: index)) ?? " ")
    }

    /// Drops heading sizes and spacing from a line that no longer has the syntax for them,
    /// and spreads a heading's size over text joined onto its line.
    private func fixParagraph(_ paragraph: NSRange, storage: NSTextStorage) {
        guard paragraph.length > 0 else { return }
        let text = storage.mutableString
        var contentEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentEnd, for: NSRange(location: paragraph.location, length: 0))
        let content = NSRange(location: paragraph.location, length: contentEnd - paragraph.location)
        let line = text.substring(with: content)
        let next = NSMaxRange(paragraph) < text.length
            ? text.paragraphRange(for: NSRange(location: NSMaxRange(paragraph), length: 0)) : nil
        let nextLine = next.map { text.substring(with: $0).trimmingCharacters(in: .newlines) } ?? ""
        func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
            expression.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
        }
        let isHeading = matches(Self.headingLine, line)
        let isTitle = !line.trimmingCharacters(in: .whitespaces).isEmpty && next != nil && matches(Self.underlineLine, nextLine)
        let isUnderline = matches(Self.underlineLine, line)
        let isFence = matches(Self.fenceLine, line)

        let paragraphRole = storage.attribute(Self.paragraphRole, at: paragraph.location, effectiveRange: nil) as? Int ?? 0
        let keeps: Bool
        switch paragraphRole {
        case 0: keeps = true
        case 11...16: keeps = isHeading
        case 21...26: keeps = isTitle
        case Paragraph.setextUnderline: keeps = isUnderline
        case Paragraph.tableRow...(Paragraph.tableDelimiterLast + Paragraph.tableIndented): keeps = line.contains("|")
        default: keeps = isFence
        }
        if !keeps {
            storage.addAttribute(.paragraphStyle, value: baseParagraph, range: paragraph)
            storage.removeAttribute(Self.paragraphRole, range: paragraph)
        }

        guard content.length > 0 else { return }
        let lineLevel = (storage.attribute(Self.fontRole, at: content.location, effectiveRange: nil) as? Int ?? 0) & Self.levelMask
        let level = (isHeading || isTitle) ? lineLevel : 0
        var updates: [(NSRange, Int)] = []
        storage.enumerateAttribute(Self.fontRole, in: content) { value, run, _ in
            let role = value as? Int ?? 0
            if role & Self.levelMask != level { updates.append((run, (role & ~Self.levelMask) | level)) }
        }
        for (run, role) in updates {
            storage.addAttribute(.font, value: font(for: role), range: run)
            if role == 0 { storage.removeAttribute(Self.fontRole, range: run) }
            else { storage.addAttribute(Self.fontRole, value: role, range: run) }
        }
    }

    // MARK: Code backgrounds

    /// Shifts ranges after an edit; a range touching the edit grows or shrinks with it.
    private func moveBackgrounds(after range: NSRange, changeInLength delta: Int) {
        guard !backgrounds.isEmpty else { return }
        let oldEnd = NSMaxRange(range) - delta
        backgrounds = backgrounds.compactMap { span in
            var start = span.range.location, end = NSMaxRange(span.range)
            if end < range.location { return span }
            if start >= oldEnd { start += delta; end += delta }
            else {
                if start > range.location { start = range.location }
                end = end >= oldEnd ? end + delta : NSMaxRange(range)
            }
            return end > start ? SyntaxStyleSpan(range: NSRange(location: start, length: end - start), style: span.style) : nil
        }
    }

    /// Fills code backgrounds intersecting `dirty`, in text view coordinates, before the text draws.
    func drawBackgrounds(in dirty: NSRect) {
        guard !backgrounds.isEmpty || !tables.isEmpty, let editor, let manager = editor.layoutManager,
              let container = editor.textContainer, let storage = editor.textStorage, storage.length > 0 else { return }
        let origin = editor.textContainerOrigin
        let glyphs = manager.glyphRange(forBoundingRect: dirty.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        drawTables(visible: visible, manager: manager, storage: storage, origin: origin)
        guard !backgrounds.isEmpty else { return }
        // Non-overlapping ranges sorted by location also have ascending ends.
        var low = 0, high = backgrounds.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(backgrounds[mid].range) < visible.location { low = mid + 1 } else { high = mid }
        }
        for span in backgrounds[low...] {
            guard span.range.location <= NSMaxRange(visible) else { break }
            let range = NSIntersectionRange(span.range, NSRange(location: 0, length: storage.length))
            guard range.length > 0 else { continue }
            if span.style == .codeBlock { drawBlock(range, manager: manager, container: container, storage: storage, origin: origin) }
            else { drawInline(range, manager: manager, container: container, storage: storage, origin: origin) }
        }
    }

    /// The used rect excludes paragraph spacing but includes the line spacing below the text.
    func usedRect(at character: Int, manager: NSLayoutManager) -> NSRect {
        manager.lineFragmentUsedRect(forGlyphAt: manager.glyphIndexForCharacter(at: character), effectiveRange: nil)
    }
    func lineSpacing(at character: Int, storage: NSTextStorage) -> CGFloat {
        (storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing ?? 0
    }

    private func drawBlock(_ range: NSRange, manager: NSLayoutManager, container: NSTextContainer, storage: NSTextStorage, origin: NSPoint) {
        let last = NSMaxRange(range) - 1
        let top = usedRect(at: range.location, manager: manager), bottom = usedRect(at: last, manager: manager)
        let pad: CGFloat = 3
        let minY = top.minY - pad, maxY = bottom.maxY - lineSpacing(at: last, storage: storage) + pad
        let rect = NSRect(x: origin.x - 4, y: origin.y + minY, width: container.size.width + 8, height: maxY - minY)
        NSColor(calibratedWhite: 1, alpha: 0.055).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    private func drawInline(_ range: NSRange, manager: NSLayoutManager, container: NSTextContainer, storage: NSTextStorage, origin: NSPoint) {
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let spacing = lineSpacing(at: range.location, storage: storage)
        NSColor(calibratedWhite: 1, alpha: 0.09).setFill()
        // One rounded rect per wrapped row, spanning only the text's own height.
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, line, _ in
            let part = NSIntersectionRange(line, glyphs)
            guard part.length > 0 else { return }
            let bounds = manager.boundingRect(forGlyphRange: part, in: container)
            let rect = NSRect(x: origin.x + bounds.minX - 1, y: origin.y + used.minY,
                              width: bounds.width + 2, height: max(0, used.height - spacing))
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
    }
}
