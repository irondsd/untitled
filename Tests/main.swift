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
    try check(cleanup.records[emptyFile] == nil && !FileManager.default.fileExists(atPath: cleanup.textURL(emptyFile).path),
        "closing an unchanged opened file discards its local copy instead of archiving it")
    try check(FileManager.default.fileExists(atPath: original.path), "discarding an opened file's local copy never deletes the original")
    let openedFile = try cleanup.create(text: "# Readme", filePath: original.path)
    try cleanup.rename(openedFile, title: "Renamed readme")
    try cleanup.archive(openedFile)
    try check(cleanup.records[openedFile] == nil, "renaming an opened file does not make it archivable")
    let editedFile = try cleanup.create(text: "# Readme", filePath: original.path)
    try cleanup.saveText("# Readme\nunsaved edit", for: editedFile)
    try cleanup.archive(editedFile)
    try check(cleanup.archived.contains { $0.id == editedFile }, "opened files with unsaved edits stay recoverable in the archive")
    try cleanup.deleteArchived(editedFile)
    try check(FileManager.default.fileExists(atPath: original.path), "deleting a local note never deletes its original external file")
    let savedScratch = try cleanup.create(text: "scratch saved elsewhere")
    try cleanup.associateFile(savedScratch, url: original, text: "scratch saved elsewhere")
    try cleanup.archive(savedScratch)
    try check(cleanup.archived.contains { $0.id == savedScratch }, "scratch notes saved to a file are still archived")
    let blankScratch = try cleanup.create(text: " \n\t")
    let blankFile = try cleanup.create(filePath: original.path)
    try check(try cleanup.isBlankScratch(blankScratch) && !cleanup.isBlankScratch(blankFile) && !cleanup.isBlankScratch(savedScratch),
        "only unnamed whitespace scratch notes count as blank")
    let order = cleanup.session.openIDs
    try cleanup.move(blankFile, to: 0)
    try check(cleanup.session.openIDs == [blankFile] + order.filter { $0 != blankFile }, "move places a tab at the given position")
    try cleanup.move(blankFile, to: 99)
    try check(cleanup.session.openIDs.last == blankFile && NotesStore(root: cleanup.root).session.openIDs == cleanup.session.openIDs,
        "move clamps to the end and persists the order")
    try cleanup.archive(blankScratch)
    try cleanup.archive(blankFile)
    let syntaxNote = try cleanup.create(text: "plain words")
    try cleanup.setSyntax(syntaxNote, language: .yaml)
    try check(NotesStore(root: cleanup.root).records[syntaxNote]?.syntaxOverride == .yaml, "manual syntax choice persists")
    try cleanup.setSyntax(syntaxNote, language: nil)
    try check(NotesStore(root: cleanup.root).records[syntaxNote]?.syntaxOverride == nil, "automatic detection can be restored")
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: cleanup.notesDirectory.appendingPathComponent("\(syntaxNote.uuidString).json"))) as! [String: Any]
    legacy["syntax"] = "cobol"
    try JSONSerialization.data(withJSONObject: legacy).write(to: cleanup.notesDirectory.appendingPathComponent("\(syntaxNote.uuidString).json"))
    let unknownSyntax = try NotesStore(root: cleanup.root).records[syntaxNote]
    try check(unknownSyntax?.syntaxOverride == nil && unknownSyntax?.archivedAt == nil, "unknown syntax values fall back to detection without losing metadata")
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
    let literal = try FindResults(source: "A.b a.b axb", query: FindQuery(text: "a.b"))
    try check(literal.matches.map(\.range.location) == [0, 4], "literal find escapes regex punctuation and ignores case by default")
    let sensitive = try FindResults(source: "A.b a.b", query: FindQuery(text: "a.b", caseSensitive: true))
    try check(sensitive.matches.map(\.range.location) == [4], "case sensitive find preserves case")
    let captures = try FindResults(source: "📝 name=Alice\nname=Bob", query: FindQuery(text: "name=(\\w+)", regex: true))
    let captureEdits = try captures.edits(replacement: "$1: $0\\n", indexes: [0, 1])
    try check(captureEdits.map(\.replacement) == ["Alice: name=Alice\n", "Bob: name=Bob\n"], "regex replacement expands captures, full match and newline escapes")
    try check(captureEdits[0].range.location == 3, "regex ranges use UTF-16 after emoji")
    let escapedEdit = try captures.edits(replacement: "\\$1 \\\\n\\t", indexes: [0])
    try check(escapedEdit[0].replacement == "$1 \\n\t", "replacement distinguishes escaped dollars, literal backslashes and tabs")
    try check(try literal.edits(replacement: "$1\\n", indexes: [0])[0].replacement == "$1\\n", "literal replacement preserves dollar signs and backslashes")
    let anchors = try FindResults(source: "a\nb\n", query: FindQuery(text: "^", regex: true))
    try check(anchors.matches.map(\.range) == [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)], "regex anchors match logical lines with finite zero-width results")
    let endMatch = try FindResults(source: "📝", query: FindQuery(text: "$", regex: true))
    try check(endMatch.matches[0].range == NSRange(location: 2, length: 0), "zero-width regex can match end of note")
    let empty = try FindResults(source: "abc", query: FindQuery(text: ""))
    try check(empty.matches.isEmpty, "empty query does not match every insertion position")
    var invalidPattern = false
    do { _ = try FindResults(source: "abc", query: FindQuery(text: "(", regex: true)) } catch { invalidPattern = true }
    try check(invalidPattern, "invalid regex produces an error without edits")
    var invalidGroup = false
    do { _ = try captures.edits(replacement: "$2", indexes: [0]) } catch { invalidGroup = true }
    try check(invalidGroup, "unknown replacement capture group is rejected")
    let lookaround = try FindResults(source: "one1 two2", query: FindQuery(text: "(?<=one)\\d", regex: true))
    try check(try lookaround.edits(replacement: "[$0]", indexes: [0])[0].replacement == "[1]", "lookbehind and captures keep full document context")
    let cancelled = try FindResults(source: String(repeating: "a ", count: 1000), query: FindQuery(text: "a"), cancelled: { true })
    try check(cancelled.matches.isEmpty, "obsolete searches can stop enumeration")
    let occurrences = try SelectionMatches(source: "📝 KSHA ksha KSHA KSHA-long", text: "KSHA")
    try check(occurrences.ranges.map(\.location) == [3, 13, 18], "selection matching is case-sensitive and includes partial words")
    try check(occurrences.next(after: occurrences.ranges[1], excluding: [occurrences.ranges[1]]) == occurrences.ranges[2], "next occurrence advances after the selected text")
    try check(occurrences.next(after: occurrences.ranges[2], excluding: [occurrences.ranges[2]]) == occurrences.ranges[0], "next occurrence wraps to the start")
    try check(occurrences.next(after: occurrences.ranges[2], excluding: occurrences.ranges) == nil, "selecting every occurrence does not duplicate ranges")
    let overlapping = try SelectionMatches(source: "aaaaa", text: "aa")
    try check(overlapping.ranges.map(\.location) == [0, 1, 2, 3], "selection matching finds overlapping literal positions")
    try check(overlapping.next(after: NSRange(location: 1, length: 2), excluding: [NSRange(location: 1, length: 2)]) == NSRange(location: 3, length: 2), "next occurrence avoids overlap with a manually chosen substring")
    let punctuation = try SelectionMatches(source: "a.b aXb a.b", text: "a.b")
    try check(punctuation.ranges.map(\.location) == [0, 8], "selection matching treats regex punctuation literally")
    let noSelection = try SelectionMatches(source: "abc", text: "")
    try check(noSelection.ranges.isEmpty, "empty selection has no occurrence matches")
    try check(occurrences.all(including: [occurrences.ranges[1]]) == occurrences.ranges, "select all includes every exact match without duplicates")
    try check(overlapping.all(including: [NSRange(location: 1, length: 2)]) == [NSRange(location: 1, length: 2), NSRange(location: 3, length: 2)], "select all preserves the original selection and skips overlapping matches")
    try check(try SelectionMatches(source: "aaaa", text: "aa").all(including: [NSRange(location: 0, length: 2)]) == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)], "select all preserves adjacent occurrence boundaries")
    let yamlFixture = "# Deployment\nservice: api\nenabled: true\nreplicas: 3\nurl: https://example.test/#anchor\nname: \"true # literal\" # comment\nscript: |\n  # heading inside a scalar\n  count: 42\n"
    let yamlSyntax = SyntaxEngine.analyze(yamlFixture)
    func kinds(_ result: SyntaxResult, _ source: String, at needle: String) -> [SyntaxKind] {
        let range = (source as NSString).range(of: needle)
        return result.spans.filter { NSLocationInRange(range.location, $0.range) }.map(\.kind)
    }
    try check(yamlSyntax.language == .yaml, "YAML mappings outweigh a leading hash comment")
    try check(kinds(yamlSyntax, yamlFixture, at: "service").contains(.key), "YAML mapping keys have a token")
    try check(kinds(yamlSyntax, yamlFixture, at: "true").contains(.literal), "YAML boolean values have a token")
    try check(kinds(yamlSyntax, yamlFixture, at: "3").contains(.number), "YAML numeric values have a token")
    try check(!kinds(yamlSyntax, yamlFixture, at: "#anchor").contains(.comment), "URL fragments stay inside plain YAML scalars")
    try check(kinds(yamlSyntax, yamlFixture, at: "# literal").contains(.string)
        && !kinds(yamlSyntax, yamlFixture, at: "# literal").contains(.comment), "YAML hashes inside quotes are strings")
    try check(kinds(yamlSyntax, yamlFixture, at: "# comment").contains(.comment), "YAML trailing comments have a token")
    try check(kinds(yamlSyntax, yamlFixture, at: "# heading").contains(.string)
        && !kinds(yamlSyntax, yamlFixture, at: "42").contains(.number), "YAML block scalars suppress nested syntax")
    for snippet in ["name: api", "name: api\nport: 8080", "enabled: true", "replicas: 3", "services:\n  - api\n  - worker", "- name: api\n  enabled: false", "%YAML 1.2\n---\nhello"] {
        try check(SyntaxEngine.analyze(snippet).language == .yaml, "detects YAML structure: \(snippet.prefix(24))")
    }
    for snippet in ["", "Just a plain note.", "Remember: call Alex tomorrow", "https://example.test/a#part", "echo hello", "---"] {
        let result = SyntaxEngine.analyze(snippet)
        try check(result.language == .plain && result.spans.isEmpty, "ambiguous or unsupported text stays plain: \(snippet.prefix(24))")
    }
    let markdownFixture = "# Plan 📝\r\n\r\n- [x] Ship **today**\r\n> A *quote* with [docs](https://example.test).\r\nUse `count: true` here.\r\n```yaml\r\n# literal code\r\nport: 42\r\n```\r\n"
    let markdownSyntax = SyntaxEngine.analyze(markdownFixture)
    try check(markdownSyntax.language == .markdown, "detects Markdown with CRLF and Unicode")
    try check(kinds(markdownSyntax, markdownFixture, at: "# Plan").contains(.heading), "Markdown headings have a token")
    try check(kinds(markdownSyntax, markdownFixture, at: "**today**").contains(.emphasis), "Markdown strong emphasis has a token")
    try check(kinds(markdownSyntax, markdownFixture, at: "*quote*").contains(.emphasis), "Markdown emphasis has a token")
    try check(kinds(markdownSyntax, markdownFixture, at: "[docs]").contains(.link), "Markdown links have a token")
    try check(kinds(markdownSyntax, markdownFixture, at: "count: true").contains(.code), "inline code suppresses other syntax")
    try check(kinds(markdownSyntax, markdownFixture, at: "# literal code") == [.code], "fenced code suppresses headings and YAML")
    for snippet in ["# Heading", "**bold**", "*italic*", "[link](https://example.test)", "Title\n====", "- one\n- two", "1. one", "> quote", "~~~\ncode", "```\nunclosed"] {
        try check(SyntaxEngine.analyze(snippet).language == .markdown, "detects Markdown structure: \(snippet.prefix(24))")
    }
    let frontMatter = "---\ntitle: Example\nenabled: true\n---\n\n# Heading\nText with **emphasis**."
    let frontSyntax = SyntaxEngine.analyze(frontMatter)
    try check(frontSyntax.language == .markdown && kinds(frontSyntax, frontMatter, at: "title").contains(.key)
        && kinds(frontSyntax, frontMatter, at: "# Heading").contains(.heading), "Markdown front matter uses YAML colors above a Markdown body")
    let unicodeYAML = "emoji: 🧩\n名前: \"café\"\r\ncount: 2"
    let unicodeSyntax = SyntaxEngine.analyze(unicodeYAML)
    try check(unicodeSyntax.language == .yaml && kinds(unicodeSyntax, unicodeYAML, at: "名前").contains(.key), "YAML keys support Unicode")
    for source in [yamlFixture, markdownFixture, unicodeYAML, frontMatter] {
        let result = SyntaxEngine.analyze(source)
        try check(result.spans.allSatisfy { $0.range.location >= 0 && $0.range.length > 0 && NSMaxRange($0.range) <= (source as NSString).length }, "syntax ranges are valid UTF-16 offsets")
    }
    for snippet in ["enabled: true # toggle", "{name: api, enabled: true}", "- true\n- false", "script: | # shell\n  # not a heading\n  echo true"] {
        try check(SyntaxEngine.analyze(snippet).language == .yaml, "detects additional YAML structure: \(snippet.prefix(24))")
    }
    try check(SyntaxEngine.analyze("# Set `enabled` to **true**\nenabled: true\nname: api").language == .yaml, "YAML comments can contain Markdown punctuation without changing detection")
    let scalarFixture = "message: the word true and 42 are plain\nport: 8080 # number\nflow: {name: api, enabled: false}\nbase: &defaults\ncopy: *defaults\nscript: >- # comment\n  # literal content\n  port: 99\nend: null"
    let scalarSyntax = SyntaxEngine.analyze(scalarFixture)
    try check(!kinds(scalarSyntax, scalarFixture, at: "true").contains(.literal)
        && !kinds(scalarSyntax, scalarFixture, at: "42").contains(.number), "YAML plain scalars do not color individual words as typed values")
    try check(kinds(scalarSyntax, scalarFixture, at: "8080").contains(.number), "YAML comments do not hide preceding numeric values")
    try check(kinds(scalarSyntax, scalarFixture, at: "name").contains(.key)
        && kinds(scalarSyntax, scalarFixture, at: "false").contains(.literal), "YAML flow collections color keys and typed values")
    try check(kinds(scalarSyntax, scalarFixture, at: "&defaults").contains(.marker)
        && kinds(scalarSyntax, scalarFixture, at: "*defaults").contains(.marker), "YAML anchors and aliases have tokens")
    try check(kinds(scalarSyntax, scalarFixture, at: "# literal content") == [.string]
        && !kinds(scalarSyntax, scalarFixture, at: "99").contains(.number)
        && kinds(scalarSyntax, scalarFixture, at: "null").contains(.literal), "commented block scalar indicators preserve literal content and stop at dedent")
    let fenceFixture = "~~~~yaml\n**literal**\n~~~\n# still code\n~~~~\n# Heading"
    let fenceSyntax = SyntaxEngine.analyze(fenceFixture)
    try check(kinds(fenceSyntax, fenceFixture, at: "# still code") == [.code]
        && kinds(fenceSyntax, fenceFixture, at: "# Heading").contains(.heading), "only a matching Markdown fence of sufficient length closes code")
    let escapedMarkdown = "# Escapes\n\\*plain* and snake_case_name plus `**code**`."
    let escapedSyntax = SyntaxEngine.analyze(escapedMarkdown)
    try check(!kinds(escapedSyntax, escapedMarkdown, at: "*plain*").contains(.emphasis)
        && !kinds(escapedSyntax, escapedMarkdown, at: "_case").contains(.emphasis)
        && kinds(escapedSyntax, escapedMarkdown, at: "**code**") == [.code], "escaped emphasis, identifiers and inline code keep literal text")
    try check(SyntaxEngine.analyze(String(repeating: yamlFixture, count: 1000), cancelled: { true }).spans.isEmpty,
        "obsolete syntax jobs can be cancelled")
    let typescript = #"""
    /* A client 📝. const ignored = false; */
    interface User {
      id: number;
      name: string;
    }
    type State = 'idle' | 'ready';
    const retries: number = 3;
    export async function greet(user: User): Promise<string> {
      const endpoint = "https://example.test/a//b";
      const pattern = /https?:\/\/[a-z/]+/gi;
      const ratio = retries / 2 / 3;
      const message = `Hello ${user.name}! ${Math.max(1, retries)}`;
      return { message, enabled: true, missing: null };
    }
    """#
    let tsSyntax = SyntaxEngine.analyze(typescript)
    try check(tsSyntax.language == .javascript, "TypeScript uses the shared JavaScript format")
    for (needle, kind) in [("interface", SyntaxKind.keyword), ("User", .type), ("number", .type), ("greet", .function), ("async", .keyword), ("true", .literal), ("null", .literal), ("3;", .number)] {
        try check(kinds(tsSyntax, typescript, at: needle).contains(kind), "TypeScript token: \(needle)")
    }
    try check(kinds(tsSyntax, typescript, at: "const ignored") == [.comment], "declarations inside block comments stay comments")
    try check(kinds(tsSyntax, typescript, at: "https://example.test/a//b") == [.string], "JavaScript URL strings do not become comments")
    try check(kinds(tsSyntax, typescript, at: "https?:") == [.string], "regex literals have string colors")
    try check(kinds(tsSyntax, typescript, at: "Hello") == [.string]
        && !kinds(tsSyntax, typescript, at: "user.name").contains(.string)
        && kinds(tsSyntax, typescript, at: "max(").contains(.function), "template strings highlight expressions separately from text")
    let divisionStart = (typescript as NSString).range(of: "retries / 2 / 3").location
    let divisionRange = NSRange(location: divisionStart, length: 17)
    try check(!tsSyntax.spans.contains { $0.kind == .string && NSIntersectionRange($0.range, divisionRange).length > 0 }, "division chains are not mistaken for regex literals")
    for snippet in [
        "const answer = 42;", "let value: string", "var count = 0;", "const { id } = user;",
        "function greet(name) { return name; }", "async function load() { await fetch('/api'); }",
        "(x) => x + 1", "x => x * 2", "interface User { id: number }", "type ID = string | number;",
        "class Client extends Base {}", "enum State { Idle, Ready }", "namespace App {}",
        "import { readFile } from 'fs';", "import React from 'react';", "import 'setup';",
        "export default config;", "console.log('hello');", "JSON.parse('{}')", "module.exports = {};",
        "fetch('/api')", "alert('hello')", "greet(user);", "client.run();", "if (ready) { console.log('go') }", "// A JavaScript comment", "/* unfinished comment",
        "#!/usr/bin/env node\nconsole.log('hello')", "const unfinished = `hello ${value"
    ] {
        try check(SyntaxEngine.analyze(snippet).language == .javascript, "detects JS/TS: \(snippet.prefix(35))")
    }
    let literals = #"""
    const values = [0xFF, 0b1010, 0o755, 1_000, 12n, 1.25e-3, .5];
    const escaped = "say \"hello\" // true";
    const single = 'it\'s /* literal */';
    const literal = `text ${ { value: `nested ${42}` }.value } end`;
    const escapedTemplate = `\${plain} and \`backtick\``;
    object.default; object.return();
    // false and 123 are a comment
    """#
    let literalSyntax = SyntaxEngine.analyze(literals)
    for number in ["0xFF", "0b1010", "0o755", "1_000", "12n", "1.25e-3", ".5", "42"] {
        try check(kinds(literalSyntax, literals, at: number) == [.number], "JavaScript numeric literal: \(number)")
    }
    try check(kinds(literalSyntax, literals, at: "// true") == [.string]
        && kinds(literalSyntax, literals, at: "/* literal */") == [.string], "escaped quote content suppresses comment and keyword syntax")
    try check(kinds(literalSyntax, literals, at: "nested") == [.string]
        && kinds(literalSyntax, literals, at: " end") == [.string], "nested template interpolation resumes the outer string")
    try check(kinds(literalSyntax, literals, at: "plain") == [.string], "escaped template interpolation stays literal")
    try check(!kinds(literalSyntax, literals, at: "default").contains(.keyword)
        && kinds(literalSyntax, literals, at: "return()").contains(.function), "member names are not colored as reserved words")
    try check(kinds(literalSyntax, literals, at: "false and 123") == [.comment], "line comments suppress literal colors")
    let regexCases = #"""
    function check(value) {
      if (value) /a[/*]b\//gi.test(value);
      return /foo\/\/bar/;
    }
    """#
    let regexSyntax = SyntaxEngine.analyze(regexCases)
    try check(kinds(regexSyntax, regexCases, at: "a[/*]b") == [.string]
        && kinds(regexSyntax, regexCases, at: "foo\\/\\/bar") == [.string], "regex escapes and character classes do not start comments")
    for snippet in [
        "\"const answer = 42;\"", "'interface User { id: number }'", "We should import the file tomorrow.",
        "This function is useful.", "Remember to return the package."
    ] {
        try check(SyntaxEngine.analyze(snippet).language == .plain, "prose and literal contents are not JavaScript evidence: \(snippet.prefix(30))")
    }
    for (snippet, language) in [
        ("script: |\n  const enabled = true;\n  console.log(enabled)", NoteLanguage.yaml),
        ("example: 'const answer = 42;'\nenabled: true", .yaml),
        ("# Docs\n\n```typescript\ninterface User { name: string }\n```", .markdown),
        ("---\ntitle: Client\n---\n\n```js\nconst x = 1;\n```", .markdown),
        ("Use `const answer = 42;` inline.", .markdown),
        ("const config = {\n  port: 8080,\n  enabled: true\n};", .javascript)
    ] {
        try check(SyntaxEngine.analyze(snippet).language == language, "format detection respects enclosing syntax: \(snippet.prefix(24))")
    }
    for snippet in [typescript, literals, regexCases, "const café = '🧩';\r\nconst 名前 = 2;\u{2028}console.log(名前);", "const x = `unterminated ${ { nested: 1 }", "const x = 'unfinished", "const x = 1; /* unfinished"] {
        let result = SyntaxEngine.analyze(snippet)
        try check(result.language == .javascript && result.spans.allSatisfy { $0.range.location >= 0 && $0.range.length > 0 && NSMaxRange($0.range) <= (snippet as NSString).length }, "JS/TS ranges handle Unicode, line endings and incomplete edits")
        try check(zip(result.spans, result.spans.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location }, "JavaScript lexical tokens never overlap")
    }
    // A provider can be added through the registry without any engine branch or UI dependency.
    struct TestFormat: SyntaxDefinition {
        static let language = NoteLanguage.javascript
        static func confidence(in source: SyntaxSource) -> Int { source.text.hasPrefix("custom:") ? 120 : 0 }
        static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] { [SyntaxSpan(range: NSRange(location: 0, length: 6), kind: .keyword)] }
    }
    struct TiedFormat: SyntaxDefinition {
        static let language = NoteLanguage.yaml
        static func confidence(in source: SyntaxSource) -> Int { 120 }
        static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] { [] }
    }
    let registered = SyntaxEngine.analyze("custom: source", using: [TestFormat.self, YAMLSyntax.self])
    try check(registered.language == .javascript && registered.spans.first?.kind == .keyword, "registered modules supply detection and semantic tokens without engine edits")
    try check(SyntaxEngine.analyze("custom: source", using: [TestFormat.self, TiedFormat.self]).language == .javascript
        && SyntaxEngine.analyze("custom: source", using: [TiedFormat.self, TestFormat.self]).language == .yaml, "equal detection confidence uses stable registry order")
    let forced = SyntaxEngine.analyze("# Heading\nkey: value", language: .yaml)
    try check(forced.language == .yaml && !forced.spans.isEmpty, "a chosen format skips detection")
    let forcedPlain = SyntaxEngine.analyze("key: value", language: .plain)
    try check(forcedPlain.language == .plain && forcedPlain.spans.isEmpty, "choosing plain text removes highlighting")
    try check(SyntaxEngine.detectLanguage("name: api\nport: 80") == .yaml && SyntaxEngine.detectLanguage("hello there") == .plain,
        "detection alone reports the language")
    try check(NoteLanguage.allCases.map(\.fileExtension) == ["txt", "sh", "css", "csv", "html", "js", "json", "md", "tsv", "xml", "yaml"], "each format suggests a file extension")
    func noOverlap(_ result: SyntaxResult, _ source: String) -> Bool {
        result.spans.allSatisfy { $0.range.location >= 0 && $0.range.length > 0 && NSMaxRange($0.range) <= (source as NSString).length }
            && zip(result.spans, result.spans.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location }
    }

    for (language, separator) in [(NoteLanguage.csv, ","), (.tsv, "\t")] {
        let table = "\u{FEFF}name\(separator)city\(separator)count\r\n\"Ada 🧩\"\(separator)\"Paris\(separator)France\"\(separator)12\r\n\"Grace\r\nHopper\"\(separator)\"said \"\"hello\"\"\"\(separator)7\r\n"
        let result = SyntaxEngine.analyze(table)
        try check(result.language == language, "detects \(language) with BOM, Unicode, CRLF and quoted multiline fields")
        for (needle, column) in [("name", 0), ("Ada", 0), ("Grace", 0), ("Hopper", 0), ("city", 1), ("Paris", 1), ("France", 1), ("hello", 1), ("count", 2), ("12", 2), ("7", 2)] {
            try check(kinds(result, table, at: needle) == [.column(column)], "\(language) keeps column \(column) color at \(needle)")
        }
        try check(noOverlap(result, table), "\(language) ranges are ordered and valid UTF-16")
        try check(result.spans.filter { $0.kind == .marker }.count == 6, "\(language) only marks separators outside quotes")
        let emptyCells = "a\(separator)\(separator)c\(separator)\nd\(separator)e\(separator)\(separator)f"
        let emptyResult = SyntaxEngine.analyze(emptyCells, language: language)
        try check(kinds(emptyResult, emptyCells, at: "c") == [.column(2)]
            && kinds(emptyResult, emptyCells, at: "f") == [.column(3)], "\(language) empty and trailing fields retain column positions")
        let wide = (0..<9).map { "value\($0)" }.joined(separator: separator)
        try check(kinds(SyntaxEngine.analyze(wide, language: language), wide, at: "value6") == [.column(0)], "\(language) cycles colors after six columns")
        for unfinished in ["", "a", "\"a\(separator)b\nnext", "a\(separator)\"b\"oops\(separator)c", "a\(separator)b\nc", "a\"b\(separator)c", "\(separator)\(separator)\r\n", "\"\"\"\""] {
            try check(noOverlap(SyntaxEngine.analyze(unfinished, language: language), unfinished), "manual \(language) tolerates incomplete edits: \(unfinished.debugDescription)")
        }
        let partial = "name\(separator)city\(separator)count\nAda\(separator)Paris\(separator)12\nGrace\(separator)\"unfinished"
        try check(SyntaxEngine.analyze(partial).language == language, "\(language) retains detection during an incomplete last record")
        let largeTable = "name\(separator)city\(separator)count\nAda\(separator)Paris\(separator)12\n\""
            + String(repeating: "🧩x", count: 20_000) + "\"\(separator)London\(separator)7"
        try check(SyntaxEngine.analyze(largeTable).language == language, "\(language) survives detection sampling inside a large quoted field")
        let blankRows = "a\(separator)b\(separator)c\r\r1\(separator)2\(separator)3\r\r"
        let blankResult = SyntaxEngine.analyze(blankRows)
        try check(blankResult.language == language && kinds(blankResult, blankRows, at: "1") == [.column(0)],
            "\(language) skips blank records and handles CR line endings")
        var csvWork = 0
        let cancelled = SyntaxEngine.analyze(String(repeating: table, count: 100), language: language,
            cancelled: { csvWork += 1; return csvWork > 80 })
        try check(cancelled.spans.isEmpty && csvWork > 80, "\(language) cancels scanning in progress")
        try loaded.setSyntax(first, language: language)
        try check(try NotesStore(root: root).records[first]?.syntaxOverride == language, "\(language) manual choice persists")
        try check(SyntaxEngine.fileExtension(for: table, language: language) == language.rawValue, "\(language) suggests its Save As extension")
    }
    for (snippet, language) in [
        ("name,age\nAda,36", NoteLanguage.csv),
        ("name,city\nAda,Paris\nGrace,New York", .csv),
        ("name\tcity\nAda\tParis", .tsv),
        ("name,role\tcount\nAda,dev\t12", .tsv),
        ("Hello, Alex\nThanks, Sam", .plain),
        ("one,two,three", .plain),
        ("name,age\nAda,36,extra", .plain),
        ("name,age\n\"unclosed,36", .plain),
        ("# Table\n\nname,age\nAda,36", .markdown),
        ("```csv\nname,age\nAda,36\n```", .markdown),
        ("values: |\n  name,age\n  Ada,36", .yaml),
        ("{\"a\": 1, \"b\": 2}\n", .json),
        ("const a = [1,2,3];\nconst b = [4,5,6];", .javascript)
    ] {
        try check(SyntaxEngine.analyze(snippet).language == language, "delimited detection respects table structure and other formats: \(snippet.debugDescription)")
    }

    let json = #"""
    {
      "名前 🧩": "café",
      "escaped": "say \"hello\" \\ \/ \b \f \n \r \t \u0041",
      "values": [true, false, null, -12, 0, 1.25, 6.02e+23, -2E-3],
      "nested": {"text": "const x = 42; **bold** <script>not code</script>"}
    }
    """#
    let jsonSyntax = SyntaxEngine.analyze(json)
    try check(jsonSyntax.language == .json, "detects JSON independently of YAML and JavaScript")
    for (needle, kind) in [("名前", SyntaxKind.key), ("escaped", .key), ("values", .key), ("café", .string),
                           ("say", .string), ("const x", .string), ("true", .literal), ("false", .literal),
                           ("null", .literal), ("-12", .number), ("1.25", .number), ("6.02e+23", .number),
                           ("-2E-3", .number), ("{", .marker), ("[", .marker)] {
        try check(kinds(jsonSyntax, json, at: needle) == [kind], "JSON token: \(needle)")
    }
    try check(noOverlap(jsonSyntax, json), "JSON tokens stay ordered, non-overlapping and within UTF-16 bounds")
    for snippet in ["{}", "[]", "{\"a\":1}", "[1, 2, 3]", "[true,false,null]", "[[[]],{}]",
                    "{\"empty\":{\"array\":[]}}", "\u{FEFF}{\r\n\"名前🧩\": \"雪\"\r\n}",
                    "{\"key\":", "{\"key\": \"unfinished", "{\"key\": tru", "[1.2e-", "[null, {\"x\": ["] {
        try check(SyntaxEngine.analyze(snippet).language == .json, "detects complete or unfinished JSON: \(snippet.debugDescription)")
    }
    let jsonAsStrings = #"{"true": "false", "123": "null", "punctuation": "{}[]:,", "quote": "\"key\": 1"}"#
    let stringSyntax = SyntaxEngine.analyze(jsonAsStrings)
    try check(kinds(stringSyntax, jsonAsStrings, at: "true") == [.key]
        && kinds(stringSyntax, jsonAsStrings, at: "123") == [.key]
        && kinds(stringSyntax, jsonAsStrings, at: "false") == [.string]
        && kinds(stringSyntax, jsonAsStrings, at: "{}[]:,") == [.string]
        && kinds(stringSyntax, jsonAsStrings, at: "key") == [.string], "JSON protects quoted values and escaped quotes from other tokens")
    for (snippet, language) in [
        ("{name: api, enabled: true}", NoteLanguage.yaml),
        ("data: |\n  {\"enabled\": true}", .yaml),
        ("```json\n{\"enabled\": true}\n```", .markdown),
        ("# JSON\n\n{\"enabled\": true}", .markdown),
        ("const config = {\"enabled\": true};", .javascript),
        ("{\"run\": () => true}", .javascript),
        ("<script type=\"application/json\">{\"enabled\":true}</script>", .html),
        ("body { color: red; }", .css),
        ("An ordinary note about JSON.", .plain),
        ("true", .plain), ("42", .plain), ("\"a string\"", .plain)
    ] {
        try check(SyntaxEngine.analyze(snippet).language == language, "JSON detection respects other formats: \(snippet.prefix(32).debugDescription)")
    }
    for snippet in ["[value]", "{\"key\": undefined}", "{\"key\": NaN}", "[1,2].map(x => x)",
                    "{\"key\": 0xFF}", "{\"key\": 01}", "{\"key\": 1n}", "{\"key\": true};", "[1 2]",
                    "{\"x\" true}", "{\"x\":]", #"{"x":"\q"}"#, #"{"x":"\uXYZW"}"#] {
        try check(JSONSyntax.confidence(in: SyntaxSource(snippet)) == 0, "non-JSON tokens do not become JSON evidence: \(snippet.debugDescription)")
    }
    for snippet in [json, "{\"x\":\"🧩\r\nnext", "{\"x\":\"escape\\", #"{"x":"\u12"#, "{\"x\": -", "{\"x\": 1.",
                    "[nul", "{\"x\": }", "\"literal\"", "{\"bad\":\"\\q\"}"] {
        try check(noOverlap(SyntaxEngine.analyze(snippet, language: .json), snippet), "manual JSON handles unfinished or invalid edits: \(snippet.prefix(28).debugDescription)")
    }
    try check(SyntaxEngine.analyze("true", language: .json).spans.first?.kind == .literal,
        "manual JSON supports scalar documents without detecting ordinary scalar notes")
    let largeJSON = "{\"items\":[" + String(repeating: "{\"name\":\"🧩\",\"value\":123},", count: 2000) + "null]}"
    try check(SyntaxEngine.analyze(largeJSON).language == .json, "JSON detection survives a sample ending inside a large document")
    try check(SyntaxEngine.analyze(String(repeating: "[", count: 1000) + "0" + String(repeating: "]", count: 1000)).language == .json,
        "deep JSON nesting uses bounded iterative parser state")
    var jsonWork = 0
    let cancelledJSON = SyntaxEngine.analyze(largeJSON, language: .json, cancelled: { jsonWork += 1; return jsonWork > 100 })
    try check(cancelledJSON.spans.isEmpty && jsonWork > 100, "JSON scanning checks cancellation during work")
    try loaded.setSyntax(first, language: .json)
    try check(try NotesStore(root: root).records[first]?.syntaxOverride == .json, "JSON menu choice persists in note metadata")

    // JSX and TSX share the JavaScript format.
    let tsx = #"""
    import React from 'react';
    type Props = { title: string; count?: number };
    export function Card({ title, count }: Props) {
      const big = count > 3 && count < 10;
      return (
        <section className="card" data-id={title}>
          {/* a comment */}
          <Header.Title level={2}>{title}</Header.Title>
          <p>Don't panic — it's 100% fine</p>
          <>
            <input disabled value='x' />
          </>
          {big ? <Badge /> : null}
        </section>
      );
    }
    """#
    let tsxSyntax = SyntaxEngine.analyze(tsx)
    try check(tsxSyntax.language == .javascript, "TSX uses the JavaScript format")
    for (needle, kind) in [("section", SyntaxKind.tag), ("className", .attribute), ("data-id", .attribute), ("\"card\"", .string),
                           ("Header.Title", .type), ("level", .attribute), ("Badge", .type), ("disabled", .attribute), ("'x'", .string),
                           ("a comment", .comment), ("Props", .type), ("string", .type)] {
        try check(kinds(tsxSyntax, tsx, at: needle).contains(kind), "JSX token: \(needle)")
    }
    try check(kinds(tsxSyntax, tsx, at: "Don't panic") == [] && kinds(tsxSyntax, tsx, at: "100%") == [],
        "JSX text children stay plain, including apostrophes")
    try check(kinds(tsxSyntax, tsx, at: "3 &&").contains(.number), "comparisons are not mistaken for JSX")
    try check(noOverlap(tsxSyntax, tsx), "JSX tokens stay ordered and in range")
    let generics = "const id = <T,>(value: T): T => value;\nconst cast = <any>window;\nfunction first<T>(items: T[]) { return items[0] < 2; }"
    let genericSyntax = SyntaxEngine.analyze(generics)
    try check(genericSyntax.language == .javascript && !genericSyntax.spans.contains { $0.kind == .tag || $0.kind == .attribute }
        && kinds(genericSyntax, generics, at: "value: T").contains(.key), "TypeScript generics and assertions are not JSX")
    for snippet in ["<Button onClick={() => save()} />", "<div className=\"row\">Hi</div>", "<><Item /></>",
                    "const el = <div>hello</div>;", "return <List items={items} />"] {
        try check(SyntaxEngine.analyze(snippet).language == .javascript, "detects JSX: \(snippet.prefix(30))")
    }
    for (snippet, ext) in [("const a = 1;", "js"), ("const a: number = 1;", "ts"), ("const a = <div>x</div>;", "jsx"), (tsx, "tsx"),
                           ("interface User { id: number }", "ts"), ("function f(a, b) { return { a: b }; }", "js")] {
        try check(SyntaxEngine.fileExtension(for: snippet, language: .javascript) == ext, "JavaScript save extension: \(ext) for \(snippet.prefix(24))")
    }
    for snippet in ["const unfinished = <div className=", "const x = <div>{items.map(i => <Item key={i} />)", "a = <", "<div {...props"] {
        let result = SyntaxEngine.analyze(snippet)
        try check(noOverlap(result, snippet), "incomplete JSX keeps valid ranges: \(snippet.prefix(24))")
    }

    // CSS
    let css = #"""
    @import url("theme.css");
    /* Layout 🧩 */
    :root { --gap: 1.5rem; }
    body > .card, #main a:hover::after {
      margin: 0 auto;
      color: #fff !important;
      width: calc(100% - var(--gap));
      background: url(data:image/png;base64,AAAA);
      font-family: "Inter", sans-serif;
    }
    input[type="text"] { border: 1px solid rgba(0, 0, 0, .5) }
    @media (max-width: 600px) {
      .card { padding: -2px; }
    }
    """#
    let cssSyntax = SyntaxEngine.analyze(css)
    try check(cssSyntax.language == .css, "detects CSS")
    for (needle, kind) in [("@import", SyntaxKind.keyword), ("Layout", .comment), ("--gap:", .key), ("1.5rem", .number), ("body", .tag),
                           (".card,", .type), ("#main", .type), (":hover", .keyword), ("::after", .keyword), ("margin", .key),
                           ("#fff", .number), ("!important", .keyword), ("calc", .function), ("100%", .number), ("\"Inter\"", .string),
                           ("type=", .attribute), ("rgba", .function), (".5", .number), ("@media", .keyword), ("max-width", .key),
                           ("600px", .number), ("-2px", .number), ("{", .marker)] {
        try check(kinds(cssSyntax, css, at: needle).contains(kind), "CSS token: \(needle)")
    }
    try check(!kinds(cssSyntax, css, at: "AAAA").contains(.key) && kinds(cssSyntax, css, at: "auto") == [],
        "CSS value keywords stay plain and data URLs keep their semicolons")
    try check(noOverlap(cssSyntax, css), "CSS tokens stay ordered and in range")
    for snippet in ["body {\n  margin: 0;\n  padding: 0;\n}", ".btn { color: red }", "a:hover { text-decoration: underline; }",
                    "@media print {\n  nav { display: none; }\n}", "@import 'base.css';",
                    ".parent {\n  color: blue;\n  &:hover { color: red; }\n}"] {
        try check(SyntaxEngine.analyze(snippet).language == .css, "detects CSS: \(snippet.prefix(24))")
    }
    for (snippet, language) in [
        ("interface User {\n  id: number;\n  name: string;\n}", NoteLanguage.javascript),
        ("if (ready) {\n  color: red;\n}", .javascript),
        ("const style = {\n  color: 'red',\n};", .javascript),
        ("color: red\nmargin: 0", .yaml),
        ("Hello {name}: welcome;", .plain)
    ] {
        try check(SyntaxEngine.analyze(snippet).language == language, "CSS detection respects other formats: \(snippet.prefix(24))")
    }
    try check(SyntaxEngine.analyze("{\"color\": \"red\"}").language != .css, "JSON objects are not CSS")
    for snippet in ["body { color:", ".a { b: c", "/* open", "a[href=\"x", "@media (", "x { y: \"z"] {
        try check(noOverlap(SyntaxEngine.analyze(snippet, language: .css), snippet), "incomplete CSS keeps valid ranges: \(snippet)")
    }

    // HTML
    let html = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset=utf-8>
      <style>
        body { margin: 0; }
      </style>
    </head>
    <body>
      <!-- note -->
      <p class='intro'>Fish &amp; chips — const x = 1;</p>
      <script type="module">
        const answer = 42; // "</p>"
      </script>
      <script type="text/template"><b>raw</b></script>
    </body>
    </html>
    """#
    let htmlSyntax = SyntaxEngine.analyze(html)
    try check(htmlSyntax.language == .html, "detects HTML documents")
    for (needle, kind) in [("<!DOCTYPE html>", SyntaxKind.keyword), ("html lang", .tag), ("lang", .attribute), ("\"en\"", .string),
                           ("utf-8", .string), ("margin", .key), ("note", .comment), ("class", .attribute), ("'intro'", .string),
                           ("&amp;", .literal), ("const answer", .keyword), ("42", .number), ("\"</p>\"", .comment), ("</", .marker)] {
        try check(kinds(htmlSyntax, html, at: needle).contains(kind), "HTML token: \(needle)")
    }
    try check(kinds(htmlSyntax, html, at: "const x") == [] && kinds(htmlSyntax, html, at: "raw") == [],
        "HTML text and template scripts are not highlighted as code")
    try check(noOverlap(htmlSyntax, html), "HTML tokens stay ordered and in range")
    for snippet in ["<div class=\"row\">\n  <p>Hello</p>\n</div>", "<ul>\n<li>One</li>\n</ul>", "<!-- comment -->\n<p>x</p>",
                    "<style>.a { color: red; }</style>", "<section>\n  <h1>{title}</h1>\n</section>"] {
        try check(SyntaxEngine.analyze(snippet).language == .html, "detects HTML: \(snippet.prefix(24))")
    }
    for (snippet, language) in [
        ("<p align=\"center\"><img src=\"logo.png\"></p>\n\n# Project\n\n- one\n- two", NoteLanguage.markdown),
        ("Use the <b>bold</b> tag.", .plain),
        ("a < b && c > d", .plain)
    ] {
        try check(SyntaxEngine.analyze(snippet).language == language, "HTML detection respects other formats: \(snippet.prefix(24))")
    }
    for snippet in ["<div class=\"x", "<script>const a = '", "<!-- open", "<p>&amp", "<a href=x", "<style>a { color:"] {
        try check(noOverlap(SyntaxEngine.analyze(snippet, language: .html), snippet), "incomplete HTML keeps valid ranges: \(snippet)")
    }
    // Bash
    let bash = #"""
    #!/usr/bin/env bash
    set -euo pipefail
    # Deploy 🚀
    NAME="${1:-world}"
    files=(a.txt "b c.txt")
    greet() {
      local who=$1
      echo "Hello, $who! Today is $(date +%A)" >&2
    }
    for f in "${files[@]}"; do
      if [[ -f $f ]]; then grep -v '#' "$f" > /dev/null 2>&1; fi
    done
    case "$NAME" in
      world|all) echo 'single $quoted';;
      *) printf "%s\n" `whoami` ;;
    esac
    cat <<-EOF > out.txt
    	value: $NAME and $((count + 1)) # not a comment
    	EOF
    cat <<'RAW'
    $literal
    RAW
    echo done # trailing
    """#
    let bashSyntax = SyntaxEngine.analyze(bash)
    try check(bashSyntax.language == .bash, "detects Bash from a shebang")
    for (needle, kind) in [("#!/usr", SyntaxKind.comment), ("set", .function), ("-euo", .attribute), ("Deploy", .comment), ("NAME=", .key),
                           ("${1:-world}", .key), ("files=", .key), ("\"b c.txt\"", .string), ("greet", .function), ("local", .function),
                           ("who=", .key), ("$who", .key), ("Hello", .string), ("$(", .marker), ("date", .function), (">&2", .marker),
                           ("for", .keyword), ("in \"", .keyword), ("${files[@]}", .key), ("do\n", .keyword), ("[[", .keyword), ("-f", .attribute),
                           ("then", .keyword), ("grep", .function), ("'#'", .string), ("2>", .number), ("fi\n", .keyword), ("done\n", .keyword),
                           ("case", .keyword), ("|all", .marker), (";;", .marker), ("esac", .keyword), ("`whoami`", .marker), ("whoami", .function),
                           ("<<-", .marker), ("value:", .string), ("$((", .marker), ("count", .key), ("1))", .number), ("# not", .string),
                           ("$literal", .string), ("trailing", .comment)] {
        try check(kinds(bashSyntax, bash, at: needle).contains(kind), "Bash token: \(needle.debugDescription)")
    }
    try check(kinds(bashSyntax, bash, at: "single $quoted") == [.string], "single quotes do not expand variables")
    try check(kinds(bashSyntax, bash, at: "done #") == [], "reserved words in argument position stay plain")
    try check(kinds(bashSyntax, bash, at: "world|") == [], "case patterns are not commands")
    try check(noOverlap(bashSyntax, bash), "Bash tokens stay ordered and in range")
    for snippet in ["#!/bin/bash\necho hello", "#!/bin/sh\nexit 0", "for i in 1 2 3; do echo $i; done",
                    "if [ -f ~/.bashrc ]; then\n  source ~/.bashrc\nfi", "git status\ngit pull\nnpm install",
                    "while read -r line; do\n  echo \"$line\"\ndone < input.txt", "function deploy {\n  echo hi\n}",
                    "FOO=bar\nBAZ=qux\nDEBUG=1", "cd ~/dev/app && npm test 2>&1 | tee log.txt"] {
        try check(SyntaxEngine.analyze(snippet).language == .bash, "detects Bash: \(snippet.prefix(24).debugDescription)")
    }
    for (snippet, language) in [
        ("make dinner\ncat food\nset alarm", NoteLanguage.plain),
        ("It costs $5 or $10 today", .plain),
        ("if it rains then\nwe stay home\ndone", .plain),
        ("name: api\ncommand: echo \"$HOME\" 2>&1\nrun: npm test", .yaml),
        ("run: |\n  if [ -f x ]; then echo; fi\n  echo $HOME", .yaml),
        ("function deploy() {\n  console.log('hi');\n}", .javascript),
        ("$(document).ready(function() {\n  $('.btn').on('click', go);\n});", .javascript),
        ("const x = a << SHIFT;\nif (x) { y(); }", .javascript),
        ("# Setup\n\n```bash\nnpm install\n```", .markdown),
        ("Use `npm install` and then `npm test` here.", .markdown)
    ] {
        try check(SyntaxEngine.analyze(snippet).language == language, "Bash detection respects other formats: \(snippet.prefix(24).debugDescription)")
    }
    for snippet in ["echo \"unfinished $(date", "cat <<EOF\nno end", "x=${HOME", "echo 'open", "case $x in\n  a)", "$((1 +", "`ls", "arr=(a b",
                    "cat <<", "echo hi \\\r\n  there\r\n", "printf '%s' 🧩 \"名前 $名\"", "a=1 b=2 cmd >"] {
        try check(noOverlap(SyntaxEngine.analyze(snippet, language: .bash), snippet), "incomplete Bash keeps valid ranges: \(snippet.prefix(24).debugDescription)")
    }

    // XML
    let xml = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE note [ <!ENTITY w "World"> ]>
    <note xmlns:h="http://example.test/h" id='1'>
      <h:to>Tove &w; — café</h:to>
      <![CDATA[ a < b && c > d ]]>
      <script>const x = 1;</script>
      <empty/>
      <!-- note -->
    </note>
    """#
    let xmlSyntax = SyntaxEngine.analyze(xml)
    try check(xmlSyntax.language == .xml, "detects XML from its declaration")
    for (needle, kind) in [("<?", SyntaxKind.marker), ("xml version", .keyword), ("version", .attribute), ("\"UTF-8\"", .string), ("?>", .marker),
                           ("<!DOCTYPE", .keyword), ("<!ENTITY", .keyword), ("note xmlns", .tag), ("xmlns:h", .attribute), ("'1'", .string),
                           ("h:to", .tag), ("&w;", .literal), ("<![CDATA[", .marker), (" a < b", .string), ("]]>", .marker),
                           ("empty", .tag), ("/>", .marker), ("note -->", .comment)] {
        try check(kinds(xmlSyntax, xml, at: needle).contains(kind), "XML token: \(needle)")
    }
    try check(kinds(xmlSyntax, xml, at: "const x") == [], "XML script elements are not JavaScript")
    try check(noOverlap(xmlSyntax, xml), "XML tokens stay ordered and in range")
    for snippet in ["<note><to>Tove</to></note>", "<Config>\n  <Item name=\"a\"/>\n</Config>", "<svg xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M0 0\"/></svg>",
                    "<!-- feed -->\n<rss version=\"2.0\"><channel><title>x</title></channel></rss>", "\u{FEFF}<?xml version=\"1.0\"?><a/>",
                    "<LinearLayout android:id=\"@+id/root\" />", "<_x>a</_x>"] {
        try check(SyntaxEngine.analyze(snippet).language == .xml, "detects XML: \(snippet.prefix(24).debugDescription)")
    }
    for (snippet, language) in [
        ("<div><svg xmlns=\"http://www.w3.org/2000/svg\"></svg></div>", NoteLanguage.html),
        ("<ul>\n<li>One</li>\n</ul>", .html),
        ("<!DOCTYPE html>\n<html><body></body></html>", .html),
        ("<Button onClick={() => save()} />", .javascript),
        ("<><Item /></>", .javascript),
        ("<p align=\"center\"><img src=\"logo.png\"></p>\n\n# Project", .markdown),
        ("a < b && c > d", .plain)
    ] {
        try check(SyntaxEngine.analyze(snippet).language == language, "XML detection respects other formats: \(snippet.prefix(24).debugDescription)")
    }
    for snippet in ["<?xml version=\"1.0", "<![CDATA[ open", "<!DOCTYPE x [ <!ENTITY", "<a b=\"c", "<ns:tag", "<a>&amp"] {
        try check(noOverlap(SyntaxEngine.analyze(snippet, language: .xml), snippet), "incomplete XML keeps valid ranges: \(snippet.debugDescription)")
    }
    try check(SyntaxEngine.analyze("custom: source", using: [TestFormat.self], cancelled: { true }).spans.isEmpty,
        "cancellation applies to added formats through the shared engine")
    // Visible-range painting asks the index for on-screen spans only.
    func span(_ location: Int, _ length: Int, _ kind: SyntaxKind = .key) -> SyntaxSpan {
        SyntaxSpan(range: NSRange(location: location, length: length), kind: kind)
    }
    func ranges(_ spans: [SyntaxSpan]) -> [NSRange] { spans.map(\.range) }
    let disjoint = SyntaxSpanIndex([span(0, 3), span(5, 2), span(10, 4), span(20, 1)])
    try check(disjoint.count == 4 && ranges(disjoint.spans(in: NSRange(location: 6, length: 6)))
        == [NSRange(location: 6, length: 1), NSRange(location: 10, length: 2)], "span index clips disjoint spans to the window")
    try check(disjoint.spans(in: NSRange(location: 3, length: 2)).isEmpty
        && disjoint.spans(in: NSRange(location: 14, length: 6)).isEmpty, "span index skips gaps and touching boundaries")
    try check(disjoint.spans(in: NSRange(location: 21, length: 50)).isEmpty && disjoint.spans(in: NSRange(location: 0, length: 0)).isEmpty,
        "span index handles windows past the end and empty windows")
    try check(SyntaxSpanIndex().spans(in: NSRange(location: 0, length: 10)).isEmpty, "empty span index returns nothing")
    let unsorted = SyntaxSpanIndex([span(10, 2, .string), span(0, 2, .number), span(5, 2, .comment)])
    try check(unsorted.spans(in: NSRange(location: 0, length: 12)).map(\.kind) == [.number, .comment, .string],
        "span index sorts out-of-order disjoint spans")
    // A long early span must not hide later short ones, and later overlaps still override.
    let layered = SyntaxSpanIndex([span(0, 100, .code), span(40, 5, .key), span(42, 2, .string), span(90, 3, .number)])
    let middle = layered.spans(in: NSRange(location: 41, length: 2))
    try check(middle.map(\.kind) == [.code, .key, .string] && ranges(middle)
        == [NSRange(location: 41, length: 2), NSRange(location: 41, length: 2), NSRange(location: 42, length: 1)],
        "overlapping spans keep their original override order")
    try check(layered.spans(in: NSRange(location: 60, length: 10)).map(\.kind) == [.code], "an enclosing span reaches windows inside it")
    let reversed = SyntaxSpanIndex([span(30, 5, .key), span(0, 50, .comment)])
    try check(reversed.spans(in: NSRange(location: 31, length: 1)).map(\.kind) == [.key, .comment],
        "a later enclosing span still overrides an earlier one after sorting")
    let indexedNote = "---\ntitle: Plan\n---\n# Heading\n\nSome **bold** text.\n"
    let analyzed = SyntaxEngine.analyze(indexedNote)
    let everything = NSRange(location: 0, length: (indexedNote as NSString).length)
    try check(SyntaxSpanIndex(analyzed.spans).spans(in: everything).map { "\($0.range)\($0.kind)" }
        == analyzed.spans.map { "\($0.range)\($0.kind)" }, "the whole-note window reproduces the engine's spans in order")
    var many: [SyntaxSpan] = []
    for line in 0..<20_000 { many.append(span(line * 10, 4, line % 2 == 0 ? .key : .string)); many.append(span(line * 10 + 5, 3, .number)) }
    let large = SyntaxSpanIndex(many)
    try check(ranges(large.spans(in: NSRange(location: 150_002, length: 10)))
        == [NSRange(location: 150_002, length: 2), NSRange(location: 150_005, length: 3), NSRange(location: 150_010, length: 2)],
        "span index finds a window deep in a large note")
    let writable = root.appendingPathComponent("external.txt")
    try ExternalFileWriter.write("saved\n", to: writable)
    try check(try String(contentsOf: writable, encoding: .utf8) == "saved\n", "external writes to writable files need no administrator")
    let locked = root.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    var lockedError: Error?
    do { try "x".write(to: locked.appendingPathComponent("hosts"), atomically: true, encoding: .utf8) } catch { lockedError = error }
    try check(lockedError.map(ExternalFileWriter.isPermissionDenied) == true, "writes into a read-only folder are recognized as permission failures")
    var missingError: Error?
    do { try "x".write(to: root.appendingPathComponent("missing/file.txt"), atomically: true, encoding: .utf8) } catch { missingError = error }
    try check(missingError.map(ExternalFileWriter.isPermissionDenied) == false, "a missing folder does not ask for an administrator password")
    let awkward = ExternalFileWriter.scriptSource(copying: "/tmp/a \"quoted\" \\ path", to: "/etc/it's \"hosts\"")
    var compileError: NSDictionary?
    try check(NSAppleScript(source: awkward)?.compileAndReturnError(&compileError) == true && compileError == nil,
        "administrator save script compiles with quotes and backslashes in paths")
    print("\n\(count) storage, line-index, find and syntax checks passed")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
