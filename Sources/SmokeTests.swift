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
