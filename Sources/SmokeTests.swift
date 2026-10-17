import AppKit

extension AppDelegate {
    /// Runs only against the explicitly supplied disposable data folder.
    func runSmokeTests() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            var checks: [String] = []
            func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
                guard try condition() else { throw NSError(domain: "SmokeTest", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
                checks.append(name)
            }
            do {
                try check(CommandLine.arguments.contains("--data-dir"), "isolated test storage")
                let first = currentID!
                let pane = editors[first]!
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
                try flush()
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
