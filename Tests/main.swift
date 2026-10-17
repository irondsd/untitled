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
        "This function is useful.", "Remember to return the package.", "#!/bin/bash\necho hello"
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
    try check(SyntaxEngine.analyze("custom: source", using: [TestFormat.self], cancelled: { true }).spans.isEmpty,
        "cancellation applies to added formats through the shared engine")
    print("\n\(count) storage, line-index, find and syntax checks passed")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
