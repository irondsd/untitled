import AppKit

/// One row in the Hotkeys list: a section header or an action with its key combination.
struct Hotkey: Equatable {
    var title: String
    var keys: String
    var isSection: Bool { keys.isEmpty }
    static func section(_ title: String) -> Hotkey { Hotkey(title: title, keys: "") }

    /// Reads key equivalents from the main menu so the list always matches the real bindings,
    /// then adds keys the editor and Find panel handle outside the menu.
    static func list(from menu: NSMenu?) -> [Hotkey] {
        var rows: [Hotkey] = []
        for top in menu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            var section: [Hotkey] = []
            var numbered: [NSMenuItem] = []
            for item in submenu.items where !item.isHidden && !item.isSeparatorItem && !item.keyEquivalent.isEmpty {
                // Collapse "Tab 1" … "Tab 9" into one row.
                if item.title.hasPrefix("Tab "), Int(item.keyEquivalent) != nil { numbered.append(item); continue }
                section.append(Hotkey(title: item.title.replacingOccurrences(of: "…", with: ""), keys: keys(for: item)))
            }
            if let first = numbered.first, let last = numbered.last {
                section.append(Hotkey(title: "Select Tab by Position", keys: "\(keys(for: first))…\(last.keyEquivalent)"))
            }
            guard !section.isEmpty else { continue }
            rows.append(.section(top.title == "untitled" ? "App" : top.title))
            rows += section
        }
        rows.append(.section("Editor"))
        rows += [Hotkey(title: "Reduce Multiple Selections to One", keys: "Esc"),
                 Hotkey(title: "Open Markdown Link", keys: "⌘ Click")]
        rows.append(.section("Find Panel"))
        rows += [Hotkey(title: "Find Next / Previous", keys: "↩ / ⇧↩"),
                 Hotkey(title: "Replace and Find Next", keys: "↩ in Replace"),
                 Hotkey(title: "Move Between Find and Replace", keys: "⇥ / ⇧⇥"),
                 Hotkey(title: "Close Find", keys: "Esc")]
        return rows
    }

    static func keys(for item: NSMenuItem) -> String {
        let modifiers = item.keyEquivalentModifierMask
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let key = item.keyEquivalent
        switch key {
        case "\t": text += "⇥"
        case "\r": text += "↩"
        case "\u{1b}": text += "Esc"
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): text += "↑"
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): text += "↓"
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): text += "←"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): text += "→"
        case "-": text += "−"
        default:
            // An uppercase key equivalent implies Shift.
            if key != key.lowercased(), !modifiers.contains(.shift) { text.insert("⇧", at: text.index(before: text.endIndex)) }
            text += key.uppercased()
        }
        return text
    }
}

/// Read-only list of keyboard shortcuts for the Settings window.
@MainActor
final class HotkeysViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private(set) var rows: [Hotkey] = []

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 480))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let action = NSTableColumn(identifier: .init("action"))
        action.title = "Action"
        action.width = 270
        let keys = NSTableColumn(identifier: .init("keys"))
        keys.title = "Hotkey"
        keys.width = 130
        table.addTableColumn(action)
        table.addTableColumn(keys)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.usesAutomaticRowHeights = false
        table.rowHeight = 22
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Hotkeys")
        scroll.documentView = table
        view = scroll
        preferredContentSize = scroll.frame.size
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }
    func reload() {
        rows = Hotkey.list(from: NSApp.mainMenu)
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].isSection }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].isSection ? 28 : 22 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let hotkey = rows[row]
        if hotkey.isSection {
            let label = NSTextField(labelWithString: hotkey.title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        let isKeys = tableColumn?.identifier.rawValue == "keys"
        let label = NSTextField(labelWithString: isKeys ? hotkey.keys : hotkey.title)
        label.font = isKeys ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)
        label.textColor = isKeys ? .secondaryLabelColor : .labelColor
        label.alignment = isKeys ? .right : .left
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
