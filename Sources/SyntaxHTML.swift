import Foundation

/// HTML markup. `<script>` and `<style>` bodies are handed to the JavaScript and CSS modules.
struct HTMLSyntax: SyntaxDefinition {
    static let language = NoteLanguage.html
    private static let tag = SyntaxRegex.compile(#"<(/?)([a-zA-Z][a-zA-Z0-9-]*)(?:\s[^<>]*)?/?>"#)
    private static let document = SyntaxRegex.compile(#"(?i)<!doctype\s+html|<(?:html|head|body|script|style)[\s>]"#)
    private static let start = SyntaxRegex.compile(#"^\s*(?:<!--|<![a-zA-Z]|<[a-zA-Z][a-zA-Z0-9-]*[\s/>])"#)
    private static let markdownBlock = SyntaxRegex.compile(#"(?m)^ {0,3}(?:#{1,6}\s|```|~~~)"#)

    static func confidence(in source: SyntaxSource) -> Int {
        let text = source.text
        guard source.first(start, text) != nil else { return 0 }
        // READMEs often open with a centered HTML banner before Markdown headings.
        if source.first(markdownBlock, text) != nil { return 40 }
        // A full document, or one owning script/style blocks, encloses any code inside it.
        if source.first(document, text) != nil { return 95 }
        let tags = source.matches(tag, text)
        let closing = tags.contains { $0.range(at: 1).length > 0 }
        return tags.count >= 2 || closing ? 75 : 50
    }

    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] { HTMLScanner(source).scan() }
}

private final class HTMLScanner {
    private let source: SyntaxSource
    private let text: NSString
    private let units: [UInt16]
    private var position = 0
    private var spans: [SyntaxSpan] = []

    init(_ source: SyntaxSource) {
        self.source = source
        text = source.text as NSString
        units = Array(source.text.utf16)
    }
    private func unit(_ offset: Int = 0) -> UInt16 { position + offset < units.count ? units[position + offset] : 0 }
    private func whitespace(_ value: UInt16) -> Bool {
        UnicodeScalar(value).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
    private func letter(_ value: UInt16) -> Bool { (65...90).contains(value) || (97...122).contains(value) }
    private func namePart(_ value: UInt16) -> Bool {
        letter(value) || (48...57).contains(value) || [UInt16(45), 95, 58, 46].contains(value) || value >= 128
    }
    private func add(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
        if end > start { spans.append(SyntaxSpan(range: NSRange(location: start, length: end - start), kind: kind)) }
    }
    private func find(_ needle: String, from start: Int, caseInsensitive: Bool = false) -> Int? {
        guard start <= units.count else { return nil }
        let found = text.range(of: needle, options: caseInsensitive ? [.literal, .caseInsensitive] : .literal,
            range: NSRange(location: start, length: units.count - start))
        return found.location == NSNotFound ? nil : found.location
    }

    func scan() -> [SyntaxSpan] {
        while position < units.count && !source.cancelled() {
            let character = unit()
            if character == 60 && unit(1) == 33 && unit(2) == 45 && unit(3) == 45 {
                let end = find("-->", from: position + 4).map { $0 + 3 } ?? units.count
                add(position, end, .comment); position = end; continue
            }
            if character == 60 && (unit(1) == 33 || unit(1) == 63) {
                // Doctype, CDATA and processing instructions.
                let end = find(">", from: position).map { $0 + 1 } ?? units.count
                add(position, end, .keyword); position = end; continue
            }
            if character == 60 && (letter(unit(1)) || unit(1) == 47 && letter(unit(2))) {
                tag(); continue
            }
            if character == 38 {
                var cursor = position + 1
                while cursor < units.count && cursor - position < 32 && (namePart(units[cursor]) || units[cursor] == 35) { cursor += 1 }
                if cursor < units.count && units[cursor] == 59 && cursor > position + 1 {
                    add(position, cursor + 1, .literal); position = cursor + 1; continue
                }
            }
            position += 1
        }
        return spans
    }

    private func tag() {
        let open = position
        let closing = unit(1) == 47
        position += closing ? 2 : 1
        add(open, position, .marker)
        let nameStart = position
        while position < units.count && namePart(unit()) { position += 1 }
        add(nameStart, position, .tag)
        let name = text.substring(with: NSRange(location: nameStart, length: position - nameStart)).lowercased()
        var scriptType = ""
        while position < units.count && !source.cancelled() {
            let character = unit()
            if whitespace(character) { position += 1; continue }
            if character == 62 { add(position, position + 1, .marker); position += 1; break }
            if character == 47 && unit(1) == 62 { add(position, position + 2, .marker); position += 2; return }
            // A stray `<` means the tag was never closed; let the outer scan resume there.
            if character == 60 { return }
            let attributeStart = position
            while position < units.count && !whitespace(unit()) && ![UInt16(61), 62, 60].contains(unit())
                && !(unit() == 47 && unit(1) == 62) { position += 1 }
            if position == attributeStart { position += 1; continue }
            add(attributeStart, position, .attribute)
            let attribute = text.substring(with: NSRange(location: attributeStart, length: position - attributeStart)).lowercased()
            var cursor = position
            while cursor < units.count && whitespace(units[cursor]) { cursor += 1 }
            guard cursor < units.count, units[cursor] == 61 else { continue }
            add(cursor, cursor + 1, .marker)
            position = cursor + 1
            while position < units.count && whitespace(unit()) { position += 1 }
            let valueStart = position, quote = unit()
            if quote == 34 || quote == 39 {
                position = find(String(UnicodeScalar(quote)!), from: position + 1).map { $0 + 1 } ?? units.count
            } else {
                while position < units.count && !whitespace(unit()) && unit() != 62 { position += 1 }
            }
            add(valueStart, position, .string)
            if attribute == "type" {
                scriptType = text.substring(with: NSRange(location: valueStart, length: position - valueStart)).lowercased()
            }
        }
        guard !closing, name == "script" || name == "style" else { return }
        // Raw text runs to the matching end tag; nothing inside is markup.
        let end = find("</" + name, from: position, caseInsensitive: true) ?? units.count
        let markupScript = ["template", "html", "text/x-", "markdown"].contains { scriptType.contains($0) }
        if name == "script" && markupScript { position = end; return }
        let body = SyntaxSource(text.substring(with: NSRange(location: position, length: end - position)), cancelled: source.cancelled)
        let embedded = name == "style" ? CSSSyntax.highlight(body) : JavaScriptSyntax.highlight(body)
        spans += embedded.map { SyntaxSpan(range: NSRange(location: $0.range.location + position, length: $0.range.length), kind: $0.kind) }
        position = end
    }
}
