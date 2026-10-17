import Foundation

/// CSS, including nested rules as written in SCSS/PostCSS. A statement is a selector or at-rule
/// prelude when `{` comes before `;` or `}`; otherwise it is a `property: value` declaration.
struct CSSSyntax: SyntaxDefinition {
    static let language = NoteLanguage.css

    static func confidence(in source: SyntaxSource) -> Int {
        let scanner = CSSScanner(source)
        _ = scanner.scan()
        guard !source.cancelled(), scanner.rejected == 0 else { return 0 }
        // A stylesheet that so far only has `@import …;` lines.
        if scanner.imports > 0 && scanner.rules == 0 && scanner.strays == 0 { return 80 }
        guard scanner.declarations > scanner.strays else { return 0 }
        if scanner.atRules > 0 && scanner.rules > 0 { return 90 }
        guard scanner.rules > 0 else { return 0 }
        return scanner.declarations >= 2 || scanner.qualifiedSelectors > 0 ? 88 : 75
    }

    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] { CSSScanner(source).scan() }
}

private final class CSSScanner {
    private let source: SyntaxSource
    private let text: NSString
    private let units: [UInt16]
    private var position = 0
    private var spans: [SyntaxSpan] = []
    // Detection evidence.
    private(set) var rules = 0, declarations = 0, atRules = 0, imports = 0, qualifiedSelectors = 0, strays = 0, rejected = 0
    private static let codeWords: Set<String> = [
        "if", "else", "for", "while", "switch", "function", "class", "const", "let", "var", "return", "try", "catch",
        "export", "import", "interface", "type", "enum", "namespace", "declare", "def", "do", "struct", "fn", "func"
    ]
    private static let blockAtRules: Set<String> = [
        "media", "supports", "keyframes", "font-face", "page", "layer", "container", "document", "counter-style",
        "property", "font-feature-values", "-webkit-keyframes", "mixin", "include", "each", "if", "else", "for", "function"
    ]

    init(_ source: SyntaxSource) {
        self.source = source
        text = source.text as NSString
        units = Array(source.text.utf16)
    }
    private func unit(_ offset: Int = 0) -> UInt16 { position + offset < units.count ? units[position + offset] : 0 }
    private func at(_ index: Int) -> UInt16 { index < units.count ? units[index] : 0 }
    private func whitespace(_ value: UInt16) -> Bool {
        UnicodeScalar(value).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
    private func nameStart(_ value: UInt16) -> Bool {
        value == 95 || value == 45 || (65...90).contains(value) || (97...122).contains(value) || value >= 128
    }
    private func namePart(_ value: UInt16) -> Bool { nameStart(value) || (48...57).contains(value) }
    private func digit(_ value: UInt16) -> Bool { (48...57).contains(value) }
    private func add(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
        if end > start { spans.append(SyntaxSpan(range: NSRange(location: start, length: end - start), kind: kind)) }
    }
    private func string(_ start: Int, limit: Int) -> Int {
        let quote = units[start]
        var cursor = start + 1
        while cursor < limit {
            if units[cursor] == 92 { cursor += 2; continue }
            if units[cursor] == quote { return cursor + 1 }
            if units[cursor] == 10 || units[cursor] == 13 { return cursor }
            cursor += 1
        }
        return min(cursor, limit)
    }
    private func commentEnd(_ start: Int) -> Int {
        var cursor = start + 2
        while cursor < units.count {
            if units[cursor] == 42 && at(cursor + 1) == 47 { return cursor + 2 }
            cursor += 1
        }
        return units.count
    }

    func scan() -> [SyntaxSpan] {
        var depth = 0
        while position < units.count && !source.cancelled() {
            let character = unit()
            if whitespace(character) { position += 1; continue }
            if character == 47 && unit(1) == 42 {
                let end = commentEnd(position); add(position, end, .comment); position = end; continue
            }
            // `//` comments are common in SCSS and Less.
            if character == 47 && unit(1) == 47 {
                let start = position
                while position < units.count && unit() != 10 && unit() != 13 { position += 1 }
                add(start, position, .comment); continue
            }
            if character == 125 { add(position, position + 1, .marker); position += 1; depth = max(0, depth - 1); continue }
            if character == 59 { add(position, position + 1, .marker); position += 1; continue }
            let start = position
            let (end, terminator) = statementEnd(from: start)
            if terminator == 123 {
                prelude(start, end)
                add(end, end + 1, .marker)
                position = end + 1; depth += 1
            } else {
                if character == 64 { prelude(start, end) }
                else if depth > 0 { if declaration(start, end) { declarations += 1 } else { strays += 1 } }
                else { strays += 1; values(start, end) }
                position = end
                if terminator == 59 { add(end, end + 1, .marker); position = end + 1 }
            }
        }
        return spans
    }

    /// The first `{`, `;` or `}` outside strings, comments, parentheses and brackets.
    private func statementEnd(from start: Int) -> (Int, UInt16) {
        var cursor = start, nesting = 0
        while cursor < units.count {
            if cursor & 1023 == 0 && source.cancelled() { return (units.count, 0) }
            let value = units[cursor]
            if value == 34 || value == 39 { cursor = string(cursor, limit: units.count); continue }
            if value == 47 && at(cursor + 1) == 42 { cursor = commentEnd(cursor); continue }
            if value == 40 || value == 91 { nesting += 1 }
            else if value == 41 || value == 93 { nesting = max(0, nesting - 1) }
            else if nesting == 0 && (value == 123 || value == 59 || value == 125) { return (cursor, value) }
            // SCSS interpolation `#{…}` stays inside the statement.
            else if value == 35 && at(cursor + 1) == 123 {
                if let close = (cursor..<units.count).first(where: { units[$0] == 125 }) { cursor = close + 1; continue }
            }
            cursor += 1
        }
        return (units.count, 0)
    }

    private func prelude(_ start: Int, _ end: Int) {
        if units[start] == 64 {
            var cursor = start + 1
            while cursor < end && namePart(units[cursor]) { cursor += 1 }
            let name = text.substring(with: NSRange(location: start + 1, length: cursor - start - 1)).lowercased()
            add(start, cursor, .keyword)
            if Self.blockAtRules.contains(name) { atRules += 1 }
            if ["import", "charset", "use", "forward", "namespace", "tailwind"].contains(name) { imports += 1; atRules += 1 }
            values(cursor, end)
            return
        }
        let prelude = text.substring(with: NSRange(location: start, length: end - start))
        let firstWord = prelude.prefix { $0.isLetter || $0 == "_" }
        let blank = prelude.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if blank || Self.codeWords.contains(String(firstWord)) || prelude.contains("=>") || prelude.contains("==") {
            rejected += 1
        }
        selector(start, end)
        rules += 1
    }

    private func selector(_ start: Int, _ end: Int) {
        var cursor = start, brackets = false, parenDepth = 0
        while cursor < end {
            let value = units[cursor]
            if value == 34 || value == 39 {
                let close = string(cursor, limit: end); add(cursor, close, .string); cursor = close; continue
            }
            if value == 47 && at(cursor + 1) == 42 {
                let close = min(end, commentEnd(cursor)); add(cursor, close, .comment); cursor = close; continue
            }
            if brackets {
                if value == 93 { brackets = false; add(cursor, cursor + 1, .marker); cursor += 1; continue }
                if nameStart(value) {
                    let first = cursor
                    while cursor < end && namePart(units[cursor]) { cursor += 1 }
                    add(first, cursor, .attribute); continue
                }
                cursor += 1; continue
            }
            if value == 91 { brackets = true; add(cursor, cursor + 1, .marker); cursor += 1; continue }
            if value == 61 { rejected += 1 }
            if value == 40 {
                // Only pseudo-class arguments (`:not(…)`, `:nth-child(…)`) belong in a selector.
                if cursor == start || whitespace(units[cursor - 1]) { rejected += 1 }
                parenDepth += 1; cursor += 1; continue
            }
            if value == 41 { parenDepth = max(0, parenDepth - 1); cursor += 1; continue }
            if (value == 46 || value == 35) && nameStart(at(cursor + 1)) {
                let first = cursor
                cursor += 1
                while cursor < end && namePart(units[cursor]) { cursor += 1 }
                add(first, cursor, .type); qualifiedSelectors += 1; continue
            }
            if value == 58 {
                let first = cursor
                cursor += 1
                if cursor < end && units[cursor] == 58 { cursor += 1 }
                while cursor < end && namePart(units[cursor]) { cursor += 1 }
                add(first, cursor, .keyword); qualifiedSelectors += 1; continue
            }
            if digit(value) && parenDepth == 0 {
                let first = cursor
                while cursor < end && (digit(units[cursor]) || units[cursor] == 46 || units[cursor] == 37) { cursor += 1 }
                add(first, cursor, .number); continue
            }
            if nameStart(value) && value != 45 || value == 42 || value == 45 && nameStart(at(cursor + 1)) {
                let first = cursor
                cursor += 1
                while cursor < end && namePart(units[cursor]) { cursor += 1 }
                if parenDepth == 0 { add(first, cursor, .tag) }
                continue
            }
            if [UInt16(62), 43, 126, 44, 38].contains(value) { add(cursor, cursor + 1, .marker) }
            cursor += 1
        }
    }

    /// `property: value`, including custom properties and vendor prefixes.
    private func declaration(_ start: Int, _ end: Int) -> Bool {
        var cursor = start
        if units[cursor] == 42 { cursor += 1 }
        let nameBegin = cursor
        while cursor < end && (namePart(units[cursor]) || units[cursor] == 36) { cursor += 1 }
        let nameEnd = cursor
        while cursor < end && whitespace(units[cursor]) { cursor += 1 }
        guard nameEnd > nameBegin, cursor < end, units[cursor] == 58,
              nameStart(units[nameBegin]) || units[nameBegin] == 36 else {
            values(start, end)
            return false
        }
        add(start, nameEnd, .key)
        add(cursor, cursor + 1, .marker)
        values(cursor + 1, end)
        return text.substring(with: NSRange(location: cursor + 1, length: end - cursor - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func values(_ start: Int, _ end: Int) {
        var cursor = start
        while cursor < end {
            let value = units[cursor]
            if value == 34 || value == 39 {
                let close = string(cursor, limit: end); add(cursor, close, .string); cursor = close; continue
            }
            if value == 47 && at(cursor + 1) == 42 {
                let close = min(end, commentEnd(cursor)); add(cursor, close, .comment); cursor = close; continue
            }
            if value == 35 && cursor + 1 < end && namePart(units[cursor + 1]) {
                let first = cursor
                cursor += 1
                while cursor < end && namePart(units[cursor]) { cursor += 1 }
                add(first, cursor, .number); continue
            }
            if value == 33 {
                let first = cursor
                cursor += 1
                while cursor < end && namePart(units[cursor]) { cursor += 1 }
                add(first, cursor, .keyword); continue
            }
            let signed = (value == 45 || value == 43) && (digit(at(cursor + 1)) || at(cursor + 1) == 46 && digit(at(cursor + 2)))
                && (cursor == start || !namePart(units[cursor - 1]))
            if digit(value) && (cursor == start || !namePart(units[cursor - 1])) || value == 46 && digit(at(cursor + 1)) || signed {
                let first = cursor
                cursor += 1
                while cursor < end && (digit(units[cursor]) || units[cursor] == 46) { cursor += 1 }
                if cursor < end && (units[cursor] == 101 || units[cursor] == 69) && digit(at(cursor + 1)) {
                    cursor += 1
                    while cursor < end && digit(units[cursor]) { cursor += 1 }
                }
                // Units and percentages belong to the number.
                while cursor < end && (namePart(units[cursor]) && units[cursor] != 45 || units[cursor] == 37) { cursor += 1 }
                add(first, cursor, .number); continue
            }
            if nameStart(value) || value == 36 || value == 64 {
                let first = cursor
                cursor += 1
                while cursor < end && namePart(units[cursor]) { cursor += 1 }
                if at(cursor) == 40 && cursor < end { add(first, cursor, .function) }
                else if at(cursor) == 58 && cursor < end { add(first, cursor, .key) }
                continue
            }
            if value == 58 { add(cursor, cursor + 1, .marker) }
            cursor += 1
        }
    }
}
