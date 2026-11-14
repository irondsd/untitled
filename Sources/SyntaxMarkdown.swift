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

    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] { tokenize(source).spans }

    static func tokenize(_ source: SyntaxSource) -> (spans: [SyntaxSpan], styles: [SyntaxStyleSpan]) {
        let lines = source.lines
        var result: [SyntaxSpan] = [], styles: [SyntaxStyleSpan] = []
        var fenced: (character: Character, count: Int, start: Int)?
        // Only an ordinary paragraph line can become a setext heading title.
        var previousIsParagraph = false
        let front = YAMLSyntax.frontMatterEnd(in: source)
        func absolute(_ range: NSRange, _ line: SyntaxLine) -> NSRange {
            NSRange(location: line.offset + range.location, length: range.length)
        }
        func add(_ range: NSRange, _ kind: SyntaxKind, _ line: SyntaxLine) {
            if range.length > 0 { result.append(SyntaxSpan(range: absolute(range, line), kind: kind)) }
        }
        func style(_ range: NSRange, _ style: SyntaxStyle, _ line: SyntaxLine) {
            if range.length > 0 { styles.append(SyntaxStyleSpan(range: absolute(range, line), style: style)) }
        }
        /// Dims `length` delimiter characters at both ends of a match.
        func delimiters(_ range: NSRange, _ length: Int, _ line: SyntaxLine) {
            guard range.length >= length * 2 else { return }
            add(NSRange(location: range.location, length: length), .markup, line)
            add(NSRange(location: NSMaxRange(range) - length, length: length), .markup, line)
        }
        func whole(_ line: SyntaxLine) -> NSRange { NSRange(location: 0, length: line.length) }
        if let front {
            result += YAMLSyntax.spans(in: Array(lines[0...front]), source: source)
        }
        for (index, line) in lines.enumerated() {
            if source.cancelled() { break }
            if let front, index <= front { continue }
            let fenceMatch = source.first(fence, line.text)
            if let active = fenced {
                add(whole(line), .code, line)
                if let match = fenceMatch {
                    let delimiter = (line.text as NSString).substring(with: match.range(at: 1))
                    let suffix = (line.text as NSString).substring(with: match.range(at: 2))
                    if delimiter.first == active.character, delimiter.count >= active.count, suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                        fenced = nil
                        add(match.range(at: 1), .markup, line)
                        styles.append(SyntaxStyleSpan(range: NSRange(location: active.start, length: line.offset + line.length - active.start), style: .codeBlock))
                    }
                }
                if fenced != nil, index == lines.count - 1 {
                    // An unclosed fence runs to the end of the note.
                    styles.append(SyntaxStyleSpan(range: NSRange(location: active.start, length: line.offset + line.length - active.start), style: .codeBlock))
                }
                previousIsParagraph = false
                continue
            }
            if let match = fenceMatch {
                let delimiter = (line.text as NSString).substring(with: match.range(at: 1))
                fenced = (delimiter.first!, delimiter.count, line.offset)
                add(whole(line), .code, line)
                add(match.range(at: 1), .markup, line)
                if index == lines.count - 1 { style(whole(line), .codeBlock, line) }
                previousIsParagraph = false
                continue
            }
            let isParagraph = previousIsParagraph
            previousIsParagraph = false
            if let match = source.first(heading, line.text) {
                add(whole(line), .heading, line)
                let marks = line.text.drop(while: { $0 == " " }).prefix(while: { $0 == "#" }).count
                add(match.range, .markup, line)
                style(whole(line), .heading(marks), line)
            }
            if source.first(rule, line.text) != nil { add(whole(line), .marker, line); continue }
            if index > 0, source.first(setext, line.text) != nil, !lines[index - 1].trimmed.isEmpty {
                add(whole(lines[index - 1]), .heading, lines[index - 1])
                add(whole(line), .markup, line)
                if isParagraph {
                    style(whole(lines[index - 1]), .setextHeading(line.trimmed.hasPrefix("=") ? 1 : 2), lines[index - 1])
                    style(whole(line), .setextUnderline, line)
                }
                continue
            }
            previousIsParagraph = !line.trimmed.isEmpty && source.first(heading, line.text) == nil
            for expression in [list, quote] {
                if let match = source.first(expression, line.text) { add(match.range, .marker, line) }
            }
            let codes = source.matches(inlineCode, line.text)
            for (expression, kind) in [(strong, SyntaxKind.emphasis), (emphasis, .emphasis), (link, .link), (reference, .link)] {
                for match in source.matches(expression, line.text) where !codes.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
                    add(match.range, kind, line)
                    if expression === strong { delimiters(match.range, 2, line); style(match.range, .strong, line) }
                    if expression === emphasis { delimiters(match.range, 1, line); style(match.range, .emphasis, line) }
                }
            }
            for match in codes {
                add(match.range, .code, line)
                delimiters(match.range, match.range(at: 1).length, line)
                style(match.range, .inlineCode, line)
            }
        }
        return (result, styles)
    }
}
