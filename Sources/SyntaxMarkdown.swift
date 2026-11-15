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
    /// A bare web address; trailing punctuation and unbalanced closing brackets are trimmed afterwards.
    private static let bareURL = SyntaxRegex.compile(#"(?<![\w/@.:])https?://[^\s<>"'`|\\]+"#)
    /// A table's `|---|:--:|` line, which needs at least one pipe.
    private static let tableDelimiter = SyntaxRegex.compile(#"^ {0,3}(?=[^|]*\|)\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)

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
            if index > 0, line.text.contains("|"), source.lines[index - 1].text.contains("|"),
               source.first(tableDelimiter, line.text) != nil {
                score += 3; distinctive = true
            }
            if index > 0, source.first(setext, line.text) != nil, !source.lines[index - 1].trimmed.isEmpty {
                score += 3; distinctive = true
            }
        }
        guard score >= 2 else { return 0 }
        return distinctive ? 80 : 50
    }

    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] { tokenize(source).spans }

    /// The URL of `[text](url "title")`, `![alt](url)` or `<url>`, when it is a web or mail address.
    static func linkTarget(_ markup: String) -> String? {
        let target: Substring
        if markup.hasPrefix("<") { target = markup.dropFirst().dropLast() }
        else if let open = markup.range(of: "](") { target = markup[open.upperBound...].prefix { $0 != " " && $0 != ")" } }
        else { return nil }
        return isWebAddress(String(target)) ? String(target) : nil
    }

    /// Only these open from a note: relative paths and other schemes could launch arbitrary apps.
    static func isWebAddress(_ target: String) -> Bool {
        guard let url = URL(string: target), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "mailto" { return target.count > 7 }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    /// Drops sentence punctuation after an address, and a closing bracket it never opened.
    static func trimmedURL(_ range: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(range)
        let punctuation = Set(".,:;!?*_~".utf16)
        while end > range.location {
            let character = text.character(at: end - 1)
            if punctuation.contains(character) { end -= 1; continue }
            if let open = [UInt16(41): UInt16(40), 93: 91][character] {
                let body = text.substring(with: NSRange(location: range.location, length: end - range.location)).utf16
                if body.filter({ $0 == character }).count > body.filter({ $0 == open }).count { end -= 1; continue }
            }
            break
        }
        return NSRange(location: range.location, length: end - range.location)
    }

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
        func inline(_ line: SyntaxLine) {
            let codes = source.matches(inlineCode, line.text)
            func inCode(_ range: NSRange) -> Bool { codes.contains { NSIntersectionRange($0.range, range).length > 0 } }
            let text = line.text as NSString
            var linked: [NSRange] = []
            for (expression, kind) in [(strong, SyntaxKind.emphasis), (emphasis, .emphasis), (link, .link), (reference, .link)] {
                for match in source.matches(expression, line.text) where !inCode(match.range) {
                    add(match.range, kind, line)
                    if expression === strong { delimiters(match.range, 2, line); style(match.range, .strong, line) }
                    if expression === emphasis { delimiters(match.range, 1, line); style(match.range, .emphasis, line) }
                    if expression === link {
                        linked.append(match.range)
                        if let target = linkTarget(text.substring(with: match.range)) { style(match.range, .link(target), line) }
                    }
                }
            }
            // Bare addresses, including a reference definition's target.
            for match in source.matches(bareURL, line.text) {
                let range = trimmedURL(match.range, in: text)
                guard !inCode(range), !linked.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                let target = text.substring(with: range)
                guard isWebAddress(target) else { continue }
                add(range, .link, line)
                style(range, .link(target), line)
            }
            for match in codes {
                add(match.range, .code, line)
                delimiters(match.range, match.range(at: 1).length, line)
                style(match.range, .inlineCode, line)
            }
        }
        if let front {
            result += YAMLSyntax.spans(in: Array(lines[0...front]), source: source)
        }
        let text = source.text as NSString
        var tableEnd = -1
        for (index, line) in lines.enumerated() {
            if source.cancelled() { break }
            if let front, index <= front { continue }
            // Rows of a table found on an earlier line.
            if index <= tableEnd { continue }
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
            if index + 1 < lines.count, line.text.contains("|"), lines[index + 1].text.contains("|"),
               source.first(heading, line.text) == nil, let table = MarkdownTables.parse(text, header: line.offset) {
                styles.append(SyntaxStyleSpan(range: table.range, style: .table))
                for (offset, row) in table.rows.enumerated() {
                    let rowLine = lines[index + offset]
                    if row.isDelimiter { add(whole(rowLine), .tableRule, rowLine); continue }
                    inline(rowLine)
                    for pipe in row.pipes { result.append(SyntaxSpan(range: NSRange(location: pipe, length: 1), kind: .tableRule)) }
                }
                tableEnd = index + table.rows.count - 1
                continue
            }
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
            inline(line)
        }
        return (result, styles)
    }
}
