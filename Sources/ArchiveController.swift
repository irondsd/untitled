import AppKit

final class ArchiveWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

final class ArchiveRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 3), xRadius: 5, yRadius: 5).fill()
    }
}

final class ArchiveCell: NSTableCellView {
    var noteID: UUID?
    var onDelete: ((UUID) -> Void)?
    @objc func deleteNote(_ sender: Any?) { if let noteID { onDelete?(noteID) } }
}

@MainActor
final class ArchiveController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: NotesStore
    private let allNotes: Bool
    private let onRestore: (UUID) -> Void
    private let onError: (Error) -> Void
    private let onDeleted: () -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private let preview = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let restoreButton = NSButton(title: "Restore Note", target: nil, action: nil)
    private var rows: [NoteRecord] = []
    private var generation = 0
    private var searchWork: DispatchWorkItem?

    init(store: NotesStore, allNotes: Bool, onRestore: @escaping (UUID) -> Void,
         onError: @escaping (Error) -> Void, onDeleted: @escaping () -> Void = {}) {
        self.store = store
        self.allNotes = allNotes
        self.onRestore = onRestore
        self.onError = onError
        self.onDeleted = onDeleted
        let window = ArchiveWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 530),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = allNotes ? "Search Notes" : "Archive"
        window.minSize = NSSize(width: 640, height: 380)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = NSView()
        window.contentView = root

        search.placeholderString = allNotes ? "Search all notes and their contents" : "Search archived notes and their contents"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel(allNotes ? "Search all notes" : "Search archive")
        root.addSubview(search)

        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.title = "Notes"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .sourceList
        table.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(restoreSelected)
        table.setAccessibilityLabel("Saved notes")
        listScroll.documentView = table
        root.addSubview(listScroll)

        let previewScroll = NSScrollView()
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.font = Theme.font(13)
        preview.textColor = Theme.text
        preview.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        preview.textContainerInset = NSSize(width: 16, height: 16)
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = false
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        preview.setAccessibilityLabel("Note preview")
        previewScroll.documentView = preview
        root.addSubview(previewScroll)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        root.addSubview(status)
        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        restoreButton.bezelStyle = .rounded
        restoreButton.keyEquivalent = "\r"
        root.addSubview(restoreButton)
        for view in [search, listScroll, previewScroll, status, restoreButton] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            search.heightAnchor.constraint(equalToConstant: 28),
            listScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            listScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listScroll.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.43),
            listScroll.bottomAnchor.constraint(equalTo: restoreButton.topAnchor, constant: -14),
            previewScroll.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: 1),
            previewScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewScroll.topAnchor.constraint(equalTo: listScroll.topAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor),
            restoreButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            restoreButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: restoreButton.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: restoreButton.leadingAnchor, constant: -12)
        ])
        window.center()
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reload()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }
    func controlTextDidChange(_ obj: Notification) { reload() }

    func reload() {
        searchWork?.cancel()
        generation += 1
        let currentGeneration = generation
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = allNotes ? store.records.values.sorted { $0.modifiedAt > $1.modifiedAt } : store.archived
        let directory = store.notesDirectory
        if query.isEmpty { apply(candidates); return }
        status.stringValue = "Searching…"
        // No persistent index and no idle polling. Read text only when the user searches.
        let work = DispatchWorkItem { [weak self] in
            let matches = candidates.filter { record in
                if record.displayTitle.localizedCaseInsensitiveContains(query) { return true }
                let url = directory.appendingPathComponent("\(record.id.uuidString).txt")
                return (try? String(contentsOf: url, encoding: .utf8))?.localizedCaseInsensitiveContains(query) == true
            }
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.apply(matches)
            }
        }
        searchWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private func apply(_ records: [NoteRecord]) {
        let selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        rows = records
        table.reloadData()
        status.stringValue = rows.isEmpty ? "No matching notes" : "\(rows.count) \(rows.count == 1 ? "note" : "notes") · double-click to open"
        if !rows.isEmpty {
            let index = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updatePreview()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ArchiveRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ArchiveCell()
        let record = rows[row]
        cell.noteID = record.id
        cell.onDelete = { [weak self] id in self?.deleteNote(id) }
        let title = NSTextField(labelWithString: record.displayTitle)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        let stamp = DateFormatter.localizedString(from: record.archivedAt ?? record.modifiedAt, dateStyle: .medium, timeStyle: .short)
        let subtitle = NSTextField(labelWithString: "\(store.session.openIDs.contains(record.id) ? "Open · " : "")\(stamp)")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let delete = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete note")!,
            target: cell, action: #selector(ArchiveCell.deleteNote(_:)))
        delete.isBordered = false
        delete.contentTintColor = Theme.secondary
        delete.toolTip = "Delete note entirely"
        delete.setAccessibilityLabel("Delete \(record.displayTitle)")
        delete.isHidden = store.session.openIDs.contains(record.id)
        cell.addSubview(title); cell.addSubview(subtitle); cell.addSubview(delete)
        title.translatesAutoresizingMaskIntoConstraints = false
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        delete.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            delete.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            delete.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            delete.widthAnchor.constraint(equalToConstant: 26),
            delete.heightAnchor.constraint(equalToConstant: 26)
        ])
        cell.textField = title
        return cell
    }
    private func deleteNote(_ id: UUID) {
        guard store.records[id] != nil, !store.session.openIDs.contains(id) else { return }
        do {
            try store.deleteArchived(id)
            reload()
            onDeleted()
        } catch {
            reload()
            onError(error)
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updatePreview() }
    private func updatePreview() {
        guard rows.indices.contains(table.selectedRow) else {
            preview.string = "Closed tabs appear here. Their contents stay on this Mac."
            restoreButton.isEnabled = false
            return
        }
        let record = rows[table.selectedRow]
        do { preview.string = try store.text(record.id) }
        catch { preview.string = "Could not read this note: \(error.localizedDescription)" }
        preview.scrollRangeToVisible(NSRange(location: 0, length: 0))
        restoreButton.isEnabled = true
        restoreButton.title = store.session.openIDs.contains(record.id) ? "Open Note" : "Restore Note"
    }
    @objc private func restoreSelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        let id = rows[table.selectedRow].id
        onRestore(id)
        window?.close()
    }
}
