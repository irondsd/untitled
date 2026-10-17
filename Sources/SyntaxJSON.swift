import Foundation

/// JSON has its own small lexer so quoted keys differ from values and JavaScript stays separate.
struct JSONSyntax: SyntaxDefinition {
    static let language = NoteLanguage.json
    private static let number = SyntaxRegex.compile(#"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#)
    private static let partialNumber = SyntaxRegex.compile(#"^(?:-|(?:-?(?:0|[1-9][0-9]*))(?:\.[0-9]*)?(?:[eE][+-]?[0-9]*)?)$"#)

    private struct Token {
        let range: NSRange
        let text: String
        let kind: SyntaxKind?
        let complete: Bool
        let valid: Bool
    }

    // An iterative prefix grammar avoids recursive parsing of deeply nested or unfinished notes.
    private enum Expectation { case value, arrayValue, key, colon, objectComma, arrayComma, end }
    static func confidence(in source: SyntaxSource) -> Int {
        let tokens = scan(source)
        guard let first = tokens.first, first.text == "{" || first.text == "[" else { return 0 }
        var stack: [Expectation] = [.end], expectation: Expectation = .value, evidence = false
        for (index, token) in tokens.enumerated() {
            guard !source.cancelled(), token.valid else { return 0 }
            let last = index == tokens.count - 1
            switch expectation {
            case .key:
                if token.text == "}" { expectation = stack.removeLast(); evidence = true; continue }
                guard token.kind == .string else { return 0 }
                expectation = .colon
            case .colon:
                guard token.text == ":" else { return 0 }
                expectation = .value; evidence = true
            case .objectComma, .arrayComma:
                let object = expectation == .objectComma
                if token.text == (object ? "}" : "]") {
                    expectation = stack.removeLast(); evidence = true; continue
                }
                guard token.text == "," else { return 0 }
                expectation = object ? .key : .arrayValue
            case .value, .arrayValue:
                if expectation == .arrayValue && token.text == "]" {
                    expectation = stack.removeLast(); evidence = true; continue
                }
                let after: Expectation
                if index == 0 { after = .end }
                else if expectation == .arrayValue { after = .arrayComma }
                else { after = .objectComma }
                if token.text == "{" || token.text == "[" {
                    // The initial sentinel handles the root; nested collections save their parent state.
                    if index > 0 { stack.append(after) }
                    expectation = token.text == "{" ? .key : .arrayValue
                } else {
                    guard [.string, .number, .literal].contains(token.kind) else { return 0 }
                    evidence = true; expectation = after
                }
            case .end: return 0
            }
            if !token.complete { return last && evidence ? 92 : 0 }
        }
        return evidence && !source.cancelled() ? 92 : 0
    }

    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] {
        let tokens = scan(source)
        var spans: [SyntaxSpan] = []
        for (index, token) in tokens.enumerated() {
            if source.cancelled() { break }
            guard let kind = token.kind else { continue }
            let key = kind == .string && index + 1 < tokens.count && tokens[index + 1].text == ":"
            spans.append(SyntaxSpan(range: token.range, kind: key ? .key : kind))
        }
        return spans
    }

    private static func scan(_ source: SyntaxSource) -> [Token] {
        let text = source.text as NSString, units = Array(source.text.utf16)
        var position = 0, result: [Token] = []
        func whitespace(_ c: UInt16) -> Bool { [UInt16(32), 9, 10, 13].contains(c) }
        func punctuation(_ c: UInt16) -> Bool { [UInt16(123), 125, 91, 93, 58, 44].contains(c) }
        func hex(_ c: UInt16) -> Bool { (48...57).contains(c) || (65...70).contains(c) || (97...102).contains(c) }
        while position < units.count && !source.cancelled() {
            let c = units[position]
            if whitespace(c) || position == 0 && c == 0xFEFF { position += 1; continue }
            let start = position
            var kind: SyntaxKind?, complete = true, valid = true
            if c == 34 {
                position += 1; complete = false; kind = .string
                while position < units.count && !source.cancelled() {
                    let next = units[position]
                    if next == 34 { position += 1; complete = true; break }
                    if next < 32 { valid = false; break }
                    position += 1
                    if next == 92 {
                        guard position < units.count else { break }
                        let escape = units[position]; position += 1
                        if escape == 117 {
                            for _ in 0..<4 {
                                guard position < units.count else { break }
                                if !hex(units[position]) { valid = false; break }
                                position += 1
                            }
                        } else if ![UInt16(34), 92, 47, 98, 102, 110, 114, 116].contains(escape) { valid = false }
                    }
                }
            } else if punctuation(c) {
                position += 1; kind = .marker
            } else {
                // Keep unknown words intact: a number or keyword inside an identifier isn't JSON.
                position += 1
                while position < units.count && !whitespace(units[position]) && !punctuation(units[position])
                    && units[position] != 34 && !source.cancelled() { position += 1 }
                let word = text.substring(with: NSRange(location: start, length: position - start))
                if ["true", "false", "null"].contains(word) { kind = .literal }
                else if source.first(number, word) != nil { kind = .number }
                else if position == units.count && ["true", "false", "null"].contains(where: { $0.hasPrefix(word) }) {
                    kind = .literal; complete = false
                } else if position == units.count && source.first(partialNumber, word) != nil {
                    kind = .number; complete = false
                } else { valid = false }
            }
            let range = NSRange(location: start, length: position - start)
            result.append(Token(range: range, text: text.substring(with: range), kind: kind, complete: complete, valid: valid))
        }
        return result
    }
}
