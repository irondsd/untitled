import AppKit

final class FindPanel: NSView {
    let findField = NSTextField()
    let replaceField = NSTextField()
    let findButton = NSButton(title: "Find", target: nil, action: nil)
    let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    let regexButton = NSButton(title: ".*", target: nil, action: nil)
    let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    let allButton = NSButton(title: "All", target: nil, action: nil)
    let closeButton = NSButton()
    let status = NSTextField(labelWithString: "")
    private let findLabel = NSTextField(labelWithString: "Find")
    private let replaceLabel = NSTextField(labelWithString: "Replace")
    var onClose: (() -> Void)?
    static let height: CGFloat = 108
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        for label in [findLabel, replaceLabel, status] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.secondary
            addSubview(label)
        }
        status.lineBreakMode = .byTruncatingTail
        for (field, label) in [(findField, "Find text"), (replaceField, "Replacement text")] {
            field.font = Theme.font(12)
            field.isAutomaticTextCompletionEnabled = false
            field.cell?.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.setAccessibilityLabel(label)
            addSubview(field)
        }
        findField.placeholderString = "Find in current note"
        replaceField.placeholderString = "Replace with"
        for button in [findButton, replaceButton, regexButton, caseButton, allButton] {
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            addSubview(button)
        }
        for (button, label, help) in [
            (regexButton, "Regular expression", "Use regular expressions. Capture groups: (text); replacement: $1, $2. Supports \\n and \\t."),
            (caseButton, "Case sensitive", "Match uppercase and lowercase exactly. Off ignores case."),
            (allButton, "All matches", "Find selects all matches; Replace replaces all matches in the current note.")
        ] {
            button.setButtonType(.pushOnPushOff)
            button.setAccessibilityLabel(label)
            button.toolTip = help
        }
        regexButton.font = Theme.font(12)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close find panel")
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.secondary
        closeButton.toolTip = "Close find panel (Esc)"
        closeButton.setAccessibilityLabel("Close find panel")
        addSubview(closeButton)
        findButton.toolTip = "Find next (Return); find previous (Shift-Return). ⌘G / ⇧⌘G also navigate."
        replaceButton.toolTip = "Replace the selected match, then find the next. All replaces every match in this note."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
    override func layout() {
        super.layout()
        let actionX = bounds.width - 230
        findLabel.frame = NSRect(x: 12, y: 17, width: 50, height: 16)
        replaceLabel.frame = NSRect(x: 12, y: 51, width: 50, height: 16)
        findField.frame = NSRect(x: 68, y: 11, width: max(40, actionX - 76), height: 26)
        replaceField.frame = NSRect(x: 68, y: 45, width: max(40, actionX - 76), height: 26)
        findButton.frame = NSRect(x: actionX, y: 11, width: 94, height: 26)
        replaceButton.frame = NSRect(x: actionX, y: 45, width: 94, height: 26)
        for (index, button) in [regexButton, caseButton, allButton].enumerated() {
            button.frame = NSRect(x: bounds.width - 126 + CGFloat(index) * 38, y: 11, width: 36, height: 26)
        }
        status.frame = NSRect(x: 68, y: 82, width: max(0, bounds.width - 108), height: 16)
        closeButton.frame = NSRect(x: bounds.width - 30, y: 78, width: 22, height: 22)
    }
}

@MainActor
final class FindController: NSObject, NSTextFieldDelegate {
    let panel = FindPanel()
    private weak var editor: EditorTextView?
    private let queue = DispatchQueue(label: "local.untitled.find", qos: .userInitiated)
    private var searchWork: DispatchWorkItem?
    private var cancellation: FindCancellation?
    private var revision = 0
    private(set) var results: FindResults?
    private(set) var isSearching = false
    private var isReplacing = false
    private var currentIndex: Int?
    private var pendingNavigation: Bool?
    private var replacementOwnsUndo = false
    var panelUndoManager: UndoManager? {
        guard isVisible, replacementOwnsUndo,
              panel.findField.currentEditor() != nil || panel.replaceField.currentEditor() != nil else { return nil }
        return editor?.undoManager
    }
    var onVisibilityChange: (() -> Void)?
    var isVisible: Bool { !panel.isHidden }
    var query: FindQuery {
        FindQuery(text: panel.findField.stringValue, regex: panel.regexButton.state == .on,
                  caseSensitive: panel.caseButton.state == .on)
    }

    override init() {
        super.init()
        panel.isHidden = true
        panel.findField.delegate = self
        panel.replaceField.delegate = self
        for button in [panel.regexButton, panel.caseButton, panel.allButton] {
            button.target = self
            button.action = #selector(optionsChanged)
        }
        panel.findButton.target = self
        panel.findButton.action = #selector(find)
        panel.replaceButton.target = self
        panel.replaceButton.action = #selector(replace)
        panel.closeButton.target = self
        panel.closeButton.action = #selector(close)
        panel.onClose = { [weak self] in self?.close() }
    }

    func bind(_ textView: NSTextView) {
        replacementOwnsUndo = false
        clearHighlights()
        editor?.onCancelFind = nil
        editor = textView as? EditorTextView
        editor?.onCancelFind = { [weak self] in
            guard let self, self.isVisible else { return false }
            self.close()
            return true
        }
        refresh()
    }

    func show(focusReplacement: Bool = false) {
        guard let editor else { return }
        if !isVisible {
            let selection = editor.selectedRange()
            if selection.length > 0 {
                let selected = (editor.string as NSString).substring(with: selection)
                panel.findField.stringValue = query.regex ? NSRegularExpression.escapedPattern(for: selected) : selected
            }
        }
        panel.isHidden = false
        onVisibilityChange?()
        refresh()
        let field = focusReplacement ? panel.replaceField : panel.findField
        panel.window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    @objc func close(_ sender: Any? = nil) {
        replacementOwnsUndo = false
        panel.isHidden = true
        searchWork?.cancel()
        cancellation?.cancel()
        revision += 1
        isSearching = false
        results = nil
        clearHighlights()
        onVisibilityChange?()
        panel.window?.makeFirstResponder(editor)
    }

    func documentDidChange() {
        guard !isReplacing else { return }
        refresh()
    }
    func selectionDidChange() {
        guard !isReplacing, let results, let editor else { return }
        currentIndex = results.matches.firstIndex { $0.range == editor.selectedRange() }
        updateStatus()
    }
    func controlTextDidChange(_ notification: Notification) {
        replacementOwnsUndo = false
        if notification.object as? NSTextField === panel.findField { refresh() }
        else { updateStatus() }
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let editor = field.currentEditor() as? NSTextView else { return }
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        if commandSelector == #selector(NSResponder.insertTab(_:)), control === panel.findField {
            panel.replaceField.selectText(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)), control === panel.replaceField {
            panel.findField.selectText(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === panel.findField {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { navigate(backwards: true) }
                else { find() }
            } else { replace() }
            return true
        }
        return false
    }
    @objc func optionsChanged(_ sender: Any? = nil) {
        panel.findButton.title = panel.allButton.state == .on ? "Find All" : "Find"
        panel.replaceButton.title = panel.allButton.state == .on ? "Replace All" : "Replace"
        panel.replaceField.placeholderString = query.regex ? "Replace with · $1, $2…" : "Replace with"
        refresh()
    }

    func refresh(afterReplacement: (location: Int, skipEmpty: Bool)? = nil) {
        searchWork?.cancel()
        cancellation?.cancel()
        nextAfterReplacement = afterReplacement
        pendingNavigation = nil
        revision += 1
        results = nil
        currentIndex = nil
        clearHighlights()
        guard isVisible, let editor else { isSearching = false; return }
        let source = editor.string, query = self.query, version = revision
        guard !query.text.isEmpty else { isSearching = false; updateStatus(); return }
        isSearching = true
        updateStatus()
        let token = FindCancellation()
        cancellation = token
        let work = DispatchWorkItem { [weak self, weak editor] in
            let result = Result { try FindResults(source: source, query: query, cancelled: { token.isCancelled }) }
            guard !token.isCancelled else { return }
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, self.revision == version, self.editor === editor, self.isVisible else { return }
                self.isSearching = false
                switch result {
                case .success(let found):
                    self.results = found
                    self.highlightMatches()
                    self.selectionDidChange()
                    self.selectAfterReplacement()
                    if let backwards = self.pendingNavigation {
                        self.pendingNavigation = nil
                        self.navigate(backwards: backwards)
                    }
                case .failure(let error):
                    self.setStatus("Invalid regex: \(error.localizedDescription)", error: true)
                    self.panel.findButton.isEnabled = false
                    self.panel.replaceButton.isEnabled = false
                }
            }
        }
        searchWork = work
        queue.async(execute: work)
    }

    private func clearHighlights() {
        guard let editor else { return }
        editor.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.zeroWidthFindLocations = []
    }
    private func highlightMatches() {
        guard let editor, let results else { return }
        let color = NSColor.systemYellow.withAlphaComponent(0.28)
        for match in results.matches where match.range.length > 0 {
            editor.layoutManager?.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: match.range)
        }
        editor.zeroWidthFindLocations = results.matches.filter { $0.range.length == 0 }.map { $0.range.location }
    }
    private func setStatus(_ message: String, error: Bool = false) {
        panel.status.stringValue = message
        panel.status.textColor = error ? .systemOrange : Theme.secondary
        panel.status.toolTip = message
        panel.status.setAccessibilityLabel(message)
    }
    private func updateStatus() {
        panel.findButton.isEnabled = results?.matches.isEmpty == false && !isSearching
        panel.replaceButton.isEnabled = panel.findButton.isEnabled
        if isSearching { setStatus("Searching current note…"); return }
        guard let results else {
            setStatus(query.text.isEmpty ? "Current note · Return: find next · Shift-Return: previous · Esc: close" : panel.status.stringValue)
            return
        }
        do { _ = try results.edits(replacement: panel.replaceField.stringValue, indexes: []) }
        catch {
            panel.replaceButton.isEnabled = false
            setStatus("Replacement: \(error.localizedDescription)", error: true)
            return
        }
        let count = results.matches.count
        let countText = count == 0 ? "No matches" : currentIndex.map { "\($0 + 1) of \(count) matches" } ?? "\(count) \(count == 1 ? "match" : "matches")"
        setStatus("\(countText) · Current note")
    }

    @objc func find(_ sender: Any? = nil) {
        guard panel.allButton.state == .on else { navigate(); return }
        guard let editor, let results, !results.matches.isEmpty, !isSearching else { return }
        editor.setEditingSelectedRanges(results.matches.map { NSValue(range: $0.range) })
        editor.scrollRangeToVisible(results.matches[0].range)
        setStatus("\(results.matches.count) matches selected · Current note")
    }

    func navigate(backwards: Bool = false) {
        if !isVisible { show() }
        if isSearching { pendingNavigation = backwards; return }
        guard let editor, let results, !results.matches.isEmpty, !isSearching else { return }
        let selection = editor.selectedRange()
        let exact = results.matches.firstIndex { $0.range == selection }
        let index: Int
        if let exact { index = (exact + (backwards ? -1 : 1) + results.matches.count) % results.matches.count }
        else if backwards { index = results.matches.lastIndex { $0.range.location < selection.location } ?? results.matches.count - 1 }
        else { index = results.matches.firstIndex { $0.range.location >= NSMaxRange(selection) } ?? 0 }
        select(index)
    }

    private func select(_ index: Int) {
        guard let editor, let results else { return }
        currentIndex = index
        let range = results.matches[index].range
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
        updateStatus()
    }

    @objc func replace(_ sender: Any? = nil) {
        guard let editor, let results, !results.matches.isEmpty, !isSearching,
              results.source == editor.string, results.query == query else { return }
        let all = panel.allButton.state == .on
        let indexes: [Int]
        if all { indexes = Array(results.matches.indices) }
        else if let index = results.matches.firstIndex(where: { $0.range == editor.selectedRange() }) { indexes = [index] }
        else { navigate(); return }
        do {
            let edits = try results.edits(replacement: panel.replaceField.stringValue, indexes: indexes)
            let ranges = edits.map { NSValue(range: $0.range) }
            editor.breakUndoCoalescing()
            guard editor.shouldChangeText(inRanges: ranges, replacementStrings: edits.map(\.replacement)), let storage = editor.textStorage else { return }
            // NSTextView registers undo through shouldChangeText; a single notification keeps
            // autosave, the incremental line index, and live search in the normal editing path.
            isReplacing = true
            storage.beginEditing()
            for edit in edits.reversed() { storage.replaceCharacters(in: edit.range, with: edit.replacement) }
            storage.endEditing()
            editor.didChangeText()
            editor.undoManager?.setActionName(all ? "Replace All" : "Replace")
            editor.breakUndoCoalescing()
            replacementOwnsUndo = true
            let first = edits[0]
            let caret = first.range.location + (first.replacement as NSString).length
            editor.setSelectedRange(NSRange(location: caret, length: 0))
            isReplacing = false
            refresh(afterReplacement: all ? nil : (caret, first.range.length == 0 && first.replacement.isEmpty))
        } catch { setStatus("Replacement: \(error.localizedDescription)", error: true) }
    }

    private var nextAfterReplacement: (location: Int, skipEmpty: Bool)?
    private func selectAfterReplacement() {
        guard let pending = nextAfterReplacement, let results, !results.matches.isEmpty else { nextAfterReplacement = nil; return }
        nextAfterReplacement = nil
        let index = results.matches.firstIndex {
            pending.skipEmpty ? $0.range.location > pending.location : $0.range.location >= pending.location
        } ?? 0
        select(index)
    }
}
