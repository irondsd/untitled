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

final class HeaderView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
        else { window?.performDrag(with: event) }
    }
}

final class TabSelectButton: NSButton {
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
        NSColor(calibratedWhite: 1, alpha: active ? 0.08 : hovering ? 0.035 : 0).setFill()
        bounds.fill()
        Theme.divider.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        if active {
            NSColor(calibratedWhite: 1, alpha: 0.25).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
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
    let undo = UndoManager()
    var dirty = false

    init(text: String, fontSize: CGFloat, record: NoteRecord) {
        scroll = NSScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // A separate text system per open tab preserves its own selection and undo history.
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
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
    }
    func applyFont(size: CGFloat) {
        textView.font = Theme.font(size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.defaultTabInterval = Theme.font(size).maximumAdvancement.width * 4
        paragraph.tabStops = []
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: Theme.font(size), .foregroundColor: Theme.text, .paragraphStyle: paragraph]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        }
    }
}
