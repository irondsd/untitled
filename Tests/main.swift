import Foundation

var count = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try condition() else { throw NSError(domain: "NotesStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    count += 1
    print("PASS \(name)")
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("untitled-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
do {
    let store = try NotesStore(root: root)
    let first = store.session.selectedID!
    try check(store.session.openIDs.count == 1, "fresh storage starts with one blank note")
    let content = "Unicode 🧩 — café\n\tindented\r\nline endings preserved\n"
    try store.saveText(content, for: first)
    try store.rename(first, title: "  Research  ")
    try store.savePosition(first, location: 12, length: 4, offset: 88)
    let second = try store.create(text: "another note")
    try store.select(first)
    let loaded = try NotesStore(root: root)
    try check(loaded.session.openIDs == [first, second], "open order restored")
    try check(loaded.session.selectedID == first, "selected tab restored")
    try check(try loaded.text(first) == content, "text round-trips exactly")
    try check(loaded.records[first]?.displayTitle == "Research", "custom title restored and trimmed")
    try check(loaded.records[first]?.selectionLength == 4 && loaded.records[first]?.scrollOffset == 88, "cursor and scroll position restored")
    try loaded.archive(first)
    try check(loaded.session.selectedID == second, "close selects adjacent tab")
    try check(loaded.archived.map(\.id) == [first], "closed note listed in archive")
    try check(try loaded.text(first) == content, "close does not delete contents")
    try loaded.restore(first)
    try loaded.restore(first)
    try check(loaded.session.openIDs == [second, first], "restore retains ID and avoids duplicate tabs")
    try loaded.archive(first)
    try loaded.archive(second)
    try check(loaded.session.openIDs.count == 1, "closing the final tab creates a blank replacement")
    try check(loaded.archived.count == 2, "both original notes retained")
    let fresh = loaded.session.selectedID!
    try check(try loaded.text(fresh) == "", "replacement is blank")
    try loaded.rename(fresh, title: " ")
    try check(loaded.records[fresh]?.displayTitle == "untitled", "empty rename resets title")
    let external = root.appendingPathComponent("example.json")
    let fileNote = try loaded.create(text: "{\"hello\":true}", filePath: external.path)
    try check(loaded.records[fileNote]?.displayTitle == "example.json", "opened file uses filename")
    try check(loaded.records[fileNote]?.savedFileHash == NotesStore.hash("{\"hello\":true}"), "external file save state tracked")
    try loaded.saveText("changed local copy", for: fileNote)
    try check(!FileManager.default.fileExists(atPath: external.path), "autosave never overwrites the original external file")

    // Recover notes even when the session index cannot be decoded.
    try Data("broken index".utf8).write(to: root.appendingPathComponent("session.json"), options: .atomic)
    let indexRecovered = try NotesStore(root: root)
    try check(try indexRecovered.text(first) == content, "corrupt session cannot destroy note contents")
    try check(indexRecovered.archived.contains { $0.id == first }, "corrupt session preserves archive")

    // Recover text when metadata was lost or a save stopped before metadata creation.
    let orphan = UUID()
    let orphanText = "recovered orphan text"
    try orphanText.write(to: loaded.textURL(orphan), atomically: true, encoding: .utf8)
    let corrupt = UUID()
    try "still here".write(to: loaded.textURL(corrupt), atomically: true, encoding: .utf8)
    try Data("broken metadata".utf8).write(to: loaded.notesDirectory.appendingPathComponent("\(corrupt.uuidString).json"))
    let recovered = try NotesStore(root: root)
    try check(recovered.archived.contains { $0.id == orphan }, "orphan text recovered into archive")
    try check(try recovered.text(orphan) == orphanText, "orphan recovery preserves content")
    try check(recovered.archived.contains { $0.id == corrupt }, "corrupt metadata does not hide text")
    try recovered.restore(orphan)
    try recovered.saveSession()
    let afterRecovery = try NotesStore(root: root)
    try check(afterRecovery.session.openIDs.contains(orphan), "recovered note can be restored permanently")
    print("\n\(count) storage checks passed")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
