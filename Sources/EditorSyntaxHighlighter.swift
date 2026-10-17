import AppKit

/// Foreground-only temporary attributes never enter the file, clipboard, typing attributes or undo stack.
final class SyntaxHighlighter {
    private weak var editor: NSTextView?
    private var observer: NSObjectProtocol?
    private static let queue = DispatchQueue(label: "local.untitled.syntax", qos: .userInitiated)
    private var work: DispatchWorkItem?
    private var cancellation: FindCancellation?
    private var revision = 0
    private var brightness = 0.93
    private var spans: [SyntaxSpan] = []
    private(set) var language: NoteLanguage = .plain
    private(set) var isHighlighting = false

    init(editor: NSTextView) {
        self.editor = editor
        observer = NotificationCenter.default.addObserver(forName: NSTextView.didChangeNotification,
            object: editor, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        work?.cancel()
        cancellation?.cancel()
    }
    func refresh() {
        work?.cancel()
        cancellation?.cancel()
        revision += 1
        guard let editor else { return }
        spans = []
        // TextKit adjusts existing temporary ranges while typing. Keep those colors
        // until the replacement result is ready, avoiding a flash on every keystroke.
        isHighlighting = true
        let version = revision, snapshot = editor.string, token = FindCancellation()
        cancellation = token
        let task = DispatchWorkItem { [weak self] in
            guard !token.isCancelled else { return }
            let result = SyntaxEngine.analyze(snapshot, cancelled: { token.isCancelled })
            guard !token.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == version else { return }
                self.language = result.language
                self.spans = result.spans
                self.isHighlighting = false
                self.work = nil
                self.cancellation = nil
                self.applyColors()
            }
        }
        work = task
        Self.queue.asyncAfter(deadline: .now() + 0.12, execute: task)
    }
    func applyAppearance(brightness: Double) {
        self.brightness = brightness
        applyColors()
    }
    private func clearColors() {
        guard let editor else { return }
        editor.layoutManager?.removeTemporaryAttribute(.foregroundColor,
            forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }
    private func applyColors() {
        guard let editor, let manager = editor.layoutManager else { return }
        clearColors()
        for span in spans {
            manager.addTemporaryAttribute(.foregroundColor, value: color(span.kind), forCharacterRange: span.range)
        }
        editor.needsDisplay = true
    }
    private func color(_ kind: SyntaxKind) -> NSColor {
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
        }
        let scale = CGFloat(brightness / 0.93)
        return NSColor(calibratedRed: min(1, rgb.0 * scale), green: min(1, rgb.1 * scale), blue: min(1, rgb.2 * scale), alpha: 1)
    }
}
