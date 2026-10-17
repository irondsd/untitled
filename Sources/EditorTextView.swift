import AppKit
import CoreGraphics

final class EditorTextView: NSTextView {
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
        super.paste(sender)
    }
    override func pasteAsPlainText(_ sender: Any?) {
        guard !pasteRepeatHasEnded else { return }
        super.pasteAsPlainText(sender)
    }
}
