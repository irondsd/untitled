import AppKit

extension AppDelegate {
    /// Runs only against the explicitly supplied disposable data folder.
    func runSmokeTests() {
        Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            var checks: [String] = []
            func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
                guard try condition() else { throw NSError(domain: "SmokeTest", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
                checks.append(name)
            }
            do {
                try check(CommandLine.arguments.contains("--data-dir"), "isolated test storage")
                let first = currentID!
                let pane = editors[first]!
                try check(pane.textView is EditorTextView, "editor uses repeat-aware paste handling")
                let pastePress = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
                let pasteRepeat = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "v", charactersIgnoringModifiers: "v", isARepeat: true, keyCode: 9)!
                try check(!EditorTextView.discardsPasteRepeat(pastePress, modifiers: [], keyIsDown: { _ in false }),
                    "a quick paste still works after both keys have been released")
                try check(!EditorTextView.discardsPasteRepeat(pasteRepeat, modifiers: .command, keyIsDown: { $0 == 9 }),
                    "holding Command and V continues repeated pasting")
                try check(EditorTextView.discardsPasteRepeat(pasteRepeat, modifiers: [], keyIsDown: { _ in true }),
                    "queued paste repeats stop when Command is released")
                try check(EditorTextView.discardsPasteRepeat(pasteRepeat, modifiers: .command, keyIsDown: { _ in false }),
                    "queued paste repeats stop when V is released")
                try check(EditorTextView.discardsPasteRepeat(pasteRepeat, modifiers: [], keyIsDown: { _ in false }),
                    "a backlog of paste repeats is ignored after both keys are released")
                try check(!EditorTextView.discardsPasteRepeat(nil, modifiers: [], keyIsDown: { _ in false }),
                    "menu and programmatic pastes do not depend on held keys")
                let otherRepeat = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "z", charactersIgnoringModifiers: "z", isARepeat: true, keyCode: 6)!
                try check(!EditorTextView.discardsPasteRepeat(otherRepeat, modifiers: [], keyIsDown: { _ in false }),
                    "paste filtering leaves other repeated shortcuts alone")
                pane.textView.insertText("First note — preserved 📝\nsecond line", replacementRange: pane.textView.selectedRange())
                try flush()
                try check(try store.text(first) == pane.textView.string, "native typing persisted")
                try check(pane.lineNumbers.lines.starts.count == 2, "native edits update logical line numbers")
                pane.layoutEditor()
                let textEdge = pane.scroll.convert(NSPoint(x: 0, y: 0), from: pane.textView).x
                try check(textEdge >= pane.lineNumbers.frame.maxX,
                    "line-number gutter reserves space beside editable text")
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17)!
                try check(NSApp.mainMenu!.performKeyEquivalent(with: event), "Command-T handled by menu")
                let second = currentID!
                try check(first != second && store.session.openIDs.count == 2, "new tab selected")
                if let frame = root.superview {
                    root.layoutSubtreeIfNeeded()
                    let point = root.convert(NSPoint(x: 200, y: 19), to: frame)
                    let hit = frame.hitTest(point)
                    try check(hit is TabSelectButton, "title-bar tabs receive mouse input")
                    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                        if let button = window.standardWindowButton(kind) {
                            let rect = root.convert(button.bounds, from: button)
                            try check(rect.minY >= 0 && rect.maxY <= 38, "window control fits title-bar row")
                        }
                    }
                }
                let secondPane = editors[second]!
                secondPane.textView.insertText("Second note", replacementRange: NSRange(location: 0, length: 0))
                try flush()
                try switchTab(first)
                try check(editors[first] === pane, "switching tabs retains native text system")
                try check(pane.textView.undoManager?.canUndo == true, "undo history survives tab switch")
                pane.textView.undoManager?.undo()
                try check(pane.textView.string.isEmpty, "undo affects only the selected tab")
                try check(pane.lineNumbers.lines.starts == [0], "line numbers update after undo")
                try check(secondPane.textView.string == "Second note", "other tab remains intact")
                pane.textView.undoManager?.redo()
                try flush()
                try close(first)
                try check(store.archived.contains { $0.id == first }, "close moves note to archive")
                try check(try store.text(first) == "First note — preserved 📝\nsecond line", "archived contents preserved")
                try restore(first)
                try check(currentID == first && store.session.openIDs.count == 2, "restore reopens the same note")
                try store.rename(first, title: "Keep me")
                try check(store.records[first]?.displayTitle == "Keep me", "custom title saved")
                try flush()
                let reloaded = try NotesStore(root: store.root)
                try check(reloaded.session.openIDs == store.session.openIDs, "tab order survives restart")
                try check(reloaded.session.selectedID == first, "active tab survives restart")
                try check(reloaded.records[first]?.displayTitle == "Keep me", "custom title survives restart")
                try close(first)
                try close(second)
                try check(store.session.openIDs.count == 1 && store.archived.count == 2, "closing last tab creates fresh note without loss")
                try check(root.subviews.contains { $0 is NSScrollView }, "native editor attached to window")
                try check(window.standardWindowButton(.closeButton)?.isHidden == false, "native window controls visible")
                let fileURL = store.root.appendingPathComponent("external-example.txt")
                try "Original file".write(to: fileURL, atomically: true, encoding: .utf8)
                try openFile(fileURL)
                let fileID = currentID!
                try check(store.records[fileID]?.displayTitle == "external-example.txt", "opened file uses its filename")
                let filePane = editors[fileID]!
                filePane.textView.insertText("Changed ", replacementRange: NSRange(location: 0, length: 0))
                try flush()
                try check(try String(contentsOf: fileURL, encoding: .utf8) == "Original file", "autosave only updates local copy")
                let saveEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
                try check(NSApp.mainMenu!.performKeyEquivalent(with: saveEvent), "Command-S handled by menu")
                try check(try String(contentsOf: fileURL, encoding: .utf8) == "Changed Original file", "explicit save writes external file")
                let wrappedText = String(repeating: "a long wrapped line ", count: 60) + "\nshort\n"
                let wrappingPane = EditorPane(text: wrappedText, fontSize: 14, record: store.records[fileID]!)
                wrappingPane.scroll.frame = NSRect(x: 0, y: 0, width: 280, height: 300)
                wrappingPane.layoutEditor()
                let manager = wrappingPane.textView.layoutManager!
                manager.ensureLayout(for: wrappingPane.textView.textContainer!)
                let firstFragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                let nextGlyph = manager.glyphIndexForCharacter(at: wrappingPane.lineNumbers.lines.starts[1])
                let nextFragment = manager.lineFragmentRect(forGlyphAt: nextGlyph, effectiveRange: nil)
                try check(nextFragment.minY > firstFragment.height * 2, "long logical line wraps into multiple visual rows")
                try check(wrappingPane.lineNumbers.lines.starts.count == 3, "wrapped rows do not add logical line numbers")
                wrappingPane.applyFont(size: 18)
                try check(wrappingPane.lineNumbers.lines.starts.count == 3, "font changes preserve logical numbering")
                let archivedCount = store.archived.count
                newTab(nil)
                let emptyID = currentID!
                try close(emptyID)
                try check(store.records[emptyID] == nil && store.archived.count == archivedCount, "closing a blank native tab skips the archive")
                newTab(nil)
                let namedEmpty = currentID!
                try store.rename(namedEmpty, title: "Named empty note")
                try close(namedEmpty)
                try check(store.archived.contains { $0.id == namedEmpty }, "closing a renamed empty tab archives it")
                try store.deleteArchived(namedEmpty)
                try check(store.records[namedEmpty] == nil && !FileManager.default.fileExists(atPath: store.textURL(namedEmpty).path), "explicit archive deletion removes local note files")
                let originalOrigin = window.frame.origin
                let drag = ChromeWindowDrag()
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1)!
                drag.begin(down, in: window)
                let slight = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 101, y: 100),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 2, clickCount: 1, pressure: 1)!
                drag.update(slight, in: window)
                try check(!drag.didMove && window.frame.origin == originalOrigin, "small pointer motion remains a click")
                let moved = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 140, y: 80),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 3, clickCount: 1, pressure: 1)!
                drag.update(moved, in: window)
                try check(drag.didMove && window.frame.origin == NSPoint(x: originalOrigin.x + 40, y: originalOrigin.y - 20),
                    "title-row dragging moves the native window")
                drag.end()
                try check(!drag.didMove, "drag state resets on release")
                window.setFrameOrigin(originalOrigin)
                let baselinePane = EditorPane(text: "First\n\nThird\n", fontSize: 14, record: store.records[fileID]!)
                baselinePane.scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
                baselinePane.layoutEditor()
                let baselineManager = baselinePane.textView.layoutManager!
                let baselineContainer = baselinePane.textView.textContainer!
                baselineManager.ensureLayout(for: baselineContainer)
                let emptyBaseline = baselinePane.lineNumbers.baseline(for: 1)!
                let followingBaseline = baselinePane.lineNumbers.baseline(for: 2)!
                baselinePane.textView.insertText("f", replacementRange: NSRange(location: 6, length: 0))
                baselineManager.ensureLayout(for: baselineContainer)
                try check(abs(baselinePane.lineNumbers.baseline(for: 1)! - emptyBaseline) < 0.01,
                    "typing one character on an empty line does not move its number")
                try check(abs(baselinePane.lineNumbers.baseline(for: 2)! - followingBaseline) < 0.01,
                    "typing on an empty line does not move subsequent line numbers")
                baselinePane.textView.insertText("", replacementRange: NSRange(location: 6, length: 1))
                baselineManager.ensureLayout(for: baselineContainer)
                try check(abs(baselinePane.lineNumbers.baseline(for: 1)! - emptyBaseline) < 0.01,
                    "deleting the final character preserves the line-number baseline")
                let finalLineBaseline = baselinePane.lineNumbers.baseline(for: 3)!
                let end = (baselinePane.textView.string as NSString).length
                baselinePane.textView.insertText("x", replacementRange: NSRange(location: end, length: 0))
                baselineManager.ensureLayout(for: baselineContainer)
                try check(abs(baselinePane.lineNumbers.baseline(for: 3)! - finalLineBaseline) < 0.01,
                    "typing on the final empty line preserves its number baseline")
                // Live preferences must preserve native editing state and note contents.
                let settingsPane = editors[currentID!]!
                settingsPane.textView.insertText("Settings fixture\nsecond line", replacementRange: settingsPane.textView.selectedRange())
                try flush()
                let settingsText = settingsPane.textView.string
                let settingsSelection = settingsPane.textView.selectedRange()
                let oldPreferences = preferences
                var updated = preferences
                updated.opacity = 0.72
                updated.backgroundBlackLevel = 0.6
                updated.brightness = 0.68
                updated.defaultFontSize = 18.3
                updated.showsLineNumbers = false
                applyPreferences(updated)
                try check(EditorPreferences(defaults: preferencesDefaults) == updated, "all appearance settings persist")
                let background = preferences.backgroundColor.usingColorSpace(.genericGray)!
                try check(abs(background.whiteComponent - 0.4) < 0.001 && abs(background.alphaComponent - 0.72) < 0.001,
                    "background black level and opacity vary independently")
                try check(EditorPreferences.fontSize(9.9) == 10 && EditorPreferences.fontSize(36.1) == 36
                    && EditorPreferences.fontSize(14.26) == 14.3, "font size clamps to limits and rounds to one decimal")
                try check(fontSize == 18.3 && editors.values.allSatisfy { $0.textView.font?.pointSize == 18.3 },
                    "default font size applies to all open editors")
                try check(!settingsPane.scroll.rulersVisible && settingsPane.scroll.contentView.contentInsets.left == 0,
                    "hiding line numbers removes the gutter")
                try check(settingsPane.scroll.convert(.zero, from: settingsPane.textView).x == 0,
                    "text fills the hidden gutter without a horizontal offset")
                try check(settingsPane.textView.string == settingsText && settingsPane.textView.selectedRange() == settingsSelection,
                    "live appearance changes preserve text and selection")
                try check(!settingsPane.dirty && settingsPane.textView.undoManager?.canUndo == true,
                    "settings leave autosave and undo state intact")
                settingsPane.textView.undoManager?.undo()
                try check(!settingsPane.textView.string.contains("Settings fixture"), "appearance changes do not replace the text undo action")
                settingsPane.textView.undoManager?.redo()
                try check(settingsPane.textView.string == settingsText, "text redo survives appearance changes")
                let foreground = settingsPane.textView.textColor!.usingColorSpace(.genericGray)!.whiteComponent
                try check(abs(foreground - 0.68) < 0.001, "brightness applies to existing text")
                @MainActor func command(_ key: String, code: UInt16) -> Bool {
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
                    return NSApp.mainMenu!.performKeyEquivalent(with: event)
                }
                try check(command("=", code: 24) && fontSize == 19.3, "Command-plus temporarily zooms above the chosen default")
                try check(preferences.defaultFontSize == 18.3, "zoom does not change the default font size")
                try check(command("0", code: 29) && fontSize == 18.3, "Command-zero resets to the chosen default")
                let typingColor = settingsPane.textView.typingAttributes[.foregroundColor] as! NSColor
                try check(abs(typingColor.usingColorSpace(.genericGray)!.whiteComponent - 0.68) < 0.001,
                    "zoom preserves brightness for newly typed text")
                updated.showsLineNumbers = true
                applyPreferences(updated)
                try check(settingsPane.scroll.rulersVisible && settingsPane.scroll.contentView.contentInsets.left > 0,
                    "showing line numbers restores the gutter")
                try check(settingsPane.scroll.convert(.zero, from: settingsPane.textView).x >= settingsPane.lineNumbers.frame.maxX,
                    "restored gutter stays beside editable text")
                try check(settingsPane.lineNumbers.lines.starts.count == settingsText.components(separatedBy: "\n").count,
                    "line numbering remains correct after toggling")
                newTab(nil)
                let inheritedPane = editors[currentID!]!
                try check(inheritedPane.textView.font?.pointSize == 18.3 && inheritedPane.scroll.rulersVisible,
                    "new tabs inherit font size and line number visibility")
                try check(abs(inheritedPane.textView.textColor!.usingColorSpace(.genericGray)!.whiteComponent - 0.68) < 0.001,
                    "new tabs inherit brightness")
                try check(command(",", code: 43) && settingsController?.window?.isVisible == true,
                    "Command-comma opens Settings")
                let firstController = settingsController
                try check(command(",", code: 43) && settingsController === firstController,
                    "Settings reuses a single window")
                // Key-window routing is checked in the active preview; this test app is inactive.
                let openIDsBeforeClose = store.session.openIDs
                settingsController?.window?.performClose(nil)
                try check(settingsController?.window?.isVisible == false, "Settings closes normally")
                try check(store.session.openIDs == openIDsBeforeClose, "closing Settings leaves notes open")
                applyPreferences(oldPreferences)
                // Find uses the real text system and disposable notes, including native undo.
                newTab(nil)
                let findID = currentID!
                let findPane = editors[findID]!
                let findView = findPane.textView
                let fixture = "📝 Cat cat CAT\nname=Alice\nname=Bob\n"
                findView.insertText(fixture, replacementRange: findView.selectedRange())
                findView.setSelectedRange(NSRange(location: 0, length: 0))
                // AppKit can intercept synthetic Find key equivalents in an inactive app.
                // Check the binding and dispatch its menu action; physical Command-F is also
                // verified in the isolated active preview.
                let findMenu = NSApp.mainMenu!.items.first { $0.title == "Edit" }!.submenu!
                let findItem = findMenu.items.first { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == .command }!
                let findHandled = NSApp.sendAction(findItem.action!, to: findItem.target, from: findItem)
                try check(findHandled && findController.isVisible, "Command-F menu binding opens custom bottom find panel")
                @MainActor func waitForFind() async throws {
                    let deadline = Date().addingTimeInterval(5)
                    while findController.isSearching && Date() < deadline {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    try check(!findController.isSearching, "live search finishes")
                }
                @MainActor func search(_ text: String, regex: Bool = false, sensitive: Bool = false, all: Bool = false) async throws {
                    findController.panel.findField.stringValue = text
                    findController.panel.regexButton.state = regex ? .on : .off
                    findController.panel.caseButton.state = sensitive ? .on : .off
                    findController.panel.allButton.state = all ? .on : .off
                    findController.optionsChanged()
                    try await waitForFind()
                }
                try await search("cat")
                try check(findController.control(findController.panel.findField, textView: findView, doCommandBy: #selector(NSResponder.insertTab(_:)))
                    && findController.panel.replaceField.currentEditor() != nil, "Tab from Find focuses replacement field")
                try check(findController.control(findController.panel.replaceField, textView: findView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
                    && findController.panel.findField.currentEditor() != nil, "Shift-Tab from Replace focuses find field")
                try check(findController.results?.matches.count == 3, "live find previews every case-insensitive match")
                try check(findView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 3, effectiveRange: nil) != nil,
                    "live preview uses temporary highlighting")
                try check(!findPane.dirty || findView.string == fixture, "preview does not alter note text")
                try flush()
                try await search("cat", sensitive: true)
                try check(findController.results?.matches.count == 1 && !findPane.dirty, "case toggle refreshes matches without dirtying note")
                findController.find()
                try check(findView.selectedRange() == NSRange(location: 7, length: 3), "Find selects the next matching range")
                try await search("cat")
                findController.navigate()
                try check(findView.selectedRange().location == 11, "Find Next advances from selected match")
                findController.navigate()
                try check(findView.selectedRange().location == 3, "Find Next wraps at end of note")
                findController.navigate(backwards: true)
                try check(findView.selectedRange().location == 11, "Find Previous wraps at start of note")
                try await search("cat", all: true)
                findController.find()
                try check(findView.selectedRanges.count == 3 && findController.panel.findButton.title == "Find All", "All selects all matches and changes action labels")
                try await search("name=(\\w+)", regex: true, all: true)
                findController.panel.replaceField.stringValue = "$1: $0\\n"
                findView.breakUndoCoalescing()
                findController.replace()
                try await waitForFind()
                let replacedFixture = "📝 Cat cat CAT\nAlice: name=Alice\n\nBob: name=Bob\n\n"
                try check(findView.string == replacedFixture && findPane.dirty, "Replace All expands regex captures and escapes through native editing")
                try check(findPane.lineNumbers.lines.starts == LogicalLines(replacedFixture).starts, "bulk replacement keeps incremental line numbers correct")
                findView.undoManager?.undo()
                try await waitForFind()
                try check(findView.string == fixture, "one undo restores the complete Replace All operation")
                findView.undoManager?.redo()
                try await waitForFind()
                try check(findView.string == replacedFixture, "redo reapplies the complete Replace All operation")
                findView.undoManager?.undo()
                try await waitForFind()
                try await search("cat")
                findController.panel.replaceField.stringValue = "dog"
                findView.setSelectedRange(NSRange(location: 0, length: 0))
                findController.replace()
                try check(findView.string == fixture && findView.selectedRange().location == 3, "Replace first finds a match when selection does not match")
                findController.replace()
                try await waitForFind()
                try check(findView.string == "📝 dog cat CAT\nname=Alice\nname=Bob\n" && findView.selectedRange().location == 7,
                    "Replace changes one match and selects the next")
                findView.undoManager?.undo()
                try await waitForFind()
                try check(findView.string == fixture, "single replacement is undoable independently")
                try await search("(", regex: true)
                try check(findController.results == nil && !findController.panel.replaceButton.isEnabled && findController.panel.status.stringValue.contains("Invalid regex"),
                    "invalid regex appears inline and disables replacement")
                findController.replace()
                try check(findView.string == fixture, "invalid regex cannot change the note")
                try await search("name=(\\w+)", regex: true)
                findController.panel.replaceField.stringValue = "$9"
                findController.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: findController.panel.replaceField))
                try check(!findController.panel.replaceButton.isEnabled && findController.panel.status.stringValue.contains("No capture group"),
                    "invalid replacement references appear inline")
                try await search("$", regex: true, all: true)
                findController.find()
                try check(!findView.selectedRanges.isEmpty && !(findView as! EditorTextView).zeroWidthFindLocations.isEmpty,
                    "Find All handles empty regex matches with visible markers")
                findController.panel.replaceField.stringValue = "!"
                findController.replace()
                try await waitForFind()
                try check(findView.string.contains("CAT!\n") && findView.string.hasSuffix("!"), "Replace All handles zero-width line and end-of-note matches")
                findView.undoManager?.undo()
                try await waitForFind()
                try check(findView.string == fixture, "zero-width Replace All undoes in one step")
                try await search("cat")
                let priorEditor = findView
                newTab(nil)
                try await waitForFind()
                try check(findController.isVisible && findController.results?.matches.isEmpty == true, "open find panel follows newly selected note")
                try switchTab(findID)
                try await waitForFind()
                try check(editors[findID]?.textView === priorEditor && findController.results?.matches.count == 3, "switching back retains editor and refreshes find preview")
                findController.panel.findField.stringValue = "never matches"
                findController.refresh()
                findController.panel.findField.stringValue = "cat"
                findController.refresh()
                try await waitForFind()
                try check(findController.results?.query.text == "cat" && findController.results?.matches.count == 3, "obsolete asynchronous searches cannot overwrite newer results")
                let panel = findController.panel
                for width: CGFloat in [420, 960] {
                    panel.setFrameSize(NSSize(width: width, height: FindPanel.height))
                    panel.layoutSubtreeIfNeeded()
                    try check(panel.findField.frame.maxX < panel.findButton.frame.minX && panel.findButton.frame.maxX < panel.regexButton.frame.minX && panel.allButton.frame.maxX <= width,
                        "find controls fit window width \(Int(width))")
                }
                try check(findController.control(panel.findField, textView: findView, doCommandBy: #selector(NSResponder.cancelOperation(_:))) && !findController.isVisible,
                    "Escape in find field closes the panel")
                try check(findView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 3, effectiveRange: nil) == nil,
                    "closing find clears preview highlighting")
                showFind()
                try await waitForFind()
                findView.cancelOperation(nil)
                try check(!findController.isVisible, "Escape in editor also closes the find panel")
                newTab(nil)
                let occurrenceID = currentID!
                let occurrencePane = editors[occurrenceID]!
                let occurrenceView = occurrencePane.textView
                let occurrenceFixture = "📝 KSHA ksha KSHA KSHA-long\na.b aXb a.b\n"
                occurrenceView.insertText(occurrenceFixture, replacementRange: occurrenceView.selectedRange())
                occurrencePane.layoutEditor()
                try check(occurrenceView.frame.origin == .zero, "short notes stay anchored at the top of the editor")
                occurrenceView.breakUndoCoalescing()
                try flush()
                occurrenceView.undoManager?.removeAllActions() // Fixture creation is not part of the editing action under test.
                @MainActor func waitForOccurrences() async throws {
                    // Native undo groups close at the next event-loop turn, even when
                    // no selection remains to trigger a background matching job.
                    try await Task.sleep(nanoseconds: 10_000_000)
                    let deadline = Date().addingTimeInterval(5)
                    while occurrenceController.isSearching && Date() < deadline {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    try check(!occurrenceController.isSearching, "selection matching finishes")
                }
                occurrenceView.setSelectedRange(NSRange(location: 13, length: 4))
                try await waitForOccurrences()
                try check(occurrenceController.matches?.ranges.map(\.location) == [3, 13, 18] && !findController.isVisible,
                    "selected text highlights matching case-sensitive occurrences without Find")
                try check(occurrenceView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 3, effectiveRange: nil) != nil
                    && occurrenceView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 8, effectiveRange: nil) == nil,
                    "selection preview highlights exact repeats but not different case")
                try check(!occurrencePane.dirty && occurrenceView.string == occurrenceFixture,
                    "occurrence highlighting does not dirty or change the note")
                let occurrenceItem = findMenu.items.first { $0.keyEquivalent == "d" && $0.keyEquivalentModifierMask == .command }!
                window.makeFirstResponder(occurrenceView)
                try check(NSApp.sendAction(occurrenceItem.action!, to: occurrenceItem.target, from: occurrenceItem), "Command-D menu binding dispatches select next occurrence")
                try await waitForOccurrences()
                try check(occurrenceView.selectedRanges.map(\.rangeValue.location) == [13, 18], "Command-D adds the next occurrence and keeps the first")
                selectNextOccurrence()
                try check(occurrenceView.selectedRanges.map(\.rangeValue.location) == [3, 13, 18], "Command-D wraps and retains all earlier selections")
                selectNextOccurrence()
                try check(occurrenceView.selectedRanges.count == 3 && !findController.isVisible, "Command-D stops adding when all occurrences are selected")
                occurrenceView.setSelectedRange(NSRange(location: 13, length: 4))
                let allOccurrencesItem = findMenu.items.first { $0.keyEquivalent == "d" && $0.keyEquivalentModifierMask == [.command, .shift] }!
                try check(NSApp.sendAction(allOccurrencesItem.action!, to: allOccurrencesItem.target, from: allOccurrencesItem), "Command-Shift-D menu binding dispatches select all occurrences")
                try await waitForOccurrences()
                try check((occurrenceView as! EditorTextView).editingSelectedRanges.map(\.rangeValue.location) == [3, 13, 18] && !findController.isVisible,
                    "Command-Shift-D selects every exact occurrence without opening Find")
                selectAllOccurrences()
                try check((occurrenceView as! EditorTextView).editingSelectedRanges.count == 3 && !occurrencePane.dirty,
                    "select all occurrences is repeatable and does not alter note contents")
                occurrenceView.setSelectedRange(NSRange(location: 4, length: 0))
                selectAllOccurrences()
                try await waitForOccurrences()
                try check((occurrenceView as! EditorTextView).editingSelectedRanges.map(\.rangeValue.location) == [3, 13, 18],
                    "Command-Shift-D from a caret selects its word and every occurrence while matching is pending")
                occurrenceView.insertText("item", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await waitForOccurrences()
                try check(occurrenceView.string == "📝 item ksha item item-long\na.b aXb a.b\n", "native typing replaces every selected occurrence")
                occurrenceView.undoManager?.undo()
                try await waitForOccurrences()
                try check(occurrenceView.string == occurrenceFixture, "one undo restores multi-selection typing")
                occurrenceView.undoManager?.redo()
                try await waitForOccurrences()
                try check(occurrenceView.string == "📝 item ksha item item-long\na.b aXb a.b\n", "redo reapplies multi-selection typing")
                occurrenceView.undoManager?.undo()
                try await waitForOccurrences()
                occurrenceView.setSelectedRange(NSRange(location: 4, length: 0))
                try await waitForOccurrences()
                selectNextOccurrence()
                try await waitForOccurrences()
                try check(occurrenceView.selectedRange() == NSRange(location: 3, length: 4), "Command-D at a caret first selects the native word")
                selectNextOccurrence()
                try await waitForOccurrences()
                try check(occurrenceView.selectedRanges.count == 2, "a second Command-D adds a matching word")
                occurrenceView.cancelOperation(nil)
                try check(occurrenceView.selectedRanges.count == 1, "Escape exits multiple selections without opening Find")
                occurrenceView.setSelectedRange(NSRange(location: 0, length: 0))
                try await waitForOccurrences()
                try check(occurrenceController.matches == nil
                    && occurrenceView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 3, effectiveRange: nil) == nil,
                    "clicking away clears occurrence highlights")
                occurrenceView.setSelectedRange(NSRange(location: 3, length: 4))
                selectNextOccurrence()
                selectNextOccurrence()
                try await waitForOccurrences()
                try check(occurrenceView.selectedRanges.count == 3, "rapid Command-D presses queue while matching runs")
                showFind()
                try await waitForFind()
                try check(findController.results?.matches.count == 4 && occurrenceController.matches == nil,
                    "Find takes over highlighting and retains its independent case-insensitive behavior")
                findController.close()
                try await waitForOccurrences()
                try check(occurrenceController.matches?.ranges.count == 3, "closing Find restores exact selection matching")
                newTab(nil)
                try await waitForOccurrences()
                try check(occurrenceController.matches == nil, "switching to an empty note clears occurrence state")
                try switchTab(occurrenceID)
                try await waitForOccurrences()
                try check(editors[occurrenceID]?.textView === occurrenceView && occurrenceView.selectedRanges.count == 3,
                    "tab switches retain the editor and its multiple selections")
                try check(occurrenceController.matches?.ranges.count == 3, "returning to a note restores occurrence preview")
                newTab(nil)
                let multiPane = editors[currentID!]!
                let multiView = multiPane.textView
                multiView.insertText("🐱 a 🐱", replacementRange: multiView.selectedRange())
                multiView.selectedRanges = [NSValue(range: NSRange(location: 0, length: 2)), NSValue(range: NSRange(location: 5, length: 2))]
                multiView.insertText("xy", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await waitForOccurrences()
                try check(multiView.string == "xy a xy" && (multiView as! EditorTextView).editingSelectedRanges.count == 2, "multi-selection replacement retains both insertion points")
                multiView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await waitForOccurrences()
                try check(multiView.string == "xy! a xy!", "continued typing inserts at every caret")
                multiView.undoManager?.removeAllActions()
                multiView.deleteBackward(nil)
                try await waitForOccurrences()
                try check(multiView.string == "xy a xy", "Backspace deletes at every caret")
                multiView.undoManager?.undo()
                try await waitForOccurrences()
                try check(multiView.string == "xy! a xy!", "multi-caret deletion is undoable in one step")
                multiView.undoManager?.redo()
                try await waitForOccurrences()
                try check(multiView.string == "xy a xy", "multi-caret deletion can be redone")
                multiView.setSelectedRange(NSRange(location: 0, length: (multiView.string as NSString).length))
                multiView.insertText("🐱 a 🐱", replacementRange: multiView.selectedRange())
                multiView.undoManager?.removeAllActions()
                (multiView as! EditorTextView).setEditingSelectedRanges([NSValue(range: NSRange(location: 2, length: 0)), NSValue(range: NSRange(location: 7, length: 0))])
                multiView.deleteBackward(nil)
                try await waitForOccurrences()
                try check(multiView.string == " a ", "multi-caret Backspace removes whole Unicode characters")
                multiView.undoManager?.undo()
                try await waitForOccurrences()
                (multiView as! EditorTextView).setEditingSelectedRanges([NSValue(range: NSRange(location: 0, length: 0)), NSValue(range: NSRange(location: 5, length: 0))])
                multiView.deleteForward(nil)
                try await waitForOccurrences()
                try check(multiView.string == " a ", "multi-caret forward delete removes whole Unicode characters")
                multiView.setSelectedRange(NSRange(location: 0, length: (multiView.string as NSString).length))
                multiView.insertText("aaaa", replacementRange: multiView.selectedRange())
                (multiView as! EditorTextView).setEditingSelectedRanges([NSValue(range: NSRange(location: 0, length: 2)), NSValue(range: NSRange(location: 2, length: 2))])
                multiView.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await waitForOccurrences()
                try check(multiView.string == "bb", "adjacent selections each receive their own replacement")
                // Save and restore every pasteboard type so tests leave the user's clipboard intact.
                let clipboard = NSPasteboard.general
                let clipboardItems = clipboard.pasteboardItems?.map { item -> NSPasteboardItem in
                    let copy = NSPasteboardItem()
                    for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                    return copy
                } ?? []
                do {
                    defer { clipboard.clearContents(); if !clipboardItems.isEmpty { clipboard.writeObjects(clipboardItems) } }
                    clipboard.clearContents()
                    clipboard.setString("p\nq", forType: .string)
                    (multiView as! EditorTextView).setEditingSelectedRanges([NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 1, length: 1))])
                    multiView.paste(nil)
                    try await waitForOccurrences()
                    try check(multiView.string == "p\nqp\nq", "paste inserts multiline text into every selection")
                }
                try check(multiPane.lineNumbers.lines.starts == LogicalLines(multiView.string).starts,
                    "multi-selection edits preserve the incremental line index")
                try flush()
                try check(try store.text(currentID!) == multiView.string, "multi-selection edits persist through normal autosave storage")
                try flush()
                // Syntax is a visual overlay over the same native plain-text and undo system.
                newTab(nil)
                let syntaxID = currentID!, syntaxPane = editors[currentID!]!, syntaxView = editors[currentID!]!.textView
                @MainActor func waitForSyntax(_ target: EditorPane) async throws {
                    let deadline = Date().addingTimeInterval(5)
                    while target.syntax.isHighlighting && Date() < deadline {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    try check(!target.syntax.isHighlighting, "automatic syntax detection finishes")
                }
                let yamlPaste = "# Deployment\nservice: api\nenabled: true\nreplicas: 3\n"
                do {
                    let savedItems = clipboard.pasteboardItems?.map { item -> NSPasteboardItem in
                        let copy = NSPasteboardItem()
                        for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                        return copy
                    } ?? []
                    defer { clipboard.clearContents(); if !savedItems.isEmpty { clipboard.writeObjects(savedItems) } }
                    clipboard.clearContents()
                    clipboard.setString(yamlPaste, forType: .string)
                    syntaxView.paste(nil)
                    try await waitForSyntax(syntaxPane)
                    try check(syntaxPane.syntax.language == .yaml && syntaxView.string == yamlPaste, "native paste automatically detects YAML without changing source")
                    syntaxView.selectAll(nil)
                    syntaxView.copy(nil)
                    try check(clipboard.string(forType: .string) == yamlPaste, "copying highlighted text preserves plain source")
                }
                let keyOffset = (yamlPaste as NSString).range(of: "service").location
                @MainActor func syntaxColor(_ offset: Int) -> NSColor? {
                    syntaxView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor
                }
                try check(syntaxColor(keyOffset) != nil && syntaxColor(keyOffset) != syntaxView.textColor, "YAML keys receive temporary foreground colors")
                try check(syntaxView.textStorage?.attribute(.foregroundColor, at: keyOffset, effectiveRange: nil) as? NSColor == syntaxView.textColor,
                    "syntax colors never enter stored text attributes")
                try flush()
                syntaxView.setSelectedRange(NSRange(location: keyOffset, length: 7))
                let syntaxSelection = syntaxView.selectedRange()
                let previousColor = syntaxColor(keyOffset)
                syntaxPane.applyAppearance(brightness: 0.9, showsLineNumbers: true)
                syntaxPane.applyFont(size: 16)
                try check(syntaxColor(keyOffset) != nil && syntaxColor(keyOffset) != previousColor,
                    "syntax palette follows brightness and survives font changes")
                try check(!syntaxPane.dirty && syntaxView.selectedRange() == syntaxSelection && syntaxView.string == yamlPaste,
                    "syntax appearance preserves selection and does not dirty notes")
                try check(syntaxView.typingAttributes[.foregroundColor] as? NSColor == syntaxView.textColor,
                    "typing attributes retain the plain foreground color")
                showFind()
                try await search("service")
                try check(syntaxColor(keyOffset) != nil && syntaxView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: keyOffset, effectiveRange: nil) != nil,
                    "find highlights coexist with syntax colors")
                syntaxView.cancelOperation(nil)
                try check(syntaxColor(keyOffset) != nil && syntaxView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: keyOffset, effectiveRange: nil) == nil,
                    "closing Find preserves syntax colors")
                syntaxView.setSelectedRange(NSRange(location: 0, length: 0))
                try switchTab(occurrenceID)
                try switchTab(syntaxID)
                try check(editors[syntaxID] === syntaxPane && syntaxColor(keyOffset) != nil,
                    "tab switching retains syntax, editor and native undo manager")
                syntaxView.undoManager?.undo()
                try await waitForSyntax(syntaxPane)
                try check(syntaxView.string.isEmpty && syntaxPane.syntax.language == .plain,
                    "highlighting does not add undo actions after paste")
                syntaxView.undoManager?.redo()
                try await waitForSyntax(syntaxPane)
                try check(syntaxView.string == yamlPaste && syntaxPane.syntax.language == .yaml,
                    "redo re-detects and highlights pasted YAML")
                // Programmatic test edits can share an AppKit event undo group. Paste undo/redo
                // is already checked; isolate this next native typing action from that fixture.
                syntaxView.undoManager?.removeAllActions()
                syntaxView.setSelectedRange(NSRange(location: (syntaxView.string as NSString).length, length: 0))
                syntaxView.breakUndoCoalescing()
                syntaxView.insertText("\n# trailing comment", replacementRange: NSRange(location: (syntaxView.string as NSString).length, length: 0))
                try check(syntaxPane.syntax.isHighlighting && syntaxColor(keyOffset) != nil,
                    "existing syntax stays visible while an edit is being analyzed")
                try await waitForSyntax(syntaxPane)
                syntaxView.undoManager?.undo()
                try await waitForSyntax(syntaxPane)
                try check(syntaxView.string == yamlPaste, "syntax refresh leaves native typing undo intact")
                let markdownPaste = "# Plan 📝\n\n- Ship **today**\n\nUse `code` and [docs](https://example.test).\n"
                syntaxView.breakUndoCoalescing()
                syntaxView.insertText(markdownPaste, replacementRange: NSRange(location: 0, length: (syntaxView.string as NSString).length))
                try await waitForSyntax(syntaxPane)
                try check(syntaxPane.syntax.language == .markdown && syntaxColor(0) != nil,
                    "replacing YAML with Markdown automatically switches syntax")
                syntaxView.insertText("enabled: true", replacementRange: NSRange(location: 0, length: (syntaxView.string as NSString).length))
                syntaxView.insertText("A plain note", replacementRange: NSRange(location: 0, length: (syntaxView.string as NSString).length))
                try await waitForSyntax(syntaxPane)
                try check(syntaxPane.syntax.language == .plain && syntaxColor(0) == nil,
                    "rapid format changes discard stale syntax jobs and clear colors")
                syntaxView.insertText(markdownPaste, replacementRange: NSRange(location: 0, length: (syntaxView.string as NSString).length))
                try await waitForSyntax(syntaxPane)
                try flush()
                try check(try store.text(syntaxID) == markdownPaste, "highlighted notes persist as exact UTF-8 source")
                try close(syntaxID)
                try restore(syntaxID)
                let restoredSyntaxPane = editors[syntaxID]!
                try await waitForSyntax(restoredSyntaxPane)
                try check(restoredSyntaxPane.syntax.language == .markdown && restoredSyntaxPane.textView.string == markdownPaste,
                    "restored notes detect syntax from their plain-text content")
                newTab(nil)
                let scriptID = currentID!, scriptPane = editors[currentID!]!, scriptView = editors[currentID!]!.textView
                let typeScriptPaste = "interface User { name: string; }\nconst greet = (user: User): string => `Hello ${user.name}`;\n"
                do {
                    let savedItems = clipboard.pasteboardItems?.map { item -> NSPasteboardItem in
                        let copy = NSPasteboardItem()
                        for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                        return copy
                    } ?? []
                    defer { clipboard.clearContents(); if !savedItems.isEmpty { clipboard.writeObjects(savedItems) } }
                    clipboard.clearContents()
                    clipboard.setString(typeScriptPaste, forType: .string)
                    scriptView.paste(nil)
                    try await waitForSyntax(scriptPane)
                    try check(scriptPane.syntax.language == .javascript && scriptView.string == typeScriptPaste,
                        "pasting TypeScript automatically selects the shared JS/TS format")
                    scriptView.selectAll(nil)
                    scriptView.copy(nil)
                    try check(clipboard.string(forType: .string) == typeScriptPaste, "copying TypeScript retains source including template interpolation")
                }
                @MainActor func scriptColor(_ needle: String) -> NSColor? {
                    let offset = (scriptView.string as NSString).range(of: needle).location
                    return scriptView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor
                }
                let keywordColor = scriptColor("interface"), typeColor = scriptColor("User"), stringColor = scriptColor("Hello")
                try check(keywordColor != nil && typeColor != nil && stringColor != nil
                    && keywordColor != typeColor && stringColor != typeColor, "TypeScript keywords, types and template strings have distinct colors")
                let expressionOffset = (typeScriptPaste as NSString).range(of: "user.name").location
                try check(scriptView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: expressionOffset, effectiveRange: nil) == nil,
                    "template expressions retain code colors instead of inheriting the surrounding string")
                try flush()
                scriptView.setSelectedRange(NSRange(location: 0, length: 9))
                let scriptSelection = scriptView.selectedRange()
                scriptPane.applyAppearance(brightness: 0.82, showsLineNumbers: true)
                scriptPane.applyFont(size: 15)
                try check(scriptColor("interface") != nil && scriptColor("interface") != keywordColor
                    && scriptView.selectedRange() == scriptSelection && !scriptPane.dirty,
                    "JS/TS appearance changes preserve selection and autosave state")
                showFind()
                try await search("User")
                let typeOffset = (typeScriptPaste as NSString).range(of: "User").location
                try check(scriptColor("User") != nil && scriptView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: typeOffset, effectiveRange: nil) != nil,
                    "Find and TypeScript token colors coexist")
                scriptView.cancelOperation(nil)
                try switchTab(syntaxID)
                try switchTab(scriptID)
                try check(editors[scriptID] === scriptPane && scriptColor("interface") != nil,
                    "JS/TS tab switching retains its native editor and colors")
                scriptView.undoManager?.undo()
                try await waitForSyntax(scriptPane)
                try check(scriptView.string.isEmpty && scriptPane.syntax.language == .plain,
                    "one native undo removes TypeScript paste without formatting undo actions")
                scriptView.undoManager?.redo()
                try await waitForSyntax(scriptPane)
                try check(scriptView.string == typeScriptPaste && scriptPane.syntax.language == .javascript,
                    "native redo restores TypeScript source and syntax")
                let javaScriptPaste = "const enabled = true;\nconsole.log(`ready: ${enabled}`, /ready/gi);\n"
                scriptView.setSelectedRange(NSRange(location: 0, length: (scriptView.string as NSString).length))
                scriptView.insertText(javaScriptPaste, replacementRange: scriptView.selectedRange())
                try await waitForSyntax(scriptPane)
                try check(scriptPane.syntax.language == .javascript && scriptColor("const") != nil
                    && scriptColor("log") != nil, "JavaScript uses the same format and colors declarations and function calls")
                scriptView.insertText("name: api\nenabled: true", replacementRange: NSRange(location: 0, length: (scriptView.string as NSString).length))
                try await waitForSyntax(scriptPane)
                try check(scriptPane.syntax.language == .yaml, "replacing JavaScript with YAML automatically changes format")
                scriptView.insertText(javaScriptPaste, replacementRange: NSRange(location: 0, length: (scriptView.string as NSString).length))
                scriptView.insertText("An ordinary note", replacementRange: NSRange(location: 0, length: (scriptView.string as NSString).length))
                try await waitForSyntax(scriptPane)
                try check(scriptPane.syntax.language == .plain && scriptView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil,
                    "obsolete JS/TS detection cannot recolor a newer plain note")
                scriptView.insertText(javaScriptPaste, replacementRange: NSRange(location: 0, length: (scriptView.string as NSString).length))
                try await waitForSyntax(scriptPane)
                try flush()
                try check(try store.text(scriptID) == javaScriptPaste, "JavaScript highlighting persists only exact plain UTF-8 source")
                try close(scriptID)
                try restore(scriptID)
                try await waitForSyntax(editors[scriptID]!)
                try check(editors[scriptID]!.syntax.language == .javascript, "restored JavaScript notes automatically regain syntax colors")
                let syntaxMenu = NSApp.mainMenu!.item(withTitle: "Syntax")!.submenu!
                @MainActor func chooseSyntax(_ title: String) {
                    let item = syntaxMenu.items.first { $0.title.hasPrefix(title) }!
                    syntaxMenu.update()
                    NSApp.sendAction(item.action!, to: item.target, from: item)
                }
                chooseSyntax("YAML")
                try await waitForSyntax(editors[scriptID]!)
                try check(editors[scriptID]!.syntax.language == .yaml && store.records[scriptID]?.syntaxOverride == .yaml,
                    "Syntax menu forces a format over detection")
                syntaxMenu.update()
                try check(syntaxMenu.items.first { $0.title == "YAML" }?.state == .on, "Syntax menu checks the chosen format")
                try close(scriptID)
                try restore(scriptID)
                try await waitForSyntax(editors[scriptID]!)
                try check(editors[scriptID]!.syntax.language == .yaml, "chosen format survives archiving and restoring")
                try check(["Plain Text", "Bash", "CSS", "HTML", "JavaScript / TypeScript", "JSON", "Markdown", "XML", "YAML"].allSatisfy { title in
                    syntaxMenu.items.contains { $0.title == title } }, "Syntax menu lists every format")
                chooseSyntax("HTML")
                try await waitForSyntax(editors[scriptID]!)
                try check(editors[scriptID]!.syntax.language == .html, "Syntax menu can force HTML")
                chooseSyntax("CSS")
                try await waitForSyntax(editors[scriptID]!)
                try check(editors[scriptID]!.syntax.language == .css, "Syntax menu can force CSS")
                chooseSyntax("JSON")
                try await waitForSyntax(editors[scriptID]!)
                try check(editors[scriptID]!.syntax.language == .json && store.records[scriptID]?.syntaxOverride == .json,
                    "Syntax menu can force JSON")
                chooseSyntax("Plain Text")
                try await waitForSyntax(editors[scriptID]!)
                try check(editors[scriptID]!.syntax.language == .plain && editors[scriptID]!.textView.layoutManager?
                    .temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil, "choosing Plain Text removes colors")
                chooseSyntax("Detect Automatically")
                try await waitForSyntax(editors[scriptID]!)
                syntaxMenu.update()
                try check(editors[scriptID]!.syntax.language == .javascript && store.records[scriptID]?.syntax == nil
                    && syntaxMenu.items.first!.title.contains("JavaScript"), "Detect Automatically returns to the detected format")
                // Open real file fixtures only inside the disposable test folder.
                let jsonURL = store.root.appendingPathComponent("example.json")
                let jsonText = "{\"name\":\"🧩\",\"enabled\":true,\"count\":42}"
                try jsonText.write(to: jsonURL, atomically: true, encoding: .utf8)
                try openFile(jsonURL)
                let jsonID = currentID!, jsonPane = editors[currentID!]!
                try await waitForSyntax(jsonPane)
                let jsonManager = jsonPane.textView.layoutManager!
                let keyColor = jsonManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 2, effectiveRange: nil) as? NSColor
                let valueOffset = (jsonText as NSString).range(of: "🧩").location
                let valueColor = jsonManager.temporaryAttribute(.foregroundColor, atCharacterIndex: valueOffset, effectiveRange: nil) as? NSColor
                try check(jsonPane.syntax.language == .json && keyColor != nil && valueColor != nil && keyColor != valueColor,
                    "opened JSON colors keys and string values differently")
                jsonPane.textView.insertText("43", replacementRange: (jsonText as NSString).range(of: "42"))
                try await waitForSyntax(jsonPane)
                try flush()
                try check(try String(contentsOf: jsonURL, encoding: .utf8) == jsonText, "JSON autosave preserves the external source")
                jsonPane.textView.undoManager?.undo()
                try await waitForSyntax(jsonPane)
                try check(jsonPane.textView.string == jsonText, "JSON highlighting preserves native edit undo")
                jsonPane.textView.undoManager?.redo()
                try await waitForSyntax(jsonPane)
                try store.setSyntax(jsonID, language: .json)
                try close(jsonID)
                try restore(jsonID)
                try await waitForSyntax(editors[jsonID]!)
                try check(editors[jsonID]!.syntax.language == .json && store.records[jsonID]?.syntaxOverride == .json,
                    "JSON and its manual choice survive archive restoration")
                let plistURL = store.root.appendingPathComponent("example.plist")
                let plistText = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Name</key><string>Untitled</string></dict></plist>"
                try plistText.write(to: plistURL, atomically: true, encoding: .utf8)
                try openFile(plistURL)
                let plistID = currentID!
                try await waitForSyntax(editors[plistID]!)
                try check(editors[plistID]!.syntax.language == .xml && editors[plistID]!.textView.string == plistText,
                    "XML plist files open as unchanged XML source")
                let binaryURL = store.root.appendingPathComponent("binary.plist")
                let binaryData = try PropertyListSerialization.data(fromPropertyList: ["name": "Untitled"], format: .binary, options: 0)
                try binaryData.write(to: binaryURL)
                let beforeBinary = store.session.openIDs
                var binaryError = ""
                do { try openFile(binaryURL) } catch { binaryError = error.localizedDescription }
                try check(binaryError.contains("binary property list") && store.session.openIDs == beforeBinary && currentID == plistID,
                    "binary plists report a specific error without opening a text tab")
                try check(try Data(contentsOf: binaryURL) == binaryData, "rejecting a binary plist leaves its file intact")
                // Long notes color only the visible text and a margin, and repaint as they scroll.
                newTab(nil)
                let longID = currentID!, longPane = editors[currentID!]!, longView = editors[currentID!]!.textView
                let longNote = (0..<4000).map { "key\($0): value \($0)\n" }.joined()
                longView.insertText(longNote, replacementRange: NSRange(location: 0, length: 0))
                try await waitForSyntax(longPane)
                @MainActor func longColor(_ line: Int) -> NSColor? {
                    let offset = (longView.string as NSString).range(of: "key\(line):").location
                    return longView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor
                }
                @MainActor func scrollLong(to line: Int) async throws {
                    longView.scrollRangeToVisible((longView.string as NSString).range(of: "key\(line):"))
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try check(longPane.syntax.language == .yaml, "long YAML notes are detected")
                try await scrollLong(to: 0)
                try check(longColor(0) != nil && longColor(3999) == nil, "only text near the visible range carries syntax colors")
                try check(longColor(0) === longColor(1), "spans of one token kind share a single color object")
                try await scrollLong(to: 3999)
                try check(longColor(3999) != nil && longColor(0) == nil, "scrolling paints newly visible text and releases the rest")
                try await scrollLong(to: 2000)
                try check(longColor(2000) != nil && longColor(3999) == nil, "jumping to the middle paints it")
                longView.setSelectedRange((longView.string as NSString).range(of: "key2000:"))
                longView.undoManager?.removeAllActions()
                longView.breakUndoCoalescing()
                longView.insertText("renamed2000:", replacementRange: longView.selectedRange())
                try check(longPane.syntax.isHighlighting && longColor(2001) != nil, "visible colors stay while an edit is analyzed")
                try await waitForSyntax(longPane)
                let renamedOffset = (longView.string as NSString).range(of: "renamed2000:").location
                try check(longView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: renamedOffset, effectiveRange: nil) != nil
                    && longColor(2001) != nil, "edits in a long note are recolored where they happen")
                let beforeBrightness = longColor(2001)
                longPane.applyAppearance(brightness: 0.85, showsLineNumbers: true)
                try check(longColor(2001) != nil && longColor(2001) != beforeBrightness, "brightness repaints the visible range")
                try switchTab(syntaxID)
                try switchTab(longID)
                try check(editors[longID] === longPane && longColor(2001) != nil, "switching back to a long note keeps its visible colors")
                longView.undoManager?.undo()
                try await waitForSyntax(longPane)
                try check(longView.string == longNote, "visible-range painting leaves native undo intact")
                try flush()
                try check(try store.text(longID) == longNote && !longPane.dirty, "painting never dirties or alters the saved note")
                try close(longID)
                let savedFileURL = store.root.appendingPathComponent("opened-readme.md")
                try "# Opened".write(to: savedFileURL, atomically: true, encoding: .utf8)
                try openFile(savedFileURL)
                let openedID = currentID!
                try close(openedID)
                try check(store.records[openedID] == nil && !store.archived.contains { $0.id == openedID },
                    "closing an unchanged opened file skips the archive")
                closedTabs.removeAll()
                let keptID = try store.create(text: "Reopen me")
                let middleID = try store.create(text: "middle")
                try displaySelected()
                let orderBeforeClose = store.session.openIDs
                try close(keptID)
                try check(try reopenLastClosed() && currentID == keptID, "reopen restores the last closed note")
                try check(store.session.openIDs == orderBeforeClose, "reopened note returns to its old position")
                try openFile(savedFileURL)
                let reopenedFile = currentID!
                try close(reopenedFile)
                try close(middleID)
                try check(try reopenLastClosed() && currentID == middleID, "reopen walks back through closed tabs")
                try check(try reopenLastClosed() && store.records[currentID!]?.filePath == savedFileURL.standardizedFileURL.path
                    && store.session.openIDs.count == orderBeforeClose.count + 1, "reopen brings back an unchanged opened file from disk")
                // A keyboard-layout-translated event, so Shift reaches the menu as it does from real keys.
                let reopenKey = CGEvent(keyboardEventSource: nil, virtualKey: 17, keyDown: true)!
                reopenKey.flags = [.maskCommand, .maskShift]
                let reopenEvent = NSEvent(cgEvent: reopenKey)!
                for id in store.session.openIDs { try close(id) }
                let leftBlank = currentID!
                try check(store.session.openIDs == [leftBlank], "closing every tab leaves one blank note")
                try check(NSApp.mainMenu!.performKeyEquivalent(with: reopenEvent), "Command-Shift-T handled by menu")
                try check(store.session.openIDs.count == 1 && store.records[leftBlank] == nil && currentID != leftBlank,
                    "reopening replaces the blank note left by closing the last tab")
                for id in store.session.openIDs { try close(id) }
                let lastBlank = currentID!
                let lastBlankPane = editors[lastBlank]!
                let closeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
                window.orderFront(nil)
                try check(window.isVisible, "editor is visible before closing its only blank tab")
                try check(NSApp.mainMenu!.performKeyEquivalent(with: closeEvent), "Command-W handled by menu")
                try check(!window.isVisible, "Command-W hides the window for its only blank scratch note")
                try check(store.session.openIDs == [lastBlank] && editors[lastBlank] === lastBlankPane,
                    "hiding the last blank tab retains its note and native editor")
                try check(applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) && window.isVisible,
                    "Dock reopen shows the hidden editor window")
                try check(currentID == lastBlank && window.firstResponder === lastBlankPane.textView,
                    "Dock reopen focuses the retained editor")
                lastBlankPane.textView.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
                try flush()
                lastBlankPane.textView.insertText(" \n\t", replacementRange: NSRange(location: 0, length: 5))
                try check(NSApp.mainMenu!.performKeyEquivalent(with: closeEvent) && !window.isVisible,
                    "Command-W uses pending edits when the last note becomes whitespace only")
                try check(try store.text(lastBlank) == " \n\t" && !lastBlankPane.dirty,
                    "hiding flushes pending whitespace edits")
                _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                lastBlankPane.textView.insertText("keep", replacementRange: NSRange(location: 0, length: 3))
                try check(NSApp.mainMenu!.performKeyEquivalent(with: closeEvent) && window.isVisible,
                    "Command-W on a nonblank last note keeps the window visible")
                try check(try store.archived.contains { $0.id == lastBlank } && store.text(lastBlank) == "keep",
                    "Command-W archives pending content in the last note")
                let namedBlank = currentID!
                try store.rename(namedBlank, title: "Keep this empty note")
                try check(NSApp.mainMenu!.performKeyEquivalent(with: closeEvent) && window.isVisible
                    && store.archived.contains { $0.id == namedBlank },
                    "Command-W archives a named empty last note")
                newTab(nil)
                let extraBlank = currentID!
                try check(NSApp.mainMenu!.performKeyEquivalent(with: closeEvent) && window.isVisible
                    && store.session.openIDs.count == 1 && store.records[extraBlank] == nil,
                    "Command-W discards a blank tab normally when another tab remains")
                let report: [String: Any] = ["passed": true, "checks": checks]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: store.root.appendingPathComponent("smoke-results.json"))
                print(String(data: data, encoding: .utf8)!)
                NSApp.terminate(nil)
            } catch {
                let report: [String: Any] = ["passed": false, "checks": checks, "error": error.localizedDescription]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: store.root.appendingPathComponent("smoke-results.json"))
                    print(String(data: data, encoding: .utf8)!)
                }
                exit(1)
            }
        }
    }
}
