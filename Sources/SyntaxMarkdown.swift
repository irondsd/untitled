import Foundation

struct MarkdownSyntax: SyntaxDefinition {
    static let language = NoteLanguage.markdown
    private static let heading = SyntaxRegex.compile(#"^ {0,3}#{1,6}(?:[ \t]+|$)"#)
    private static let list = SyntaxRegex.compile(#"^ {0,3}(?:[-+*]|[0-9]{1,9}[.)])[ \t]+"#)
    private static let quote = SyntaxRegex.compile(#"^ {0,3}>[ \t]?"#)
    private static let fence = SyntaxRegex.compile(#"^ {0,3}(`{3,}|~{3,})(.*)$"#)
    private static let rule = SyntaxRegex.compile(#"^ {0,3}(?:(?:\* *){3,}|(?:- *){3,}|(?:_ *){3,})$"#)
    private static let setext = SyntaxRegex.compile(#"^ {0,3}(?:=+|-+)[ \t]*$"#)
    private static let inlineCode = SyntaxRegex.compile(#"(`+)([^`\r\n]+)\1(?!`)"#)
    private static let strong = SyntaxRegex.compile(#"(?<![\\\w])(?:\*\*(?=\S)(.+?\S|\S)\*\*|__(?=\S)(.+?\S|\S)__)(?!\w)"#)
    private static let emphasis = SyntaxRegex.compile(#"(?<![\\\w*])(?:\*(?=\S)([^*\r\n]*\S|\S)\*|_(?=\S)([^_\r\n]*\S|\S)_)(?!\w)"#)
    private static let link = SyntaxRegex.compile(#"!?\[[^\]\r\n]+\]\([^\s)]+(?: +\"[^\"]*\")?\)|<https?://[^>\s]+>"#)
    private static let reference = SyntaxRegex.compile(#"^ {0,3}\[[^\]]+\]: +\S+"#)

    static func confidence(in source: SyntaxSource) -> Int {
        if YAMLSyntax.frontMatterEnd(in: source) != nil { return 110 }
        var score = 0, distinctive = false
        for (index, line) in source.lines.enumerated() {
            if source.cancelled() { return 0 }
            if source.first(fence, line.text) != nil { return 100 }
            if source.first(heading, line.text) != nil { score += 3 }
            // Hash comments containing inline markup also occur in YAML.
            if line.trimmed.hasPrefix("#") { continue }
            if source.first(quote, line.text) != nil { score += 3; distinctive = true }
            if source.first(list, line.text) != nil { score += line.trimmed.hasPrefix("- ") ? 1 : 2 }
            if source.first(link, line.text) != nil || source.first(reference, line.text) != nil { score += 3; distinctive = true }
            if source.first(strong, line.text) != nil || source.first(emphasis, line.text) != nil
                || source.first(inlineCode, line.text) != nil { score += 2; distinctive = true }
            if index > 0, source.first(setext, line.text) != nil, !source.lines[index - 1].trimmed.isEmpty {
                score += 3; distinctive = true
            }
        }
        guard score >= 2 else { return 0 }
        return distinctive ? 80 : 50
    }

    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] {
        let lines = source.lines
        var result: [SyntaxSpan] = [], fenced: (character: Character, count: Int)?
        let front = YAMLSyntax.frontMatterEnd(in: source)
        func add(_ range: NSRange, _ kind: SyntaxKind, _ line: SyntaxLine) {
            if range.length > 0 { result.append(SyntaxSpan(range: NSRange(location: line.offset + range.location, length: range.length), kind: kind)) }
        }
        if let front {
            result += YAMLSyntax.spans(in: Array(lines[0...front]), source: source)
        }
        for (index, line) in lines.enumerated() {
            if source.cancelled() { break }
            if let front, index <= front { continue }
            let fenceMatch = source.first(fence, line.text)
            if let active = fenced {
                add(NSRange(location: 0, length: line.length), .code, line)
                if let match = fenceMatch {
                    let delimiter = (line.text as NSString).substring(with: match.range(at: 1))
                    let suffix = (line.text as NSString).substring(with: match.range(at: 2))
                    if delimiter.first == active.character, delimiter.count >= active.count, suffix.trimmingCharacters(in: .whitespaces).isEmpty { fenced = nil }
                }
                continue
            }
            if let match = fenceMatch {
                let delimiter = (line.text as NSString).substring(with: match.range(at: 1))
                fenced = (delimiter.first!, delimiter.count)
                add(NSRange(location: 0, length: line.length), .code, line); continue
            }
            if source.first(heading, line.text) != nil { add(NSRange(location: 0, length: line.length), .heading, line) }
            if source.first(rule, line.text) != nil { add(NSRange(location: 0, length: line.length), .marker, line); continue }
            if index > 0, source.first(setext, line.text) != nil, !lines[index - 1].trimmed.isEmpty {
                add(NSRange(location: 0, length: lines[index - 1].length), .heading, lines[index - 1])
                add(NSRange(location: 0, length: line.length), .marker, line); continue
            }
            for expression in [list, quote] {
                if let match = source.first(expression, line.text) { add(match.range, .marker, line) }
            }
            let codes = source.matches(inlineCode, line.text)
            for (expression, kind) in [(strong, SyntaxKind.emphasis), (emphasis, .emphasis), (link, .link), (reference, .link)] {
                for match in source.matches(expression, line.text) where !codes.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
                    add(match.range, kind, line)
                }
            }
            for match in codes { add(match.range, .code, line) }
        }
        return result
    }}
