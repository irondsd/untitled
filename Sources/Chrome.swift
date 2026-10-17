import AppKit

enum Theme {
    static let text = NSColor(calibratedWhite: 0.93, alpha: 1)
    static let secondary = NSColor(calibratedWhite: 0.68, alpha: 1)
    static let divider = NSColor(calibratedWhite: 1, alpha: 0.10)
    static func font(_ size: CGFloat) -> NSFont {
        NSFont(name: "SFMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

@MainActor
final class ChromeWindowDrag {
    private var downPoint: NSPoint?
    private var originalOrigin: NSPoint?
    private(set) var didMove = false
    func begin(_ event: NSEvent, in window: NSWindow?) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        downPoint = window.convertPoint(toScreen: event.locationInWindow)
        originalOrigin = window.frame.origin
        didMove = false
    }
    func update(_ event: NSEvent, in window: NSWindow?) {
        guard let window, let downPoint, let originalOrigin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let dx = point.x - downPoint.x, dy = point.y - downPoint.y
        guard didMove || hypot(dx, dy) >= 3 else { return }
        didMove = true
        window.setFrameOrigin(NSPoint(x: originalOrigin.x + dx, y: originalOrigin.y + dy))
    }
    func end() { downPoint = nil; originalOrigin = nil; didMove = false }
}

final class HeaderView: NSView {
    private let drag = ChromeWindowDrag()
    var leadingIsInactive = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
        else { drag.begin(event, in: window) }
    }
    override func mouseDragged(with event: NSEvent) { drag.update(event, in: window) }
    override func mouseUp(with event: NSEvent) { drag.end() }
    override func draw(_ dirtyRect: NSRect) {
        if leadingIsInactive {
            NSColor.black.withAlphaComponent(0.20).setFill()
            NSRect(x: 0, y: 0, width: 80, height: bounds.height).fill()
        }
    }
}

/// A click remains a button click; a drag anywhere on its label moves the window.
class DraggableChromeButton: NSButton {
    private let drag = ChromeWindowDrag()
    private var isPressed = false
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        drag.begin(event, in: window)
        highlight(true)
    }
    override func mouseDragged(with event: NSEvent) {
        drag.update(event, in: window)
        if drag.didMove { highlight(false) }
    }
    override func mouseUp(with event: NSEvent) {
        highlight(false)
        let clicked = isPressed && !drag.didMove
        isPressed = false
        drag.end()
        if clicked, bounds.contains(convert(event.locationInWindow, from: nil)), let action {
            sendAction(action, to: target)
        }
    }
}

final class TabSelectButton: DraggableChromeButton {
    var onRightClick: ((NSEvent) -> Void)?
    override func draw(_ dirtyRect: NSRect) { /* Chrome is drawn once by the parent. */ }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
}

final class TabButton: NSView {
    let noteID: UUID
    var title = ""
    var active = false
    var number = 1
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onRename: ((UUID) -> Void)?
    private let closeButton = NSButton()
    private let selectButton = TabSelectButton()
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(record: NoteRecord, number: Int, active: Bool) {
        noteID = record.id
        self.number = number
        self.active = active
        super.init(frame: .zero)
        title = record.displayTitle
        selectButton.isBordered = false
        selectButton.setButtonType(.momentaryChange)
        selectButton.target = self
        selectButton.action = #selector(selectTab)
        selectButton.onRightClick = { [weak self] event in self?.rightMouseDown(with: event) }
        toolTip = record.filePath ?? record.displayTitle
        selectButton.setAccessibilityLabel("\(title), tab \(number)\(active ? ", selected" : "")")
        selectButton.setAccessibilityRole(.radioButton)
        selectButton.setAccessibilityValue(active ? 1 : 0)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Archive tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.secondary
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close and archive tab"
        closeButton.setAccessibilityLabel("Close and archive \(title)")
        addSubview(selectButton)
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func layout() {
        super.layout()
        selectButton.frame = bounds
        closeButton.frame = NSRect(x: bounds.width - 27, y: (bounds.height - 20) / 2, width: 20, height: 20)
        closeButton.alphaValue = hovering ? 1 : 0.5
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; needsLayout = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(active ? 0 : hovering ? 0.14 : 0.20).setFill()
        bounds.fill()
        Theme.divider.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .regular),
            .foregroundColor: active ? Theme.text : Theme.secondary, .paragraphStyle: paragraph
        ]
        (title as NSString).draw(in: NSRect(x: 10, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 68), height: 17), withAttributes: attributes)
        if number <= 9 {
            ("⌘\(number)" as NSString).draw(in: NSRect(x: bounds.width - 55, y: (bounds.height - 13) / 2, width: 25, height: 14),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: Theme.secondary])
        }
    }
    @objc private func selectTab() { onSelect?(noteID) }
    @objc private func closeTab() { onClose?(noteID) }
    @objc private func renameTab() { onRename?(noteID) }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let rename = menu.addItem(withTitle: "Rename Tab…", action: #selector(renameTab), keyEquivalent: "")
        rename.target = self
        let close = menu.addItem(withTitle: "Close and Archive Tab", action: #selector(closeTab), keyEquivalent: "")
        close.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class EditorPane {
    let scroll: NSScrollView
    let textView: NSTextView
    let lineNumbers: LineNumberRuler
    let undo = UndoManager()
    var dirty = false
    private var brightness: Double = 0.93

    init(text: String, fontSize: CGFloat, record: NoteRecord) {
        scroll = NSScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.clipsToBounds = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.contentView.automaticallyAdjustsContentInsets = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // A separate text system per open tab preserves its own selection and undo history.
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        lineNumbers = LineNumberRuler(scrollView: scroll, textView: textView)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = Theme.text
        textView.insertionPointColor = Theme.text
        textView.selectedTextAttributes = [.backgroundColor: NSColor(calibratedRed: 0.29, green: 0.43, blue: 0.61, alpha: 0.75)]
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.setAccessibilityLabel("Note text")
        textView.string = text
        applyFont(size: fontSize)
        let location = min(record.selectionLocation, (text as NSString).length)
        let length = min(record.selectionLength, (text as NSString).length - location)
        textView.setSelectedRange(NSRange(location: max(0, location), length: max(0, length)))
        scroll.documentView = textView
        scroll.verticalRulerView = lineNumbers
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        lineNumbers.refreshMetrics()
        lineNumbers.onThicknessChange = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.layoutEditor() }
        }
    }
    func layoutEditor() {
        scroll.tile()
        // Overlay-style rulers reserve NSClipView insets rather than shrinking its frame.
        let insets = scroll.contentView.contentInsets
        let width = max(0, scroll.contentSize.width - insets.left - insets.right)
        textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, scroll.contentSize.height)))
        scroll.contentView.scroll(to: NSPoint(x: -insets.left, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func applyFont(size: CGFloat) {
        textView.font = Theme.font(size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.defaultTabInterval = Theme.font(size).maximumAdvancement.width * 4
        paragraph.tabStops = []
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: Theme.font(size), .foregroundColor: textView.textColor ?? Theme.text, .paragraphStyle: paragraph]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        }
        lineNumbers.refreshMetrics()
        if scroll.documentView != nil { layoutEditor() }
    }
    func applyAppearance(brightness: Double, showsLineNumbers: Bool) {
        if self.brightness != brightness {
            self.brightness = brightness
            let color = NSColor(calibratedWhite: CGFloat(brightness), alpha: 1)
            textView.textColor = color
            textView.insertionPointColor = color
            var typing = textView.typingAttributes
            typing[.foregroundColor] = color
            textView.typingAttributes = typing
        }
        if scroll.rulersVisible != showsLineNumbers {
            scroll.hasVerticalRuler = showsLineNumbers
            scroll.rulersVisible = showsLineNumbers
            layoutEditor()
        }
    }
}
