import AppKit

/// Selection matching shares Find's engine, but never changes its query or options.
@MainActor
final class OccurrenceController {
    private weak var editor: EditorTextView?
    private let queue = DispatchQueue(label: "local.untitled.occurrences", qos: .userInitiated)
    private var work: DispatchWorkItem?
    private var cancellation: FindCancellation?
    private var revision = 0
    private var needle: String?
    private var lastAdded: NSRange?
    private var lastSelections: [NSRange] = []
    private var addingSelection = false
    private var pendingAdditions = 0
    private var pendingSelectAll = false
    private var suspended = false
    private(set) var matches: SelectionMatches?
    private(set) var isSearching = false

    func bind(_ textView: NSTextView) {
        clear()
        editor?.onCancelOccurrences = nil
        editor = textView as? EditorTextView
        editor?.onCancelOccurrences = { [weak self] in self?.collapseSelections() ?? false }
        selectionDidChange()
    }

    func setSuspended(_ value: Bool) {
        suspended = value
        clear()
        if !value { selectionDidChange() }
    }

    func documentDidChange() {
        clear()
        selectionDidChange()
    }

    func selectionDidChange() {
        guard !suspended, let editor else { return }
        let selections = editor.editingSelectedRanges.map(\.rangeValue)
        let source = editor.string as NSString
        guard let first = selections.first, first.length > 0, NSMaxRange(first) <= source.length else { clear(); return }
        let text = source.substring(with: first)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selections.allSatisfy({ $0.length > 0 && NSMaxRange($0) <= source.length && source.substring(with: $0) == text }) else { clear(); return }
        if !addingSelection && selections != lastSelections { lastAdded = selections.last }
        lastSelections = selections
        guard text != needle else { return }
        clear()
        needle = text
        lastAdded = selections.last
        lastSelections = selections
        let version = revision, snapshot = editor.string
        let token = FindCancellation()
        cancellation = token
        isSearching = true
        let task = DispatchWorkItem { [weak self, weak editor] in
            let found = try? SelectionMatches(source: snapshot, text: text, cancelled: { token.isCancelled })
            guard !token.isCancelled else { return }
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, self.revision == version, self.editor === editor, !self.suspended else { return }
                self.isSearching = false
                self.matches = found
                if let editor, let found, found.ranges.count > 1 {
                    let color = NSColor.systemYellow.withAlphaComponent(0.20)
                    for range in found.ranges {
                        editor.layoutManager?.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
                    }
                }
                let count = self.pendingAdditions
                self.pendingAdditions = 0
                let selectAll = self.pendingSelectAll
                self.pendingSelectAll = false
                if selectAll { self.selectEveryMatch() }
                for _ in 0..<count { self.addNextSelection() }
            }
        }
        work = task
        queue.async(execute: task)
    }

    func selectNext() {
        guard !suspended, let editor else { return }
        if editor.selectedRange().length == 0 {
            let range = editor.selectionRange(forProposedRange: editor.selectedRange(), granularity: .selectByWord)
            let source = editor.string as NSString
            guard range.length > 0, NSMaxRange(range) <= source.length,
                  !source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            editor.setSelectedRange(range)
            selectionDidChange()
            return
        }
        selectionDidChange()
        if isSearching { pendingAdditions += 1 }
        else { addNextSelection() }
    }

    private func addNextSelection() {
        guard let editor, let matches else { return }
        let selected = editor.editingSelectedRanges.map(\.rangeValue)
        guard let anchor = lastAdded ?? selected.last,
              let next = matches.next(after: anchor, excluding: selected) else { return }
        addingSelection = true
        lastAdded = next
        editor.setEditingSelectedRanges((selected + [next]).sorted { $0.location < $1.location }.map { NSValue(range: $0) })
        editor.scrollRangeToVisible(next)
        addingSelection = false
    }

    func selectAll() {
        guard !suspended, let editor else { return }
        if editor.selectedRange().length == 0 { selectNext() }
        guard editor.selectedRange().length > 0 else { return }
        selectionDidChange()
        if isSearching {
            pendingSelectAll = true
            pendingAdditions = 0
        } else { selectEveryMatch() }
    }

    private func selectEveryMatch() {
        guard let editor, let matches else { return }
        let selected = editor.editingSelectedRanges.map(\.rangeValue)
        let ranges = matches.all(including: selected)
        guard !ranges.isEmpty else { return }
        addingSelection = true
        editor.setEditingSelectedRanges(ranges.map { NSValue(range: $0) })
        addingSelection = false
    }

    private func collapseSelections() -> Bool {
        guard let editor, editor.editingSelectedRanges.count > 1 else { return false }
        let range = lastAdded ?? editor.selectedRange()
        editor.setEditingSelectedRanges([NSValue(range: range)])
        return true
    }

    private func clear() {
        work?.cancel()
        cancellation?.cancel()
        revision += 1
        pendingAdditions = 0
        pendingSelectAll = false
        isSearching = false
        matches = nil
        needle = nil
        lastAdded = nil
        lastSelections = []
        // Find owns temporary backgrounds while it is open. Never remove its highlights.
        if !suspended, let editor {
            editor.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
    }
}
