import Foundation

/// JavaScript and TypeScript share a lexer; TypeScript adds keywords and type names.
/// This is deliberately tolerant of incomplete source while typing, rather than a compiler/parser.
struct JavaScriptSyntax: SyntaxDefinition {
    static let language = NoteLanguage.javascript
    fileprivate static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "get", "if",
        "import", "in", "instanceof", "let", "new", "of", "return", "set", "static", "super", "switch",
        "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
        "abstract", "accessor", "as", "asserts", "declare", "enum", "implements", "infer", "interface",
        "is", "keyof", "namespace", "override", "private", "protected", "public", "readonly", "satisfies", "type"
    ]
    fileprivate static let types: Set<String> = [
        "any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown", "intrinsic"
    ]
    fileprivate static let literals: Set<String> = ["true", "false", "null", "undefined", "NaN", "Infinity"]

    static func confidence(in source: SyntaxSource) -> Int {
        let tokens = JavaScriptLexer(source).scan()
        guard !source.cancelled() else { return 0 }
        // Keep literal placeholders for import/call syntax, but never inspect their contents.
        let code = tokens.filter { $0.kind != .comment && $0.kind != .templateText }
        func word(_ index: Int) -> String { code.indices.contains(index) ? code[index].text : "" }
        func identifier(_ index: Int) -> Bool { code.indices.contains(index) && code[index].kind == .identifier }
        for index in code.indices {
            if source.cancelled() { return 0 }
            guard code[index].kind == .identifier || code[index].kind == .punctuation else { continue }
            let value = word(index), next = word(index + 1)
            // Member names such as object.class and mapping keys such as "type:" are not declarations.
            if word(index - 1) == "." || word(index - 1) == "?." || next == ":" { continue }
            if ["const", "let", "var"].contains(value), identifier(index + 1) || ["{", "["].contains(next) {
                let end = min(code.count, index + 24)
                if code[(index + 1)..<end].contains(where: { $0.text == "=" }) { return 90 }
                if next != "", word(index + 2) == ":" || index + 2 == code.count { return 85 }
            }
            if value == "function", next == "(" || next == "*" || (identifier(index + 1) && word(index + 2) == "(") { return 90 }
            if ["class", "interface", "enum", "namespace"].contains(value), identifier(index + 1),
               ["{", "<", "extends", "implements"].contains(word(index + 2)) { return 90 }
            if value == "type", identifier(index + 1), ["=", "<"].contains(word(index + 2)) { return 90 }
            if value == "import", next == "{" || next == "*" || next == "(" || code.indices.contains(index + 1) && code[index + 1].kind == .string { return 90 }
            if value == "import", identifier(index + 1), ["from", ","].contains(word(index + 2)) { return 90 }
            if value == "export", next == "default" || next == "{" || next == "*" { return 90 }
            if value == "=>", identifier(index - 1) || word(index - 1) == ")" || word(index - 1) == "]" { return 90 }
            if ["console", "JSON", "Math", "Object", "Array", "Promise", "window", "document", "module"].contains(value),
               next == ".", identifier(index + 2), ["(", "=", "."].contains(word(index + 3)) { return 85 }
            if ["require", "fetch", "setTimeout", "setInterval"].contains(value), next == "(" { return 85 }
            if ["if", "while", "for", "switch", "catch"].contains(value), next == "(",
               code.dropFirst(index + 2).prefix(40).contains(where: { $0.text == "{" }) { return 85 }
            if identifier(index), index == 0 || [";", "{", "}"].contains(word(index - 1)) {
                var call = index + 1
                while [".", "?."].contains(word(call)) && identifier(call + 1) { call += 2 }
                if word(call) == "(" {
                    let argument = call + 1
                    let literalArgument = code.indices.contains(argument)
                        && [.string, .number, .regexp].contains(code[argument].kind)
                    let terminatedCall = code.dropFirst(argument).prefix(40).enumerated().contains {
                        $0.element.text == ")" && word(argument + $0.offset + 1) == ";"
                    }
                    if literalArgument || terminatedCall { return 80 }
                }
            }
        }
        let firstLine = source.lines.first?.trimmed ?? ""
        if firstLine.hasPrefix("#!"), ["node", "deno", "bun"].contains(where: { firstLine.contains($0) }) { return 100 }
        if firstLine.hasPrefix("//") || firstLine.hasPrefix("/*") { return 40 }
        return 0
    }

    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] {
        let tokens = JavaScriptLexer(source).scan()
        var result: [SyntaxSpan] = []
        for (index, token) in tokens.enumerated() {
            if source.cancelled() { break }
            let previous = index > 0 ? tokens[index - 1].text : ""
            let next = index + 1 < tokens.count ? tokens[index + 1].text : ""
            let member = previous == "." || previous == "?."
            let kind: SyntaxKind?
            switch token.kind {
            case .comment: kind = .comment
            case .string, .templateText, .regexp: kind = .string
            case .number: kind = .number
            case .punctuation: kind = .marker
            case .identifier:
                if next == ":" { kind = .key }
                else if !member && literals.contains(token.text) { kind = .literal }
                else if !member && keywords.contains(token.text) { kind = .keyword }
                else if next == "(" { kind = .function }
                else if !member && (types.contains(token.text) || token.text.first?.isUppercase == true) { kind = .type }
                else { kind = nil }
            }
            if let kind { result.append(SyntaxSpan(range: token.range, kind: kind)) }
        }
        return result
    }
}

private struct JavaScriptToken {
    enum Kind { case identifier, string, templateText, regexp, number, comment, punctuation }
    let range: NSRange
    let text: String
    let kind: Kind
}

/// A single forward scan protects comments, escaped strings, regexes and nested template interpolations.
private final class JavaScriptLexer {
    private let source: SyntaxSource
    private let text: NSString
    private let units: [UInt16]
    private var position = 0
    private var tokens: [JavaScriptToken] = []
    private static let controls: Set<String> = ["if", "while", "for", "with", "switch", "catch"]
    private static let expressionKeywords: Set<String> = ["return", "throw", "case", "delete", "void", "typeof", "new", "in", "of", "yield", "await", "else", "do"]
    private static let operators: Set<String> = [
        "=>", "==", "!=", "===", "!==", "<=", ">=", "++", "--", "&&", "||", "??", "?.", "**",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>", ">>>", "<<=", ">>=", ">>>=",
        "&&=", "||=", "??=", "**=", "..."
    ]

    init(_ source: SyntaxSource) {
        self.source = source
        text = source.text as NSString
        units = Array(source.text.utf16)
    }
    func scan() -> [JavaScriptToken] {
        scanCode(interpolation: false, nesting: 0)
        return tokens
    }
    private func unit(_ offset: Int = 0) -> UInt16 { position + offset < units.count ? units[position + offset] : 0 }
    private func newline(_ value: UInt16) -> Bool { [UInt16(10), 13, 0x2028, 0x2029].contains(value) }
    private func whitespace(_ value: UInt16) -> Bool {
        UnicodeScalar(value).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
    private func identifierStart(_ value: UInt16) -> Bool {
        value == 36 || value == 95 || (65...90).contains(value) || (97...122).contains(value)
            || (value >= 128 && (UnicodeScalar(value).map { CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0) } ?? true))
    }
    private func digit(_ value: UInt16) -> Bool { (48...57).contains(value) }
    private func identifierPart(_ value: UInt16) -> Bool { identifierStart(value) || digit(value) || value == 0x200C || value == 0x200D }
    private func checkpoint() -> Bool { position & 1023 == 0 && source.cancelled() }
    private func add(_ start: Int, _ kind: JavaScriptToken.Kind) {
        let range = NSRange(location: start, length: position - start)
        guard range.length > 0 else { return }
        // Literal bodies can be large; detection only needs their kind and range.
        let value = kind == .identifier || kind == .punctuation ? text.substring(with: range) : ""
        tokens.append(JavaScriptToken(range: range, text: value, kind: kind))
    }

    private func scanCode(interpolation: Bool, nesting: Int) {
        var braces = 0, expressionAllowed = true
        var parens: [Bool] = []
        var previous = ""
        while position < units.count && !source.cancelled() {
            let start = position, character = unit()
            if whitespace(character) { position += 1; continue }
            if interpolation && character == 125 && braces == 0 { return }
            if character == 35 && position == 0 && unit(1) == 33 {
                while position < units.count && !newline(unit()) && !checkpoint() { position += 1 }
                add(start, .comment); continue
            }
            if character == 47 && unit(1) == 47 {
                position += 2
                while position < units.count && !newline(unit()) && !checkpoint() { position += 1 }
                add(start, .comment); continue
            }
            if character == 47 && unit(1) == 42 {
                position += 2
                while position < units.count && !checkpoint() {
                    if unit() == 42 && unit(1) == 47 { position += 2; break }
                    position += 1
                }
                add(start, .comment); continue
            }
            if character == 34 || character == 39 {
                quoted(character)
                add(start, .string); expressionAllowed = false; previous = "literal"; continue
            }
            if character == 96 {
                template(nesting: nesting)
                expressionAllowed = false; previous = "literal"; continue
            }
            if character == 47 && expressionAllowed, let end = regexEnd() {
                position = end; add(start, .regexp)
                expressionAllowed = false; previous = "literal"; continue
            }
            if digit(character) || character == 46 && digit(unit(1)) {
                number()
                add(start, .number); expressionAllowed = false; previous = "literal"; continue
            }
            if identifierStart(character) {
                position += 1
                while position < units.count && identifierPart(unit()) && !checkpoint() { position += 1 }
                add(start, .identifier)
                let word = tokens.last!.text
                expressionAllowed = previous != "." && previous != "?." && Self.expressionKeywords.contains(word)
                previous = word
                continue
            }
            position += 1
            for length in stride(from: min(4, units.count - start), through: 2, by: -1) {
                let value = text.substring(with: NSRange(location: start, length: length))
                if Self.operators.contains(value) { position = start + length; break }
            }
            add(start, .punctuation)
            let value = tokens.last!.text
            switch value {
            case "(": parens.append(Self.controls.contains(previous)); expressionAllowed = true
            case ")": expressionAllowed = parens.popLast() ?? false
            case "{": braces += 1; expressionAllowed = true
            case "}": braces = max(0, braces - 1); expressionAllowed = false
            case "]", ".", "?.": expressionAllowed = false
            case "++", "--": break
            default: expressionAllowed = true
            }
            previous = value
        }
    }

    private func quoted(_ quote: UInt16) {
        position += 1
        while position < units.count && !checkpoint() {
            if unit() == 92 {
                position = min(units.count, position + 2)
                if position >= 2 && units[position - 1] == 13 && unit() == 10 { position += 1 }
            } else if unit() == quote { position += 1; return }
            else if newline(unit()) { return }
            else { position += 1 }
        }
    }

    private func template(nesting: Int) {
        var start = position
        position += 1
        while position < units.count && !checkpoint() {
            if unit() == 92 { position = min(units.count, position + 2); continue }
            if unit() == 96 { position += 1; add(start, .templateText); return }
            if unit() == 36 && unit(1) == 123 && nesting < 64 {
                add(start, .templateText)
                let marker = position
                position += 2; add(marker, .punctuation)
                scanCode(interpolation: true, nesting: nesting + 1)
                if position < units.count && unit() == 125 {
                    let close = position
                    position += 1; add(close, .punctuation)
                }
                start = position
            } else { position += 1 }
        }
        add(start, .templateText)
    }

    private func regexEnd() -> Int? {
        var cursor = position + 1, inClass = false
        while cursor < units.count {
            if cursor & 1023 == 0 && source.cancelled() { return nil }
            let value = units[cursor]
            if newline(value) { return nil }
            if value == 92 { cursor += 2; continue }
            if value == 91 { inClass = true }
            else if value == 93 { inClass = false }
            else if value == 47 && !inClass {
                cursor += 1
                while cursor < units.count && identifierPart(units[cursor]) { cursor += 1 }
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private func number() {
        func consume(_ valid: (UInt16) -> Bool) {
            while position < units.count && (valid(unit()) || unit() == 95) && !checkpoint() { position += 1 }
        }
        if unit() == 48 && [UInt16(120), 88, 98, 66, 111, 79].contains(unit(1)) {
            let prefix = unit(1)
            position += 2
            consume { value in
                if prefix == 98 || prefix == 66 { return value == 48 || value == 49 }
                if prefix == 111 || prefix == 79 { return (48...55).contains(value) }
                return (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
            }
            if unit() == 110 { position += 1 }
            return
        }
        consume(digit)
        var fractional = false
        if unit() == 46 {
            fractional = true; position += 1; consume(digit)
        }
        if unit() == 101 || unit() == 69 {
            let exponent = position
            position += 1
            if unit() == 43 || unit() == 45 { position += 1 }
            if digit(unit()) { consume(digit); fractional = true }
            else { position = exponent }
        }
        if !fractional && unit() == 110 { position += 1 }
    }
}
