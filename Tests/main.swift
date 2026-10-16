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
    let cleanup = try NotesStore(root: root.appendingPathComponent("cleanup-tests"))
    let blank = cleanup.session.selectedID!
    try cleanup.archive(blank)
    try check(cleanup.records[blank] == nil && !FileManager.default.fileExists(atPath: cleanup.textURL(blank).path), "closing an unnamed blank note discards its local files")
    try check(cleanup.archived.isEmpty && cleanup.session.openIDs.count == 1, "closing last blank note leaves a fresh note without an archive entry")
    let whitespace = try cleanup.create(text: " \t\r\n ")
    try cleanup.archive(whitespace)
    try check(cleanup.records[whitespace] == nil, "whitespace-only unnamed notes are discarded")
    let namedBlank = try cleanup.create()
    try cleanup.rename(namedBlank, title: "Keep this empty note")
    try cleanup.archive(namedBlank)
    try check(cleanup.archived.contains { $0.id == namedBlank }, "renamed blank notes are archived")
    let cleared = try cleanup.create(text: "used to contain something")
    try cleanup.saveText("", for: cleared)
    try cleanup.archive(cleared)
    try check(cleanup.records[cleared] == nil, "clearing an unnamed note makes it discardable")
    let protected = cleanup.session.selectedID!
    var rejected = false
    do { try cleanup.deleteArchived(protected) } catch { rejected = true }
    try check(rejected && cleanup.records[protected] != nil, "archive deletion cannot delete an open note")
    let beforeSession = cleanup.session.openIDs
    try cleanup.deleteArchived(namedBlank)
    try check(cleanup.records[namedBlank] == nil && cleanup.archived.isEmpty, "explicit deletion removes archived note from index")
    try check(!FileManager.default.fileExists(atPath: cleanup.textURL(namedBlank).path) &&
        !FileManager.default.fileExists(atPath: cleanup.notesDirectory.appendingPathComponent("\(namedBlank.uuidString).json").path), "explicit deletion removes both text and metadata")
    try check(cleanup.session.openIDs == beforeSession, "deletion leaves open tabs intact")
    let afterDelete = try NotesStore(root: cleanup.root)
    try check(afterDelete.records[namedBlank] == nil, "deleted note does not return after restart")
    let original = root.appendingPathComponent("empty-original.txt")
    try "".write(to: original, atomically: true, encoding: .utf8)
    let emptyFile = try cleanup.create(filePath: original.path)
    try cleanup.archive(emptyFile)
    try check(cleanup.archived.contains { $0.id == emptyFile }, "opened empty files remain recoverable")
    try cleanup.deleteArchived(emptyFile)
    try check(FileManager.default.fileExists(atPath: original.path), "deleting a local note never deletes its original external file")
    let interrupted = try cleanup.create(text: "pending explicit deletion")
    try cleanup.archive(interrupted)
    try Data().write(to: cleanup.notesDirectory.appendingPathComponent("\(interrupted.uuidString).deleted"))
    let resumed = try NotesStore(root: cleanup.root)
    try check(resumed.records[interrupted] == nil && !FileManager.default.fileExists(atPath: resumed.textURL(interrupted).path), "interrupted explicit deletion finishes without orphan recovery")

    for (text, expected) in [("", [0]), ("abc", [0]), ("a\nb\n", [0,2,4]),
                             ("a\r\nb", [0,3]), ("📝\nlast", [0,3]), ("a\u{2028}b", [0,2])] {
        try check(LogicalLines(text).starts == expected, "logical line offsets: \(String(reflecting: text))")
    }
    var seed: UInt64 = 0x7157
    func random(_ limit: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) % UInt64(max(1, limit)))
    }
    var text = ""
    var lines = LogicalLines(text)
    let replacements = ["", "a", "longer", "\n", "\r", "\r\n", "📝", "é", "\u{2028}", "a\nb\n"]
    for iteration in 0..<1500 {
        let positions = text.indices.map { $0.utf16Offset(in: text) } + [(text as NSString).length]
        let startIndex = random(positions.count)
        let endIndex = min(positions.count - 1, startIndex + random(5))
        let range = NSRange(location: positions[startIndex], length: positions[endIndex] - positions[startIndex])
        let replacement = replacements[random(replacements.count)]
        text = (text as NSString).replacingCharacters(in: range, with: replacement)
        let inserted = (replacement as NSString).length
        lines.edited(text as NSString, range: NSRange(location: range.location, length: inserted), changeInLength: inserted - range.length)
        guard lines.starts == LogicalLines(text).starts else {
            throw NSError(domain: "LineTests", code: iteration, userInfo: [NSLocalizedDescriptionKey: "Incremental line index mismatch at edit \(iteration): \(String(reflecting: text))"])
        }
    }
    try check(true, "1,500 incremental Unicode and newline edits match full line indexing")
    for range in [NSRange(location: 1, length: 1), NSRange(location: 2, length: 1)] {
        var index = LogicalLines("a\r\nb")
        let changed = ("a\r\nb" as NSString).replacingCharacters(in: range, with: "")
        index.edited(changed as NSString, range: NSRange(location: range.location, length: 0), changeInLength: -1)
        try check(index.starts == LogicalLines(changed).starts, "deleting either half of CRLF preserves logical numbering")
    }
    print("\n\(count) storage and line-index checks passed")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
