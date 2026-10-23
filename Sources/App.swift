import AppKit
import UniformTypeIdentifiers

/// A closed tab, newest last: archived notes by ID; discarded copies of unchanged files by path.
struct ClosedTab {
    var noteID: UUID?
    var filePath: String?
    var index: Int
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    var store: NotesStore!
    var window: NSWindow!
    let root = FlippedView()
    private let header = HeaderView()
    private let tabScroll = NSScrollView()
    private let tabDocument = NSView()
    private let titleButton = DraggableChromeButton()
    private let plusButton = NSButton()
    private let tint = NSView()
    private var tabs: [TabButton] = []
    var editors: [UUID: EditorPane] = [:]
    var currentID: UUID?
    private var saveWork: DispatchWorkItem?
    private var archiveController: ArchiveController?
    private var searchController: ArchiveController?
    private var lastSaveError: String?
    private(set) var fontSize: CGFloat = 14
    var preferences = EditorPreferences()
    var preferencesDefaults = UserDefaults.standard
    var settingsController: SettingsController?
    let findController = FindController()
    let occurrenceController = OccurrenceController()
    private var startupURLs: [URL] = []
    /// Closed this launch; older notes reopen from the archive, newest first.
    var closedTabs: [ClosedTab] = []
    private let headerHeight: CGFloat = 38
    private var isSmokeTesting: Bool { CommandLine.arguments.contains("--smoke-test") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let args = CommandLine.arguments
            let override = args.firstIndex(of: "--data-dir").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            let dataRoot = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("untitled", isDirectory: true)
            store = try NotesStore(root: dataRoot)
            // Disposable note roots also get separate preferences, never the user's settings.
            if override != nil {
                let suite = "local.untitled.tests." + dataRoot.path.replacingOccurrences(of: "/", with: ".")
                preferencesDefaults = UserDefaults(suiteName: suite)!
            }
            preferences = EditorPreferences(defaults: preferencesDefaults)
            fontSize = CGFloat(preferences.defaultFontSize)
            let savedSize = preferencesDefaults.double(forKey: "fontSize")
            if savedSize >= 10 && savedSize <= 36 { fontSize = CGFloat(EditorPreferences.fontSize(savedSize)) }
            buildMenus()
            buildWindow()
            try displaySelected()
            for url in startupURLs { try openFile(url) }
            startupURLs.removeAll()
            if !isSmokeTesting {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            reportTestGeometry()
            if args.contains("--smoke-test") { runSmokeTests() }
        } catch {
            showError(error)
            NSApp.terminate(nil)
        }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.delegate = self
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 420, height: 260)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = false
        window.contentView = root
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.frame = root.bounds
        root.addSubview(effect)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = preferences.backgroundColor.cgColor
        root.addSubview(tint)
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.clear.cgColor
        header.onOpenFiles = { [weak self] urls in
            guard let self else { return false }
            do {
                for url in urls { try self.openFile(url) }
                self.window.makeKeyAndOrderFront(nil)
                return true
            } catch {
                self.showError(error)
                return false
            }
        }
        root.addSubview(header)
        root.addSubview(findController.panel)
        findController.onVisibilityChange = { [weak self] in
            guard let self else { return }
            self.occurrenceController.setSuspended(self.findController.isVisible)
            self.layoutWindow()
        }
        tabScroll.drawsBackground = false
        tabScroll.automaticallyAdjustsContentInsets = false
        tabScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tabScroll.hasHorizontalScroller = false
        tabScroll.hasVerticalScroller = false
        tabScroll.documentView = tabDocument
        header.addSubview(tabScroll)
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 13, weight: .semibold)
        titleButton.contentTintColor = Theme.text
        titleButton.lineBreakMode = .byTruncatingMiddle
        titleButton.target = self
        titleButton.action = #selector(renameCurrent)
        titleButton.toolTip = "Drag to move · click to rename (⇧⌘R)"
        header.addSubview(titleButton)
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        plusButton.isBordered = false
        plusButton.wantsLayer = true
        plusButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.20).cgColor
        plusButton.contentTintColor = Theme.secondary
        plusButton.target = self
        plusButton.action = #selector(newTab)
        plusButton.toolTip = "New tab (⌘T)"
        plusButton.setAccessibilityLabel("New tab")
        header.addSubview(plusButton)
        root.onLayout = { [weak self] in self?.layoutWindow() }
        window.center()
        if !isSmokeTesting && !CommandLine.arguments.contains("--ui-test") { window.setFrameAutosaveName("EditorWindow") }
        rebuildTabs()
        layoutWindow()
    }

    private func layoutWindow() {
        guard window != nil else { return }
        tint.frame = root.bounds
        header.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: headerHeight)
        titleButton.frame = NSRect(x: 90, y: 0, width: max(0, root.bounds.width - 180), height: headerHeight)
        plusButton.frame = NSRect(x: root.bounds.width - 34, y: 0, width: 34, height: headerHeight)
        tabScroll.frame = NSRect(x: 80, y: 0, width: max(0, root.bounds.width - 114), height: headerHeight)
        let width = max(150, tabScroll.bounds.width / CGFloat(max(1, tabs.count)))
        tabDocument.frame = NSRect(x: 0, y: 0, width: max(tabScroll.bounds.width, width * CGFloat(tabs.count)), height: headerHeight)
        for (index, tab) in tabs.enumerated() {
            tab.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: headerHeight)
            tab.needsLayout = true
            tab.layoutSubtreeIfNeeded()
        }
        if let currentID, let pane = editors[currentID] {
            let findHeight = findController.isVisible ? FindPanel.height : 0
            pane.scroll.frame = NSRect(x: 0, y: headerHeight, width: root.bounds.width, height: max(0, root.bounds.height - headerHeight - findHeight))
            pane.layoutEditor()
        }
        findController.panel.frame = NSRect(x: 0, y: root.bounds.height - FindPanel.height, width: root.bounds.width, height: FindPanel.height)
        // Keep native traffic lights in the same compact row as the custom tabs.
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind), let host = button.superview else { continue }
            let row = header.convert(NSRect(x: 0, y: 0, width: 80, height: headerHeight), to: host)
            button.setFrameOrigin(NSPoint(x: CGFloat(13 + index * 20), y: row.midY - button.frame.height / 2))
        }
    }

    private func rebuildTabs() {
        tabs.forEach { $0.removeFromSuperview() }
        tabs.removeAll()
        for (index, id) in store.session.openIDs.enumerated() {
            guard let record = store.records[id] else { continue }
            let tab = TabButton(record: record, number: index + 1, active: id == store.session.selectedID)
            tab.onSelect = { [weak self] id in self?.perform { try self?.switchTab(id) } }
            tab.onClose = { [weak self] id in self?.perform { try self?.close(id) } }
            tab.onRename = { [weak self] id in self?.rename(id) }
            tabDocument.addSubview(tab)
            tabs.append(tab)
        }
        let multiple = tabs.count > 1
        header.leadingIsInactive = multiple && store.session.openIDs.first != store.session.selectedID
        tabScroll.isHidden = !multiple
        plusButton.isHidden = !multiple
        titleButton.isHidden = multiple
        if let id = store.session.selectedID, let record = store.records[id] {
            titleButton.title = record.displayTitle
            titleButton.setAccessibilityLabel("\(record.displayTitle), rename note")
            window.title = record.displayTitle
            window.representedURL = record.filePath.map { URL(fileURLWithPath: $0) }
            updateEditedIndicator()
        }
        layoutWindow()
        if let index = store.session.openIDs.firstIndex(of: store.session.selectedID ?? UUID()), tabs.indices.contains(index) {
            tabDocument.scrollToVisible(tabs[index].frame)
        }
    }

    func displaySelected() throws {
        guard let id = store.session.selectedID, let record = store.records[id] else { return }
        if let currentID { editors[currentID]?.scroll.removeFromSuperview() }
        if editors[id] == nil {
            let pane = EditorPane(text: try store.text(id), fontSize: fontSize,
                fontFamily: preferences.fontFamily, record: record)
            pane.applyAppearance(brightness: preferences.brightness, showsLineNumbers: preferences.showsLineNumbers)
            pane.textView.delegate = self
            editors[id] = pane
        }
        currentID = id
        let pane = editors[id]!
        root.addSubview(pane.scroll, positioned: .below, relativeTo: header)
        layoutWindow()
        pane.scroll.contentView.scroll(to: NSPoint(x: -pane.scroll.contentView.contentInsets.left, y: record.scrollOffset))
        pane.scroll.reflectScrolledClipView(pane.scroll.contentView)
        rebuildTabs()
        window.makeFirstResponder(pane.textView)
        findController.bind(pane.textView)
        occurrenceController.bind(pane.textView)
    }

    func flush() throws {
        saveWork?.cancel()
        saveWork = nil
        for (id, pane) in editors where pane.dirty {
            try store.saveText(pane.textView.string, for: id)
            pane.dirty = false
        }
        if let id = currentID, let pane = editors[id] {
            let range = pane.textView.selectedRange()
            try store.savePosition(id, location: range.location, length: range.length, offset: pane.scroll.contentView.bounds.origin.y)
        }
        try store.saveSession()
        lastSaveError = nil
        updateEditedIndicator()
    }

    func switchTab(_ id: UUID) throws {
        guard id != currentID else { return }
        try flush()
        try store.select(id)
        try displaySelected()
    }
    func close(_ id: UUID) throws {
        try flush()
        let record = store.records[id], index = store.session.openIDs.firstIndex(of: id)
        try store.archive(id)
        if let index {
            if store.records[id] != nil { closedTabs.append(ClosedTab(noteID: id, index: index)) }
            else if record?.openedFromFile == true, let path = record?.filePath { closedTabs.append(ClosedTab(filePath: path, index: index)) }
        }
        if currentID == id { editors[id]?.scroll.removeFromSuperview(); currentID = nil }
        editors.removeValue(forKey: id)
        try displaySelected()
        archiveController?.reload()
        searchController?.reload()
    }
    func restore(_ id: UUID) throws {
        try flush()
        try store.restore(id)
        try displaySelected()
        archiveController?.reload()
        searchController?.reload()
        if !isSmokeTesting { window.makeKeyAndOrderFront(nil) }
    }

    func textDidChange(_ notification: Notification) {
        guard let id = currentID, let pane = editors[id], notification.object as? NSTextView === pane.textView else { return }
        pane.dirty = true
        findController.documentDidChange()
        occurrenceController.documentDidChange()
        // Hashing the whole document belongs to the delayed save, not the typing path.
        window.isDocumentEdited = store.records[id]?.filePath != nil
        scheduleSave()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        if (notification.object as? EditorTextView)?.isSettingEditingSelections == true { return }
        scheduleSave()
        if let id = currentID, notification.object as? NSTextView === editors[id]?.textView {
            findController.selectionDidChange()
            occurrenceController.selectionDidChange()
        }
    }
    func undoManager(for view: NSTextView) -> UndoManager? {
        editors.values.first { $0.textView === view }?.undo
    }
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do { try self.flush() }
            catch {
                let description = error.localizedDescription
                if self.lastSaveError != description {
                    self.lastSaveError = description
                    self.showError(error)
                }
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    private func updateEditedIndicator() {
        guard let id = store.session.selectedID, let record = store.records[id] else { return }
        if record.filePath != nil, let pane = editors[id] {
            window.isDocumentEdited = NotesStore.hash(pane.textView.string) != record.savedFileHash
        } else { window.isDocumentEdited = false }
    }

    @objc func newTab(_ sender: Any? = nil) {
        perform {
            try flush()
            _ = try store.create()
            try displaySelected()
            if !isSmokeTesting { window.makeKeyAndOrderFront(nil) }
        }
    }
    @objc func closeTab(_ sender: Any? = nil) {
        if let key = NSApp.keyWindow, key !== window { key.performClose(sender); return }
        guard let id = currentID else { return }
        perform {
            if store.session.openIDs.count == 1 {
                // Check the saved text only after pending editor changes have been flushed.
                try flush()
                if try store.isBlankScratch(id) {
                    window.orderOut(sender)
                    return
                }
            }
            try close(id)
        }
    }
    @objc private func selectNumber(_ sender: NSMenuItem) {
        guard store.session.openIDs.indices.contains(sender.tag) else { return }
        perform { try switchTab(store.session.openIDs[sender.tag]) }
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func nextTab(_ sender: Any?) { cycleTab(delta: 1) }
    @objc private func previousTab(_ sender: Any?) { cycleTab(delta: -1) }
    private func cycleTab(delta: Int) {
        guard let id = currentID, let index = store.session.openIDs.firstIndex(of: id) else { return }
        let count = store.session.openIDs.count
        perform { try switchTab(store.session.openIDs[(index + delta + count) % count]) }
    }
    @objc private func reopenClosed(_ sender: Any?) {
        perform { if try !reopenLastClosed() { NSSound.beep() } }
    }
    /// Like a browser: the most recent closed tab returns to its old position. When it replaces the
    /// blank note left by closing the last tab, that blank note is closed.
    @discardableResult
    func reopenLastClosed() throws -> Bool {
        try flush()
        let open = store.session.openIDs
        let blank = try open.count == 1 && store.isBlankScratch(open[0]) ? open[0] : nil
        while let tab = closedTabs.popLast() {
            guard isReopenable(tab) else { continue }
            if let id = tab.noteID { try restore(id) }
            else if let path = tab.filePath { try openFile(URL(fileURLWithPath: path)) }
            if let id = currentID { try store.move(id, to: tab.index); rebuildTabs() }
            if let blank { try close(blank) }
            return true
        }
        guard let record = store.archived.first else { return false }
        try restore(record.id)
        if let blank { try close(blank) }
        return true
    }
    private func isReopenable(_ tab: ClosedTab) -> Bool {
        if let id = tab.noteID { return store.records[id] != nil && !store.session.openIDs.contains(id) }
        guard let path = tab.filePath, FileManager.default.fileExists(atPath: path) else { return false }
        return !store.session.openIDs.contains { store.records[$0]?.filePath == path }
    }
    @objc private func renameCurrent(_ sender: Any?) { if let id = currentID { rename(id) } }
    private func rename(_ id: UUID) {
        guard let record = store.records[id] else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Note"
        alert.informativeText = "Give this note a title. Leave it empty to use the default name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = record.title ?? ""
        field.placeholderString = record.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "untitled"
        field.setAccessibilityLabel("Note title")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.perform { try self.store.rename(id, title: field.stringValue); self.rebuildTabs() }
        }
    }
    @objc private func showArchive(_ sender: Any?) { showNotes(all: false) }
    @objc private func searchNotes(_ sender: Any?) { showNotes(all: true) }
    private func showNotes(all: Bool) {
        perform {
            try flush()
            let controller = ArchiveController(store: store, allNotes: all, onRestore: { [weak self] id in
                self?.perform { try self?.restore(id) }
            }, onError: { [weak self] error in self?.showError(error) }, onDeleted: { [weak self] in
                self?.archiveController?.reload()
                self?.searchController?.reload()
            })
            if all { searchController?.close(); searchController = controller }
            else { archiveController?.close(); archiveController = controller }
            controller.showWindow(nil)
        }
    }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Text Files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.perform { for url in panel.urls { try self.openFile(url) } }
        }
    }
    func openFile(_ url: URL) throws {
        try flush()
        let path = url.standardizedFileURL.path
        if let record = store.records.values.first(where: { $0.filePath == path }) {
            try restore(record.id)
            return
        }
        let data = try Data(contentsOf: url)
        if data.starts(with: Array("bplist00".utf8)) {
            throw NSError(domain: "untitled", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "This is a binary property list. Open an XML/text version of the plist instead."])
        }
        guard !data.starts(with: [0x00]),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
              !text.contains("\0") else {
            throw NSError(domain: "untitled", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file is not supported text. Open a UTF-8 or UTF-16 text file."])
        }
        _ = try store.create(text: text, filePath: path)
        try displaySelected()
    }
    @objc private func saveDocument(_ sender: Any?) {
        guard let id = currentID, let record = store.records[id], let pane = editors[id] else { return }
        guard let path = record.filePath else { saveDocumentAs(sender); return }
        perform {
            try flush()
            let url = URL(fileURLWithPath: path)
            try ExternalFileWriter.write(pane.textView.string, to: url)
            try store.associateFile(id, url: url, text: pane.textView.string)
            rebuildTabs()
        }
    }
    @objc private func saveDocumentAs(_ sender: Any?) {
        guard let id = currentID, let record = store.records[id], let pane = editors[id] else { return }
        let panel = NSSavePanel()
        panel.title = "Save Note as File"
        panel.nameFieldStringValue = suggestedFileName(record, text: pane.textView.string)
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.perform {
                try self.flush()
                try ExternalFileWriter.write(pane.textView.string, to: url)
                try self.store.associateFile(id, url: url, text: pane.textView.string)
                self.rebuildTabs()
            }
        }
    }

    /// Titles that already name an extension are kept; otherwise the note's syntax supplies one.
    private func suggestedFileName(_ record: NoteRecord, text: String) -> String {
        let name = record.displayTitle
        if !URL(fileURLWithPath: name).pathExtension.isEmpty { return name }
        let language = record.syntaxOverride ?? SyntaxEngine.detectLanguage(text)
        return name + "." + SyntaxEngine.fileExtension(for: text, language: language)
    }

    @objc private func setSyntax(_ sender: NSMenuItem) {
        guard let id = currentID, let pane = editors[id] else { return }
        let language = sender.representedObject as? String
        perform {
            try store.setSyntax(id, language: language.flatMap(NoteLanguage.init(rawValue:)))
            pane.syntax.override = store.records[id]?.syntaxOverride
        }
    }

    @objc private func increaseFont(_ sender: Any?) { changeFont(by: 1) }
    @objc private func decreaseFont(_ sender: Any?) { changeFont(by: -1) }
    @objc private func resetFont(_ sender: Any?) { fontSize = CGFloat(preferences.defaultFontSize); changeFont(by: 0) }
    private func changeFont(by delta: CGFloat) {
        fontSize = CGFloat(EditorPreferences.fontSize(Double(fontSize + delta)))
        preferencesDefaults.set(Double(fontSize), forKey: "fontSize")
        editors.values.forEach { $0.applyFont(size: fontSize, family: preferences.fontFamily) }
    }
    @objc private func changeOpacity(_ sender: NSMenuItem) {
        var updated = preferences
        updated.opacity = Double(sender.tag) / 100
        applyPreferences(updated)
    }
    func applyPreferences(_ updated: EditorPreferences) {
        let defaultChanged = preferences.defaultFontSize != updated.defaultFontSize
        let familyChanged = preferences.fontFamily != updated.fontFamily
        preferences = updated
        preferences.save(to: preferencesDefaults)
        tint.layer?.backgroundColor = preferences.backgroundColor.cgColor
        // A new family keeps any temporary zoom; a new default size replaces it.
        if defaultChanged { fontSize = CGFloat(preferences.defaultFontSize) }
        if defaultChanged || familyChanged { changeFont(by: 0) }
        for pane in editors.values {
            pane.applyAppearance(brightness: preferences.brightness, showsLineNumbers: preferences.showsLineNumbers)
        }
        settingsController?.refresh(preferences)
    }
    @objc private func showSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsController(preferences: preferences)
            settingsController?.onChange = { [weak self] in self?.applyPreferences($0) }
        }
        settingsController?.refresh(preferences)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func revealStorage(_ sender: Any?) { NSWorkspace.shared.open(store.root) }
    @objc private func showMainWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        if let currentID { window.makeFirstResponder(editors[currentID]?.textView) }
    }
    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "untitled", .applicationVersion: "0.1.4",
            .credits: NSAttributedString(string: "A quiet place for things you want to keep.\nNative macOS. Notes stay on this Mac.")
        ])
    }

    @objc func showFind(_ sender: Any? = nil) { findController.show() }
    @objc func selectNextOccurrence(_ sender: Any? = nil) {
        guard let id = currentID, let editor = editors[id]?.textView, window.firstResponder === editor else { return }
        if findController.isVisible { findController.close() }
        occurrenceController.selectNext()
    }
    @objc func selectAllOccurrences(_ sender: Any? = nil) {
        guard let id = currentID, let editor = editors[id]?.textView, window.firstResponder === editor else { return }
        if findController.isVisible { findController.close() }
        occurrenceController.selectAll()
    }
    @objc private func showReplace(_ sender: Any?) { findController.show(focusReplacement: true) }
    @objc private func findNext(_ sender: Any?) {
        findController.navigate()
    }
    @objc private func findPrevious(_ sender: Any?) {
        findController.navigate(backwards: true)
    }
    @objc private func undoEditing(_ sender: Any?) {
        if NSApp.keyWindow === window, let manager = findController.panelUndoManager { manager.undo() }
        else { NSApp.sendAction(Selector(("undo:")), to: nil, from: sender) }
    }
    @objc private func redoEditing(_ sender: Any?) {
        if NSApp.keyWindow === window, let manager = findController.panelUndoManager { manager.redo() }
        else { NSApp.sendAction(Selector(("redo:")), to: nil, from: sender) }
    }

    private func buildMenus() {
        let main = NSMenu()
        NSApp.mainMenu = main
        func submenu(_ title: String) -> NSMenu {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; return menu
        }
        @discardableResult
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let value = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            value.keyEquivalentModifierMask = modifiers
            value.target = target
            return value
        }
        let app = submenu("untitled")
        item(app, "About untitled", #selector(showAbout), target: self)
        app.addItem(.separator())
        item(app, "Settings…", #selector(showSettings), ",", target: self)
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = app.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; NSApp.servicesMenu = services
        app.addItem(.separator())
        item(app, "Hide untitled", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        item(app, "Quit untitled", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = submenu("File")
        item(file, "New Tab", #selector(newTab), "t", target: self)
        item(file, "New Note", #selector(newTab), "n", target: self)
        item(file, "Open…", #selector(openDocument), "o", target: self)
        file.addItem(.separator())
        item(file, "Save to File…", #selector(saveDocument), "s", target: self)
        item(file, "Save As…", #selector(saveDocumentAs), "s", [.command, .shift], target: self)
        item(file, "Rename Note…", #selector(renameCurrent), "r", [.command, .shift], target: self)
        file.addItem(.separator())
        item(file, "Close and Archive Tab", #selector(closeTab), "w", target: self)
        item(file, "Reopen Closed Tab", #selector(reopenClosed), "t", [.command, .shift], target: self)
        item(file, "Archive…", #selector(showArchive), "a", [.command, .shift], target: self)
        item(file, "Search All Notes…", #selector(searchNotes), "f", [.command, .shift], target: self)
        file.addItem(.separator())
        item(file, "Show Notes Folder", #selector(revealStorage), target: self)
        let edit = submenu("Edit")
        item(edit, "Undo", #selector(undoEditing), "z", target: self)
        item(edit, "Redo", #selector(redoEditing), "z", [.command, .shift], target: self)
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        item(edit, "Select Next Occurrence", #selector(selectNextOccurrence), "d", target: self)
        item(edit, "Select All Occurrences", #selector(selectAllOccurrences), "d", [.command, .shift], target: self)
        edit.addItem(.separator())
        item(edit, "Find and Replace…", #selector(showFind), "f", target: self)
        item(edit, "Replace…", #selector(showReplace), "f", [.command, .option], target: self)
        item(edit, "Find Next", #selector(findNext), "g", target: self)
        item(edit, "Find Previous", #selector(findPrevious), "g", [.command, .shift], target: self)
        let view = submenu("View")
        item(view, "Increase Text Size", #selector(increaseFont), "+", target: self)
        let increaseAlternate = item(view, "Increase Text Size", #selector(increaseFont), "=", target: self)
        increaseAlternate.isHidden = true
        increaseAlternate.allowsKeyEquivalentWhenHidden = true
        item(view, "Decrease Text Size", #selector(decreaseFont), "-", target: self)
        item(view, "Reset Text Size", #selector(resetFont), "0", target: self)
        view.addItem(.separator())
        let opacityMenu = NSMenu(title: "Background")
        let opacityParent = view.addItem(withTitle: "Background", action: nil, keyEquivalent: "")
        opacityParent.submenu = opacityMenu
        for (title, value) in [("More Transparent", 25), ("Balanced", 48), ("More Opaque", 75), ("Solid", 100)] {
            let valueItem = item(opacityMenu, title, #selector(changeOpacity), target: self)
            valueItem.tag = value
        }
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        let syntaxMenu = submenu("Syntax")
        item(syntaxMenu, "Detect Automatically", #selector(setSyntax), target: self)
        syntaxMenu.addItem(.separator())
        for language in NoteLanguage.allCases {
            item(syntaxMenu, language.displayName, #selector(setSyntax), target: self).representedObject = language.rawValue
        }
        let tabMenu = submenu("Tabs")
        item(tabMenu, "Next Tab", #selector(nextTab), "\t", [.control], target: self)
        item(tabMenu, "Previous Tab", #selector(previousTab), "\t", [.control, .shift], target: self)
        tabMenu.addItem(.separator())
        for number in 1...9 {
            let numberItem = item(tabMenu, "Tab \(number)", #selector(selectNumber), String(number), target: self)
            numberItem.tag = number - 1
        }
        let windowMenu = submenu("Window")
        NSApp.windowsMenu = windowMenu
        item(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        item(windowMenu, "Show Editor", #selector(showMainWindow), target: self)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectNextOccurrence) || menuItem.action == #selector(selectAllOccurrences) {
            guard NSApp.keyWindow == nil || NSApp.keyWindow === window, let id = currentID else { return false }
            return window.firstResponder === editors[id]?.textView
        }
        if menuItem.action == #selector(undoEditing) || menuItem.action == #selector(redoEditing) {
            let manager = (NSApp.keyWindow === window ? findController.panelUndoManager : nil)
                ?? (NSApp.keyWindow ?? window).firstResponder?.undoManager
            return menuItem.action == #selector(undoEditing) ? manager?.canUndo == true : manager?.canRedo == true
        }
        if [#selector(showFind), #selector(showReplace), #selector(findNext), #selector(findPrevious)].contains(menuItem.action) {
            return NSApp.keyWindow?.isVisible != true || NSApp.keyWindow === window
        }
        if menuItem.action == #selector(selectNumber) { return store.session.openIDs.indices.contains(menuItem.tag) }
        if menuItem.action == #selector(reopenClosed) { return closedTabs.contains(where: isReopenable) || !store.archived.isEmpty }
        if menuItem.action == #selector(setSyntax) {
            guard let id = currentID, let pane = editors[id] else { return false }
            let chosen = menuItem.representedObject as? String
            menuItem.state = chosen == pane.syntax.override?.rawValue ? .on : .off
            if chosen == nil {
                // Show what detection picked while it is in charge.
                menuItem.title = pane.syntax.override == nil && pane.syntax.language != .plain
                    ? "Detect Automatically (\(pane.syntax.language.displayName))" : "Detect Automatically"
            }
            return NSApp.keyWindow == nil || NSApp.keyWindow === window
        }
        if menuItem.action == #selector(changeOpacity) { menuItem.state = Int((preferences.opacity * 100).rounded()) == menuItem.tag ? .on : .off }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        do { try flush(); return true }
        catch { showError(error); return false }
    }
    func windowDidResize(_ notification: Notification) { layoutWindow() }
    func windowDidMove(_ notification: Notification) { reportTestGeometry() }
    private func reportTestGeometry() {
        guard CommandLine.arguments.contains("--ui-test"), let window, let store else { return }
        let frame = window.frame
        var values: [String: Any] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        if let id = currentID, let pane = editors[id] {
            values["scroll"] = NSStringFromRect(pane.scroll.frame)
            values["clip"] = NSStringFromRect(pane.scroll.contentView.frame)
            values["clipBounds"] = NSStringFromRect(pane.scroll.contentView.bounds)
            values["text"] = NSStringFromRect(pane.textView.frame)
            values["textInRoot"] = NSStringFromRect(root.convert(pane.textView.bounds, from: pane.textView))
            values["ruler"] = NSStringFromRect(pane.lineNumbers.frame)
            values["scrollSubviews"] = pane.scroll.subviews.map { "\(type(of: $0)): \($0.frame)" }
        }
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
            try? data.write(to: store.root.appendingPathComponent("window-frame.json"), options: .atomic)
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { layoutWindow() }
    func applicationWillResignActive(_ notification: Notification) { perform { try flush() } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil else { return .terminateNow }
        do { try flush(); return .terminateNow }
        catch { showError(error); return .terminateCancel }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(nil); return true
    }
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard store != nil, window != nil else { startupURLs.append(contentsOf: urls); return }
        perform { for url in urls { try openFile(url) }; window.makeKeyAndOrderFront(nil) }
    }
    func perform(_ work: () throws -> Void) {
        do { try work() } catch CocoaError.userCancelled {} catch { showError(error) }
    }
    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "untitled couldn’t complete that action"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

@main
struct UntitledMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if (args.contains("--smoke-test") || args.contains("--ui-test")) && !args.contains("--data-dir") {
            fputs("Test modes require an isolated --data-dir.\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
