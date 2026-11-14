import AppKit

/// Typography that colors alone cannot express, driven by a format's `SyntaxStyle` spans.
/// Code backgrounds are drawn behind the text and never stored. Ranges follow edits
/// until the next analysis replaces them, so backgrounds do not jump while typing.
final class EditorStyler: NSObject {
    private weak var editor: NSTextView?
    private var observer: NSObjectProtocol?
    /// Code block and inline code ranges, sorted by location and non-overlapping.
    private(set) var backgrounds: [SyntaxStyleSpan] = []

    init(editor: NSTextView) {
        self.editor = editor
        super.init()
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: editor.textStorage, queue: nil) { [weak self] notification in
                guard let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
                self?.edited(storage.editedRange, changeInLength: storage.changeInLength)
            }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func apply(_ styles: [SyntaxStyleSpan]) {
        let drawn = styles.filter { $0.style == .codeBlock || $0.style == .inlineCode }
            .sorted { $0.range.location < $1.range.location }
        guard drawn.map(\.range) != backgrounds.map(\.range) || drawn.map(\.style) != backgrounds.map(\.style) else { return }
        backgrounds = drawn
        editor?.needsDisplay = true
    }

    /// Shifts ranges after an edit; a range touching the edit grows or shrinks with it.
    private func edited(_ range: NSRange, changeInLength delta: Int) {
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
        guard !backgrounds.isEmpty, let editor, let manager = editor.layoutManager,
              let container = editor.textContainer, let storage = editor.textStorage, storage.length > 0 else { return }
        let origin = editor.textContainerOrigin
        let glyphs = manager.glyphRange(forBoundingRect: dirty.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
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
    private func usedRect(at character: Int, manager: NSLayoutManager) -> NSRect {
        manager.lineFragmentUsedRect(forGlyphAt: manager.glyphIndexForCharacter(at: character), effectiveRange: nil)
    }
    private func lineSpacing(at character: Int, storage: NSTextStorage) -> CGFloat {
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
