import AppKit
import CoreGraphics

/// Lays out Markdown table rows without wrapping, shifted by their table's horizontal scroll.
final class EditorTextContainer: NSTextContainer {
    /// The horizontal scroll of the table containing a character, or nil outside tables.
    var tableOffset: ((Int) -> CGFloat?)?
    static let tableLineWidth: CGFloat = 1_000_000

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        if let offset = tableOffset?(characterIndex) {
            remainingRect?.pointee = .zero
            return NSRect(x: proposedRect.minX - offset, y: proposedRect.minY, width: Self.tableLineWidth, height: proposedRect.height)
        }
        return super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                      writingDirection: baseWritingDirection, remaining: remainingRect)
    }
}

final class EditorTextView: NSTextView {
    /// Handles a scroll event itself, such as a sideways swipe over a wide table.
    var onScrollWheel: ((NSEvent) -> Bool)?
    /// Areas where nothing may draw, such as the margins beside a scrolled table.
    var drawingExclusions: ((NSRect) -> [NSRect])?
    var onCancelFind: (() -> Bool)?
    var onCancelOccurrences: (() -> Bool)?
    /// Draws behind the text, such as code block backgrounds; the editor itself draws no background.
    var onDrawBackground: ((NSRect) -> Void)?
    var zeroWidthFindLocations: [Int] = [] { didSet { needsDisplay = true } }
    /// The link under a point in view coordinates. Hovering underlines it; Command-click opens it.
    var linkAt: ((NSPoint) -> (range: NSRange, url: URL)?)?
    private var hoveredLink: NSRange?
    private var showsLinkCursor = false
    private var linkTracking: NSTrackingArea?
    private var multipleSelections: [NSValue]? { didSet { needsDisplay = true } }
    private var nativeMultipleSelection: [NSValue] = []
    private(set) var isSettingEditingSelections = false
    var editingSelectedRanges: [NSValue] {
        validateMultipleSelections()
        return multipleSelections ?? selectedRanges
    }
    func setEditingSelectedRanges(_ ranges: [NSValue]) {
        isSettingEditingSelections = true
        multipleSelections = nil
        if ranges.count > 1 {
            if ranges.allSatisfy({ $0.rangeValue.length == 0 }) { setSelectedRange(ranges[0].rangeValue) }
            else { selectedRanges = ranges }
            nativeMultipleSelection = selectedRanges
            multipleSelections = ranges
        } else { selectedRanges = ranges }
        isSettingEditingSelections = false
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: self)
    }

    override func keyDown(with event: NSEvent) {
        validateMultipleSelections()
        if [UInt16(123), 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode) { multipleSelections = nil }
        super.keyDown(with: event)
        validateMultipleSelections()
    }

    // MARK: Duplicate lines

    @objc func duplicateLineUp(_ sender: Any?) { duplicateLines(down: false) }
    @objc func duplicateLineDown(_ sender: Any?) { duplicateLines(down: true) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(duplicateLineUp(_:)) || item.action == #selector(duplicateLineDown(_:)) { return isEditable }
        return super.validateUserInterfaceItem(item)
    }

    /// Copies the logical lines touched by the selection above or below them. Going down, the
    /// selection follows the new copy; going up, it stays put, now on the upper copy.
    private func duplicateLines(down: Bool) {
        guard isEditable, let storage = textStorage else { return }
        let text = storage.string as NSString
        var selection = selectedRange()
        multipleSelections = nil
        // A selection ending right after a newline does not reach into the next line.
        var span = selection
        if span.length > 0, text.character(at: NSMaxRange(span) - 1) == 0x0A { span.length -= 1 }
        let lines = text.lineRange(for: span)
        var block = text.substring(with: lines)
        if !block.hasSuffix("\n") { block = down ? "\n" + block : block + "\n" }
        let location = down ? NSMaxRange(lines) : lines.location
        let insertion = NSRange(location: location, length: 0)
        // Keep surrounding typing as separate undo steps.
        breakUndoCoalescing()
        guard shouldChangeText(in: insertion, replacementString: block) else { return }
        storage.replaceCharacters(in: insertion, with: block)
        didChangeText()
        undoManager?.setActionName(down ? "Duplicate Line Down" : "Duplicate Line Up")
        if down { selection.location += (block as NSString).length }
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.clickCount == 1,
           let link = linkAt?(convert(event.locationInWindow, from: nil)) {
            NSWorkspace.shared.open(link.url)
            return
        }
        multipleSelections = nil
        super.mouseDown(with: event)
    }

    // MARK: Links

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTracking { removeTrackingArea(linkTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        linkTracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredLink(nil, command: false)
    }
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        refreshHoveredLink()
    }

    /// Re-checks the pointer, such as after a modifier change or an analysis that moved links.
    func refreshHoveredLink() {
        guard let window else { return }
        hover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), modifiers: NSEvent.modifierFlags)
    }
    private func hover(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        let link = visibleRect.contains(point) ? linkAt?(point) : nil
        setHoveredLink(link?.range, command: modifiers.intersection(.deviceIndependentFlagsMask) == .command)
    }

    /// The underline is a temporary attribute, so it never reaches the note, clipboard or undo stack.
    private func setHoveredLink(_ range: NSRange?, command: Bool) {
        if range != hoveredLink, let manager = layoutManager, let length = textStorage?.length {
            // Edits shift temporary ranges, so clear the whole note rather than the remembered range.
            manager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: length))
            if let range { manager.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: range) }
            hoveredLink = range
        }
        let pointer = range != nil && command
        // The I-beam comes back only when this view put up the hand, never over other views' cursors.
        if pointer { NSCursor.pointingHand.set() } else if showsLinkCursor { NSCursor.iBeam.set() }
        showsLinkCursor = pointer
    }

    private func validateMultipleSelections() {
        guard multipleSelections != nil else { return }
        guard undoManager?.isUndoing != true, undoManager?.isRedoing != true,
              selectedRanges == nativeMultipleSelection else { multipleSelections = nil; return }
        // AppKit merges adjacent ranges and retains only one empty caret. Keep
        // their logical boundaries separately until the native selection changes.
    }

    override func cancelOperation(_ sender: Any?) {
        validateMultipleSelections()
        if onCancelFind?() == true { return }
        if onCancelOccurrences?() == true { return }
        if let first = multipleSelections?.first { setEditingSelectedRanges([first]); return }
        super.cancelOperation(sender)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        validateMultipleSelections()
        if editingSelectedRanges.count > 1, !hasMarkedText(), undoManager?.isUndoing != true, undoManager?.isRedoing != true,
           replacementRange.location == NSNotFound || replacementRange == selectedRange(),
           let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string {
            replaceSelections(with: text)
        } else { super.insertText(insertString, replacementRange: replacementRange) }
    }

    override func deleteBackward(_ sender: Any?) {
        validateMultipleSelections()
        guard editingSelectedRanges.count > 1 else { super.deleteBackward(sender); return }
        let source = string as NSString
        replaceSelections(with: "", ranges: editingSelectedRanges.map {
            let range = $0.rangeValue
            return range.length == 0 && range.location > 0
                ? source.rangeOfComposedCharacterSequence(at: range.location - 1) : range
        })
    }

    override func deleteForward(_ sender: Any?) {
        validateMultipleSelections()
        guard editingSelectedRanges.count > 1 else { super.deleteForward(sender); return }
        let source = string as NSString
        replaceSelections(with: "", ranges: editingSelectedRanges.map {
            let range = $0.rangeValue
            return range.length == 0 && range.location < source.length
                ? source.rangeOfComposedCharacterSequence(at: range.location) : range
        })
    }

    override func cut(_ sender: Any?) {
        validateMultipleSelections()
        guard editingSelectedRanges.count > 1 else { super.cut(sender); return }
        guard editingSelectedRanges.contains(where: { $0.rangeValue.length > 0 }) else { return }
        copy(sender)
        replaceSelections(with: "")
    }

    /// AppKit exposes multiple selection ranges, but typing normally replaces only
    /// the primary range. Keep all edits in its native validation/undo/save path.
    private func replaceSelections(with text: String, ranges proposed: [NSRange]? = nil) {
        guard isEditable else { return }
        let sorted = (proposed ?? editingSelectedRanges.map(\.rangeValue)).sorted { $0.location < $1.location }
        var ranges: [NSRange] = []
        for range in sorted {
            if let last = ranges.last, NSMaxRange(last) > range.location || last == range {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else { ranges.append(range) }
        }
        guard let first = ranges.first, let last = ranges.last else { return }
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let replacement = NSMutableString(string: (string as NSString).substring(with: span))
        for range in ranges.reversed() {
            replacement.replaceCharacters(in: NSRange(location: range.location - span.location, length: range.length), with: text)
        }
        breakUndoCoalescing()
        // Submit one bounded replacement to NSTextView so native typing undo is
        // registered normally, including the untouched text between selections.
        super.insertText(replacement as String, replacementRange: span)
        var delta = 0
        let length = (text as NSString).length
        var carets: [NSValue] = []
        for range in ranges {
            let caret = NSRange(location: range.location + delta + length, length: 0)
            if carets.last?.rangeValue != caret { carets.append(NSValue(range: caret)) }
            delta += length - range.length
        }
        setEditingSelectedRanges(carets)
        breakUndoCoalescing()
    }

    /// A scrolled table lays its rows out left of the container. AppKit would move the whole
    /// text to keep them in view, so pin the origin to the inset.
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: textContainerInset.height) }

    override func scrollWheel(with event: NSEvent) {
        if onScrollWheel?(event) == true { return }
        super.scrollWheel(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let exclusions = drawingExclusions?(dirtyRect) ?? []
        if !exclusions.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: bounds)
            for rect in exclusions { clip.appendRect(rect) }
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        onDrawBackground?(dirtyRect)
        super.draw(dirtyRect)
        if !exclusions.isEmpty { NSGraphicsContext.restoreGraphicsState() }
        let carets = editingSelectedRanges
        let extra = multipleSelections != nil && window?.firstResponder === self && window?.isKeyWindow == true
            ? carets.dropFirst().filter { $0.rangeValue.length == 0 }.map { $0.rangeValue.location } : []
        guard !zeroWidthFindLocations.isEmpty || !extra.isEmpty,
              let window, let manager = layoutManager, let container = textContainer else { return }
        let glyphs = manager.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: container)
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Empty matches have no characters to tint; mark their insertion positions instead.
        for (locations, color, width) in [(zeroWidthFindLocations, NSColor.systemYellow, CGFloat(2)), (extra, insertionPointColor ?? Theme.text, CGFloat(1))] {
            color.setFill()
            for location in locations where location >= visible.location && location <= NSMaxRange(visible) {
                let screen = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
                let rect = convert(window.convertFromScreen(screen), from: nil)
                NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height).fill()
            }
        }
    }

    /// A queued repeat describes when it was generated, not which keys are still held.
    /// Check live state only for repeats: a quick, completed key press must still paste once.
    static func discardsPasteRepeat(_ event: NSEvent?,
                                    modifiers: NSEvent.ModifierFlags,
                                    keyIsDown: (CGKeyCode) -> Bool) -> Bool {
        guard let event, event.type == .keyDown, event.isARepeat,
              event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "v" else { return false }
        return !modifiers.contains(.command) || !keyIsDown(event.keyCode)
    }

    private var pasteRepeatHasEnded: Bool {
        Self.discardsPasteRepeat(NSApp.currentEvent, modifiers: NSEvent.modifierFlags) {
            CGEventSource.keyState(.combinedSessionState, key: $0)
        }
    }
    override func paste(_ sender: Any?) {
        guard !pasteRepeatHasEnded else { return }
        validateMultipleSelections()
        if editingSelectedRanges.count > 1, let text = NSPasteboard.general.string(forType: .string) { replaceSelections(with: text) }
        else { super.paste(sender) }
    }
    override func pasteAsPlainText(_ sender: Any?) {
        guard !pasteRepeatHasEnded else { return }
        validateMultipleSelections()
        if editingSelectedRanges.count > 1, let text = NSPasteboard.general.string(forType: .string) { replaceSelections(with: text) }
        else { super.pasteAsPlainText(sender) }
    }
}
