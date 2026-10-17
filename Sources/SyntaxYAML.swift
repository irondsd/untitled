import Foundation

struct YAMLSyntax: SyntaxDefinition {
    static let language = NoteLanguage.yaml
    private static let mapping = SyntaxRegex.compile(#"^ *(?:- +)?((?:[^\s\[\]{},:#'\"][^:#]*?|\"(?:[^\"\\]|\\.)*\"|'(?:[^']|'')*')) *:(?=\s|$)"#)
    private static let flowKey = SyntaxRegex.compile(#"(?:[\{,] *)([^\s\[\]{},:#'\"][^,:{}\[\]]*?) *:(?=\s|$)"#)
    private static let simpleKey = SyntaxRegex.compile(#"^[a-z_][a-z0-9_.-]*$"#)
    private static let yamlWord = SyntaxRegex.compile(#"(?i)^(?:true|false|null|~)$"#)
    private static let yamlNumber = SyntaxRegex.compile(#"(?i)^[+-]?(?:0x[0-9a-f]+|0o[0-7]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:e[+-]?[0-9]+)?|\.inf|\.nan)$"#)
    private static let blockScalar = SyntaxRegex.compile(#"(?:^|: *|- +)[|>](?:[1-9][+-]?|[+-][1-9]?)?(?: +#.*)? *$"#)
    private static let anchor = SyntaxRegex.compile(#"[&*!][^\s,\[\]{}]+"#)

    static func confidence(in source: SyntaxSource) -> Int {
        var mappings = 0, structured = false, scalarIndent: Int?, hasBlock = false
        for line in source.lines {
            if source.cancelled() { return 0 }
            let value = line.trimmed
            if value.isEmpty { continue }
            if let indent = scalarIndent {
                if line.indent > indent { continue }
                scalarIndent = nil
            }
            if value.hasPrefix("%YAML ") { return 100 }
            if let match = source.first(mapping, line.text) {
                mappings += 1
                let tail = (line.text as NSString).substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces)
                let scalar = tail.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
                let key = (line.text as NSString).substring(with: match.range(at: 1))
                let block = source.first(blockScalar, line.text) != nil
                if source.first(simpleKey, key) != nil || tail.isEmpty
                    || source.first(yamlWord, scalar) != nil || source.first(yamlNumber, scalar) != nil
                    || tail.hasPrefix("[") || tail.hasPrefix("{") || tail.hasPrefix("\"") || tail.hasPrefix("'")
                    || tail.hasPrefix("&") || block || line.indent > 0 || value.hasPrefix("- ") {
                    structured = true
                }
                if block { scalarIndent = line.indent; hasBlock = true }
            } else if value.hasPrefix("{"), source.first(flowKey, line.text) != nil {
                mappings += 2
            } else if value.hasPrefix("- ") {
                let scalar = String(value.dropFirst(2)).components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
                if source.first(yamlWord, scalar) != nil || source.first(yamlNumber, scalar) != nil {
                    mappings += 1; structured = true
                }
            }
        }
        guard mappings >= 2 || (mappings > 0 && structured) else { return 0 }
        // A literal/folded YAML block owns any code or Markdown inside it.
        return hasBlock ? 95 : 70
    }

    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] {
        spans(in: source.lines, source: source)
    }

    static func frontMatterEnd(in source: SyntaxSource) -> Int? {
        let lines = source.lines
        guard lines.first?.trimmed == "---", lines.count > 2 else { return nil }
        for index in 1..<lines.count where lines[index].trimmed == "---" {
            // A closing delimiter plus a following body distinguishes front matter from a YAML stream.
            if lines[1..<index].contains(where: { source.first(mapping, $0.text) != nil }),
               lines.dropFirst(index + 1).contains(where: { !$0.trimmed.isEmpty }) { return index }
            return nil
        }
        return nil
    }

    static func spans(in lines: [SyntaxLine], source: SyntaxSource) -> [SyntaxSpan] {
        var result: [SyntaxSpan] = [], scalarIndent: Int?
        func add(_ range: NSRange, _ kind: SyntaxKind, _ line: SyntaxLine) {
            if range.length > 0 { result.append(SyntaxSpan(range: NSRange(location: line.offset + range.location, length: range.length), kind: kind)) }
        }
        for line in lines {
            if source.cancelled() { break }
            if let indent = scalarIndent {
                if line.trimmed.isEmpty || line.indent > indent {
                    add(NSRange(location: 0, length: line.length), .string, line)
                    continue
                }
                scalarIndent = nil
            }
            if ["---", "..."].contains(line.trimmed) || line.trimmed.hasPrefix("%YAML ") || line.trimmed.hasPrefix("%TAG ") {
                add(NSRange(location: 0, length: line.length), .marker, line); continue
            }
            let lineText = line.text as NSString
            // Scan quotes/comments first so colons, hashes and typed-looking values inside strings stay literal.
            var protected: [NSRange] = [], position = 0
            while position < lineText.length {
                let character = lineText.character(at: position)
                let previous = position > 0 ? lineText.character(at: position - 1) : 32
                let boundary = position == 0 || [UInt16(32), 9, 58, 44, 91, 123, 45].contains(previous)
                if character == 35 && (position == 0 || previous == 32 || previous == 9) {
                    let range = NSRange(location: position, length: lineText.length - position)
                    add(range, .comment, line); protected.append(range); break
                }
                if (character == 34 || character == 39) && boundary {
                    let start = position
                    position += 1
                    while position < lineText.length {
                        let next = lineText.character(at: position)
                        if character == 34 && next == 92 { position = min(lineText.length, position + 2); continue }
                        if next == character {
                            if character == 39 && position + 1 < lineText.length && lineText.character(at: position + 1) == 39 { position += 2; continue }
                            position += 1; break
                        }
                        position += 1
                    }
                    let range = NSRange(location: start, length: position - start)
                    add(range, .string, line); protected.append(range); continue
                }
                position += 1
            }
            let key = source.first(mapping, line.text)
            var keys = key.map { [$0.range(at: 1)] } ?? []
            keys += source.matches(flowKey, line.text).map { $0.range(at: 1) }.filter { range in
                !protected.contains { NSIntersectionRange($0, range).length > 0 }
            }
            for range in keys { add(range, .key, line) }
            func isProtected(_ range: NSRange) -> Bool {
                protected.contains { NSIntersectionRange($0, range).length > 0 }
                    || keys.contains { NSIntersectionRange($0, range).length > 0 }
            }
            // Value words are delimited by YAML structure, not by word boundaries (URLs remain plain).
            let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",[]{}"))
            var start = 0
            while start < lineText.length {
                let unit = lineText.character(at: start)
                if let scalar = UnicodeScalar(unit), separators.contains(scalar) { start += 1; continue }
                var end = start + 1
                while end < lineText.length {
                    if let scalar = UnicodeScalar(lineText.character(at: end)), separators.contains(scalar) { break }
                    end += 1
                }
                let range = NSRange(location: start, length: end - start)
                let word = lineText.substring(with: range)
                if !isProtected(range) {
                    var before = start - 1, after = end
                    while before >= 0 && [UInt16(32), 9].contains(lineText.character(at: before)) { before -= 1 }
                    while after < lineText.length && [UInt16(32), 9].contains(lineText.character(at: after)) { after += 1 }
                    let valueStart = before < 0 || [UInt16(58), 91, 123, 44].contains(lineText.character(at: before))
                        || (before == line.indent && lineText.character(at: before) == 45)
                    let valueEnd = after == lineText.length || [UInt16(35), 44, 93, 125].contains(lineText.character(at: after))
                    if valueStart && valueEnd && source.first(yamlWord, word) != nil { add(range, .literal, line) }
                    else if valueStart && valueEnd && source.first(yamlNumber, word) != nil { add(range, .number, line) }
                    else if let match = source.first(anchor, word), match.range.location == 0 { add(range, .marker, line) }
                }
                start = end
            }
            for index in 0..<lineText.length where [UInt16(58), 44, 91, 93, 123, 125].contains(lineText.character(at: index)) {
                let range = NSRange(location: index, length: 1)
                if !isProtected(range), lineText.character(at: index) != 58 || index + 1 == lineText.length || [UInt16(32), 9].contains(lineText.character(at: index + 1)) {
                    add(range, .marker, line)
                }
            }
            if line.trimmed.hasPrefix("- ") { add(NSRange(location: line.indent, length: 1), .marker, line) }
            if let block = source.first(blockScalar, line.text) {
                let matched = lineText.substring(with: block.range)
                if let indicator = matched.firstIndex(where: { $0 == "|" || $0 == ">" }) {
                    let offset = block.range.location + (String(matched[..<indicator]) as NSString).length
                    let range = NSRange(location: offset, length: 1)
                    if !isProtected(range) {
                        scalarIndent = line.indent
                        add(range, .marker, line)
                    }
                }
            }
        }
        return result
    }

}
