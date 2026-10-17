import AppKit

final class LineNumberRuler: NSRulerView {
    private weak var editor: NSTextView?
    private var observers: [NSObjectProtocol] = []
    private(set) var lines: LogicalLines
    var onThicknessChange: (() -> Void)?
    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView, textView: NSTextView) {
        editor = textView
        lines = LogicalLines(textView.string)
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // AppKit can invalidate beyond a view’s bounds in a full-size-content window.
        // Keep the gutter fill and divider out of the title row.
        clipsToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage, queue: .main) { [weak self] notification in
                guard let self, let storage = notification.object as? NSTextStorage,
                      storage.editedMask.contains(.editedCharacters) else { return }
                self.lines.edited(storage.string as NSString, range: storage.editedRange, changeInLength: storage.changeInLength)
                self.refreshMetrics()
            })
        for (name, object) in [
            (NSView.boundsDidChangeNotification, scrollView.contentView as AnyObject),
            (NSView.frameDidChangeNotification, textView as AnyObject),
            (NSTextView.didChangeSelectionNotification, textView as AnyObject)
        ] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            })
        }
        refreshMetrics()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func refreshMetrics() {
        let font = Theme.font(max(10, (editor?.font?.pointSize ?? 14) - 1))
        let width = (String(lines.starts.count) as NSString).size(withAttributes: [.font: font]).width
        let thickness = max(44, ceil(width + 24))
        if ruleThickness != thickness { ruleThickness = thickness; onThicknessChange?() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }
    func baseline(for line: Int) -> CGFloat? {
        guard let editor, let manager = editor.layoutManager, lines.starts.indices.contains(line) else { return nil }
        let offset = lines.starts[line]
        let font = editor.font ?? Theme.font(14)
        let top: CGFloat
        if offset < lines.length {
            let glyph = manager.glyphIndexForCharacter(at: offset)
            top = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        } else {
            top = manager.extraLineFragmentRect.minY
        }
        // A newline/control glyph has different glyph metrics from a printable character.
        // The typesetter's font baseline is stable for both, including the final empty line.
        return editor.textContainerOrigin.y + top + manager.defaultBaselineOffset(for: font)
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.black.withAlphaComponent(0.10).setFill()
        rect.fill()
        NSColor.white.withAlphaComponent(0.04).setFill()
        NSRect(x: bounds.width - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return }
        let textFont = editor.font ?? Theme.font(14)
        let font = Theme.font(max(10, textFont.pointSize - 1))
        let origin = editor.textContainerOrigin
        let visible = editor.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = manager.glyphRange(forBoundingRect: visible, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let first = lines.line(at: characters.location)
        let last = lines.line(at: min(lines.length, NSMaxRange(characters)))
        let active = lines.line(at: editor.selectedRange().location)

        for line in first...max(first, last) {
            guard let baseline = baseline(for: line) else { continue }
            let y = convert(NSPoint(x: 0, y: baseline), from: editor).y - font.ascender
            guard y + font.pointSize >= rect.minY, y <= rect.maxY else { continue }
            let label = String(line + 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(calibratedWhite: line == active ? 0.82 : 0.48, alpha: 1)
            ]
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: ruleThickness - width - 12, y: y), withAttributes: attributes)
        }
    }
}
