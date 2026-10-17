import AppKit

/// Foreground-only temporary attributes never enter the file, clipboard, typing attributes or undo stack.
/// Only the visible text and a screen above and below carry colors; scrolling paints the rest on demand.
final class SyntaxHighlighter {
    private weak var editor: NSTextView?
    private var observer: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private static let queue = DispatchQueue(label: "local.untitled.syntax", qos: .userInitiated)
    private var work: DispatchWorkItem?
    private var cancellation: FindCancellation?
    private var revision = 0
    private var brightness = 0.93
    private var index = SyntaxSpanIndex()
    /// Characters that currently carry syntax colors, as of the last paint.
    private var painted = NSRange(location: 0, length: 0)
    /// One color per token kind, shared by every span of that kind.
    private var palette: [SyntaxKind: NSColor] = [:]
    private(set) var language: NoteLanguage = .plain
    /// A manually chosen format; nil follows automatic detection.
    var override: NoteLanguage? { didSet { if override != oldValue { refresh() } } }
    private(set) var isHighlighting = false

    init(editor: NSTextView) {
        self.editor = editor
        observer = NotificationCenter.default.addObserver(forName: NSTextView.didChangeNotification,
            object: editor, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        work?.cancel()
        cancellation?.cancel()
    }
    func refresh() {
        work?.cancel()
        cancellation?.cancel()
        revision += 1
        guard let editor else { return }
        index = SyntaxSpanIndex()
        // TextKit adjusts existing temporary ranges while typing. Keep those colors
        // until the replacement result is ready, avoiding a flash on every keystroke.
        isHighlighting = true
        let version = revision, snapshot = editor.string, forced = override, token = FindCancellation()
        cancellation = token
        let task = DispatchWorkItem { [weak self] in
            guard !token.isCancelled else { return }
            let result = SyntaxEngine.analyze(snapshot, language: forced, cancelled: { token.isCancelled })
            guard !token.isCancelled else { return }
            let index = SyntaxSpanIndex(result.spans)
            guard !token.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == version else { return }
                self.language = result.language
                self.index = index
                self.isHighlighting = false
                self.work = nil
                self.cancellation = nil
                self.paint(force: true)
            }
        }
        work = task
        Self.queue.asyncAfter(deadline: .now() + 0.12, execute: task)
    }
    /// Repaints as the visible text changes; call once the editor sits in its scroll view.
    func track(_ clip: NSClipView) {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main) { [weak self] _ in self?.paint() }
    }
    func applyAppearance(brightness: Double) {
        self.brightness = brightness
        palette = [:]
        paint(force: true)
    }
    /// Colors the visible text plus one screen either side. Unless forced, scrolling within
    /// the painted margin costs nothing. While an edit is analyzed the old colors stay put.
    func paint(force: Bool = false) {
        guard force || !isHighlighting, let editor, let manager = editor.layoutManager,
              let container = editor.textContainer, let length = editor.textStorage?.length else { return }
        let origin = editor.textContainerOrigin
        func characters(in rect: NSRect) -> NSRange {
            let glyphs = manager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            return manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        }
        let visible = editor.visibleRect
        // A tab that is not on screen keeps its colors until it is shown again.
        guard force || !visible.isEmpty else { return }
        if !force {
            let shown = characters(in: visible)
            if shown.location >= painted.location && NSMaxRange(shown) <= NSMaxRange(painted) { return }
        }
        let window = visible.isEmpty ? NSRange(location: 0, length: 0)
            : characters(in: visible.insetBy(dx: 0, dy: -visible.height))
        // Editing shifts existing temporary ranges, so clear the whole note. Few runs remain, so this is cheap.
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        for span in index.spans(in: NSIntersectionRange(window, NSRange(location: 0, length: length))) {
            manager.addTemporaryAttribute(.foregroundColor, value: color(span.kind), forCharacterRange: span.range)
        }
        painted = window
        editor.needsDisplay = true
    }
    private func color(_ kind: SyntaxKind) -> NSColor {
        if let cached = palette[kind] { return cached }
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch kind {
        case .heading, .key, .type: rgb = (0.56, 0.79, 1.0)
        case .string, .code: rgb = (0.67, 0.86, 0.64)
        case .number: rgb = (1.0, 0.78, 0.54)
        case .function: rgb = (0.95, 0.84, 0.61)
        case .literal, .emphasis, .keyword: rgb = (0.84, 0.72, 1.0)
        case .comment: rgb = (0.66, 0.71, 0.76)
        case .marker: rgb = (0.63, 0.81, 0.85)
        case .link: rgb = (0.52, 0.85, 0.92)
        case .tag: rgb = (0.95, 0.58, 0.62)
        case .attribute: rgb = (0.93, 0.79, 0.55)
        }
        let scale = CGFloat(brightness / 0.93)
        let value = NSColor(calibratedRed: min(1, rgb.0 * scale), green: min(1, rgb.1 * scale), blue: min(1, rgb.2 * scale), alpha: 1)
        palette[kind] = value
        return value
    }
}
