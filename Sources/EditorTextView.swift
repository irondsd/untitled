import AppKit
import CoreGraphics

final class EditorTextView: NSTextView {
    var onCancelFind: (() -> Bool)?
    var onCancelOccurrences: (() -> Bool)?
    var zeroWidthFindLocations: [Int] = [] { didSet { needsDisplay = true } }
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

    override func mouseDown(with event: NSEvent) {
        multipleSelections = nil
        super.mouseDown(with: event)
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
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
