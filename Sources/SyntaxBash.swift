import Foundation

/// Bash and POSIX shell scripts. A single-pass lexer tracks command position, so only the first word of
/// a command is colored as a command and reserved words only count where the shell reads them.
struct BashSyntax: SyntaxDefinition {
    static let language = NoteLanguage.bash
    private static let shebang = SyntaxRegex.compile(#"^#![^\r\n]*\b(?:ba|z|k|da|a)?sh\b"#)

    static func confidence(in source: SyntaxSource) -> Int {
        if let first = source.lines.first, source.first(shebang, first.text) != nil { return 100 }
        let lexer = BashLexer(source)
        _ = lexer.scan()
        guard !source.cancelled() else { return 0 }
        // Lines opening with `word:` are YAML mappings or prose labels, not commands.
        guard lexer.labels < 2, lexer.score + (lexer.blocks ? 3 : 0) >= 3 else { return 0 }
        // Blocks, test brackets, fd redirections and heredocs never occur in JavaScript, YAML or prose.
        return lexer.strong ? 92 : 60
    }

    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] { BashLexer(source).scan() }
}

private final class BashLexer {
    private struct Heredoc {
        let delimiter: String
        let stripTabs: Bool
        let interpolated: Bool
    }
    private enum Expect { case none, functionName, test, setOptions, shellArgument }
    /// Parse state of one command list; command substitutions save and restore it.
    private struct Mode {
        var command = true, declaring = false, target = false, pattern = false, caseIn = false
        var untilIn = 0, cases = 0, expect = Expect.none
    }
    private static let keywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done",
        "function", "time", "coproc", "!", "[[", "]]"
    ]
    private static let commands: Set<String> = [
        "sudo", "echo", "printf", "cd", "pwd", "ls", "mkdir", "rmdir", "rm", "cp", "mv", "ln", "chmod", "chown", "grep",
        "egrep", "sed", "awk", "curl", "wget", "git", "brew", "apt", "apt-get", "yum", "dnf", "pacman", "npm", "npx", "pnpm",
        "yarn", "pip", "pip3", "python3", "docker", "kubectl", "ssh", "scp", "rsync", "tar", "unzip", "export", "unset",
        "alias", "source", "exit", "eval", "exec", "cargo", "local", "declare", "readonly", "typeset", "shift", "trap"
    ]
    /// Commands that are also English words count only with a flag, path or variable argument.
    private static let wordCommands: Set<String> = [
        "cat", "find", "sort", "head", "tail", "touch", "kill", "make", "which", "diff", "xargs", "env", "ps", "wc", "cut", "tr", "go", "open"
    ]
    private static let declarations: Set<String> = ["export", "local", "declare", "readonly", "typeset"]

    private let source: SyntaxSource
    private let units: [UInt16]
    private var position = 0, limit: Int
    private var spans: [SyntaxSpan] = []
    private var mode = Mode()
    private var heredocs: [Heredoc] = []
    private var backticks = 0
    // Detection evidence.
    private(set) var score = 0, labels = 0
    private var blockStrong = false, openers: [String: Int] = [:]
    /// A complete `then…fi`, `do…done` or `case…esac` block.
    var blocks: Bool {
        [("then", "fi"), ("do", "done"), ("case", "esac")].contains { openers[$0.0, default: 0] > 0 && openers[$0.1, default: 0] > 0 }
    }
    var strong: Bool { blockStrong || blocks }

    init(_ source: SyntaxSource) {
        self.source = source
        units = Array(source.text.utf16)
        limit = units.count
    }
    private func unit(_ offset: Int = 0) -> UInt16 { position + offset < limit ? units[position + offset] : 0 }
    private func add(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
        if end > start { spans.append(SyntaxSpan(range: NSRange(location: start, length: end - start), kind: kind)) }
    }
    private func evidence(_ points: Int, strong: Bool = false) {
        score += strong ? 3 : points
        if strong { blockStrong = true }
    }
    private func digit(_ value: UInt16) -> Bool { (48...57).contains(value) }
    private func nameStart(_ value: UInt16) -> Bool { value == 95 || (65...90).contains(value) || (97...122).contains(value) }
    private func namePart(_ value: UInt16) -> Bool { nameStart(value) || digit(value) }
    private func blank(_ value: UInt16) -> Bool { value == 32 || value == 9 || value == 13 || value == 12 }
    /// Metacharacters end an unquoted word.
    private func breaks(_ value: UInt16) -> Bool {
        blank(value) || [UInt16(10), 59, 38, 124, 40, 41, 60, 62].contains(value) || (value == 96 && backticks > 0)
    }
    private func string(_ start: Int, _ end: Int) -> String { String(decoding: units[start..<end], as: UTF16.self) }

    func scan() -> [SyntaxSpan] {
        while position < limit && !source.cancelled() { list(until: nil) }
        return spans
    }

    /// A command list, ending at `closing` for `$(…)`, `<(…)` and backticks.
    private func list(until closing: UInt16?) {
        let saved = mode
        mode = Mode()
        defer { mode = saved }
        var depth = 0
        while position < limit && !source.cancelled() {
            let character = unit()
            if character == 10 { position += 1; newline(); continue }
            if blank(character) { position += 1; continue }
            if character == 92 && (unit(1) == 10 || unit(1) == 13 && unit(2) == 10) { position += unit(1) == 10 ? 2 : 3; continue }
            if character == 35 {
                var end = position
                while end < limit && units[end] != 10 && units[end] != 13 { end += 1 }
                add(position, end, .comment); position = end; continue
            }
            if character == 96 && closing == 96 { add(position, position + 1, .marker); position += 1; return }
            if character == 41 {
                add(position, position + 1, .marker); position += 1
                if depth > 0 { depth -= 1; mode.command = false }
                else if mode.cases > 0 { mode.pattern = false; mode.command = true }
                else if closing == 41 { return }
                continue
            }
            if character == 40 {
                if unit(1) == 40 && (mode.command || mode.untilIn == 2) {
                    mode.untilIn = 0; mode.command = false
                    arithmetic(2); continue
                }
                add(position, position + 1, .marker); position += 1
                if !mode.pattern { depth += 1; mode.command = true }
                continue
            }
            if character == 59 {
                let length = unit(1) == 59 ? (unit(2) == 38 ? 3 : 2) : (unit(1) == 38 ? 2 : 1)
                add(position, position + length, .marker); position += length
                endCommand()
                if length > 1 && mode.cases > 0 { mode.pattern = true }
                continue
            }
            if character == 124 || character == 38 && unit(1) != 62 {
                let length = unit(1) == character || character == 124 && unit(1) == 38 ? 2 : 1
                add(position, position + length, .marker); position += length
                if length == 2 || character == 124 { evidence(1) }
                endCommand(); continue
            }
            if digit(character) {
                var end = position
                while end < limit && digit(units[end]) { end += 1 }
                if end < limit && (units[end] == 60 || units[end] == 62) {
                    if string(position, end) == "2" && units[end] == 62 { evidence(0, strong: true) }
                    add(position, end, .number); position = end
                    redirection(); continue
                }
            }
            if character == 60 || character == 62 || character == 38 { redirection(); continue }
            word()
        }
    }

    private func endCommand() {
        mode.command = true; mode.declaring = false; mode.target = false; mode.untilIn = 0; mode.expect = .none
    }

    private func newline() {
        mode.command = true; mode.declaring = false; mode.target = false; mode.expect = .none
        let pending = heredocs
        heredocs = []
        for heredoc in pending { body(heredoc) }
    }

    private func redirection() {
        let start = position
        if unit() == 60 && unit(1) == 60 {
            if unit(2) == 60 { add(start, start + 3, .marker); position += 3; mode.target = true; return }
            let stripTabs = unit(2) == 45
            position += stripTabs ? 3 : 2
            add(start, position, .marker)
            heredoc(stripTabs: stripTabs); return
        }
        if (unit() == 60 || unit() == 62) && unit(1) == 40 {
            // Process substitution.
            add(start, start + 2, .marker); position += 2
            list(until: 41); return
        }
        if unit() == 38 { position += 1; evidence(0, strong: true) }
        let operation = unit()
        position += 1
        if operation == 62 && (unit() == 62 || unit() == 124) || operation == 60 && unit() == 62 { position += 1 }
        if unit() == 38 && units[start] != 38 {
            // Duplicating a descriptor, such as >&2 or 2>&1.
            position += 1
            if unit() == 45 { position += 1 } else { while position < limit && digit(unit()) { position += 1 } }
            add(start, position, .marker)
            evidence(0, strong: true); return
        }
        add(start, position, .marker)
        var cursor = position
        while cursor < limit && (units[cursor] == 32 || units[cursor] == 9) { cursor += 1 }
        if cursor + 9 <= limit && string(cursor, cursor + 9) == "/dev/null" { evidence(0, strong: true) }
        mode.target = true
    }

    private func heredoc(stripTabs: Bool) {
        while position < limit && (unit() == 32 || unit() == 9) { position += 1 }
        let start = position
        var delimiter: [UInt16] = [], quoted = false
        while position < limit && !breaks(unit()) {
            let character = unit()
            if character == 39 || character == 34 {
                quoted = true
                position += 1
                while position < limit && unit() != character && unit() != 10 { delimiter.append(unit()); position += 1 }
                if unit() == character { position += 1 }
                continue
            }
            if character == 92 { quoted = true; position += 1; continue }
            delimiter.append(character); position += 1
        }
        add(start, position, .marker)
        mode.command = false
        guard !delimiter.isEmpty else { return }
        heredocs.append(Heredoc(delimiter: String(decoding: delimiter, as: UTF16.self), stripTabs: stripTabs, interpolated: !quoted))
    }

    /// Heredoc text runs to a line holding only the delimiter; unquoted delimiters still expand variables.
    private func body(_ heredoc: Heredoc) {
        let start = position
        var cursor = position, end = limit, closing: (Int, Int)?
        while cursor < limit {
            var lineEnd = cursor
            while lineEnd < limit && units[lineEnd] != 10 { lineEnd += 1 }
            var contentStart = cursor, contentEnd = lineEnd
            if contentEnd > contentStart && units[contentEnd - 1] == 13 { contentEnd -= 1 }
            if heredoc.stripTabs { while contentStart < contentEnd && units[contentStart] == 9 { contentStart += 1 } }
            if string(contentStart, contentEnd) == heredoc.delimiter {
                end = cursor; closing = (contentStart, contentEnd); break
            }
            cursor = lineEnd + 1
        }
        if heredoc.interpolated {
            let outer = limit
            limit = end
            var segment = position
            while position < limit && !source.cancelled() {
                let character = unit()
                if character == 92 { position = min(limit, position + 2); continue }
                if character == 36 && expands() || character == 96 {
                    add(segment, position, .string)
                    if character == 96 { backtick() } else { expansion() }
                    segment = position; continue
                }
                position += 1
            }
            add(segment, min(position, end), .string)
            limit = outer
        } else {
            add(start, end, .string)
        }
        guard let closing else { position = limit; return }
        add(closing.0, closing.1, .marker)
        position = closing.1
        if heredoc.delimiter.allSatisfy({ $0.isUppercase || $0 == "_" }) || !heredoc.interpolated { evidence(0, strong: true) }
    }

    private func word() {
        let start = position
        if mode.target {
            mode.target = false
            parts()
            if position == start { position += 1 }
            return
        }
        let command = mode.command
        if command || mode.declaring, assignment() { return }
        let plain = parts()
        if position == start { position += 1; return }
        let text = string(start, position)
        let inKeyword = mode.untilIn == 1 && text == "in"
        if mode.untilIn > 0 { mode.untilIn -= 1 }
        let expect = mode.expect
        mode.expect = .none
        guard plain else {
            if command { mode.command = false }
            else if expect == .test && text.contains("$") { evidence(0, strong: true) }
            else if expect == .shellArgument && text.contains("$") { evidence(1) }
            return
        }
        if inKeyword {
            add(start, position, .keyword)
            mode.command = false
            if mode.caseIn { mode.pattern = true; mode.caseIn = false }
            return
        }
        if mode.pattern {
            if text == "esac" { add(start, position, .keyword); keyword(text) }
            return
        }
        if text == "{" || text == "}" || text == "]" || text == "[" && command {
            add(start, position, .marker)
            mode.command = text == "{"
            if text == "[" { mode.expect = .test }
            return
        }
        if command && Self.keywords.contains(text) || text == "]]" {
            add(start, position, .keyword)
            keyword(text); return
        }
        if command || expect == .functionName {
            add(start, position, .function)
            mode.command = false
            if expect == .functionName {
                // `function name {` without parentheses is shell-only; JavaScript always has them.
                var cursor = position
                while cursor < limit && blank(units[cursor]) { cursor += 1 }
                if cursor < limit && (units[cursor] == 123 || units[cursor] == 10) { evidence(0, strong: true) }
                return
            }
            if unit() == 40 && unit(1) == 41 { evidence(2) }
            if text.hasSuffix(":") && text.count > 1 { labels += 1 }
            if Self.commands.contains(text) { evidence(1) }
            else if Self.wordCommands.contains(text) { mode.expect = .shellArgument }
            if Self.declarations.contains(text) { mode.declaring = true; if text != "export" { evidence(0, strong: true) } }
            if text == "set" { mode.expect = .setOptions }
            return
        }
        let units = Array(text.utf16)
        if units.allSatisfy(digit) { add(start, position, .number); return }
        if units.count > 1 && (units[0] == 45 || units[0] == 43 && expect == .setOptions) && (units[1] == 45 || nameStart(units[1])) {
            add(start, position, .attribute)
            if expect == .test && units.count == 2 { evidence(0, strong: true) }
            if expect == .setOptions && text.dropFirst().allSatisfy({ "euxo".contains($0) }) { evidence(0, strong: true) }
            if expect == .shellArgument { evidence(1) }
            return
        }
        if expect == .shellArgument && (text.contains("/") || text.hasPrefix("~") || text.contains("*")) { evidence(1) }
    }

    private func keyword(_ text: String) {
        mode.command = !["fi", "done", "esac", "[[", "]]", "for", "select", "case", "function"].contains(text)
        switch text {
        case "for", "select", "case":
            mode.untilIn = 2; mode.caseIn = text == "case"
            if text == "case" { mode.cases += 1 }
        case "esac": mode.cases = max(0, mode.cases - 1); mode.pattern = false
        case "function": mode.expect = .functionName
        case "[[": evidence(0, strong: true)
        default: break
        }
        if ["then", "fi", "do", "done", "case", "esac"].contains(text) { openers[text, default: 0] += 1 }
    }

    /// `NAME=value`, `NAME+=value`, `NAME[index]=value` and `NAME=(array items)`.
    private func assignment() -> Bool {
        guard nameStart(unit()) else { return false }
        var cursor = position
        while cursor < limit && namePart(units[cursor]) { cursor += 1 }
        if cursor < limit && units[cursor] == 91 {
            while cursor < limit && units[cursor] != 93 && units[cursor] != 10 { cursor += 1 }
            guard cursor < limit && units[cursor] == 93 else { return false }
            cursor += 1
        }
        let nameEnd = cursor
        if cursor < limit && units[cursor] == 43 { cursor += 1 }
        guard cursor < limit && units[cursor] == 61 else { return false }
        add(position, nameEnd, .key)
        add(nameEnd, cursor + 1, .marker)
        if string(position, nameEnd).allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) { evidence(1) }
        position = cursor + 1
        mode.expect = .none
        if unit() == 40 {
            add(position, position + 1, .marker); position += 1
            while position < limit && !source.cancelled() {
                let character = unit()
                if blank(character) || character == 10 { position += 1; continue }
                if character == 41 { add(position, position + 1, .marker); position += 1; break }
                if character == 35 {
                    var end = position
                    while end < limit && units[end] != 10 { end += 1 }
                    add(position, end, .comment); position = end; continue
                }
                let before = position
                parts()
                if position == before { position += 1 }
            }
            evidence(1)
        } else {
            parts()
        }
        return true
    }

    /// The pieces of one word: quotes, expansions, escapes and plain text. Returns true when it was all plain text.
    @discardableResult private func parts() -> Bool {
        var plain = true
        while position < limit && !breaks(unit()) {
            switch unit() {
            case 39: plain = false; quoted(position, escapes: false)
            case 34: plain = false; doubleQuoted()
            case 36:
                if unit(1) == 39 { plain = false; quoted(position + 1, escapes: true) }
                else if unit(1) == 34 { plain = false; add(position, position + 1, .string); position += 1; doubleQuoted() }
                else if expands() { plain = false; expansion() }
                else { position += 1 }
            case 96: plain = false; backtick()
            case 92: plain = false; position = min(limit, position + 2)
            default: position += 1
            }
        }
        return plain
    }

    /// `'…'` has no escapes; `$'…'` honors backslashes.
    private func quoted(_ quote: Int, escapes: Bool) {
        let start = position
        var cursor = quote + 1
        while cursor < limit && units[cursor] != 39 {
            cursor += escapes && units[cursor] == 92 ? 2 : 1
        }
        position = min(limit, cursor + 1)
        add(start, position, .string)
    }

    private func doubleQuoted() {
        var segment = position
        position += 1
        while position < limit && !source.cancelled() {
            let character = unit()
            if character == 34 { position += 1; break }
            if character == 92 { position = min(limit, position + 2); continue }
            if character == 96 && backticks > 0 { break }
            if character == 36 && expands() || character == 96 {
                add(segment, position, .string)
                if character == 96 { backtick() } else {
                    if digit(unit(1)) { evidence(2) }
                    expansion()
                }
                segment = position; continue
            }
            position += 1
        }
        add(segment, position, .string)
    }

    private func expands() -> Bool {
        let next = unit(1)
        return next == 123 || next == 40 || nameStart(next) || digit(next) || [UInt16(64), 42, 35, 63, 36, 33, 45].contains(next)
    }

    private func expansion() {
        let start = position, next = unit(1)
        if next == 40 {
            if unit(2) == 40 { arithmetic(3); return }
            add(start, start + 2, .marker); position += 2
            evidence(1)
            list(until: 41); return
        }
        if next == 123 {
            var cursor = start + 2, depth = 1
            while cursor < limit && depth > 0 && units[cursor] != 10 {
                if units[cursor] == 92 { cursor += 2; continue }
                if units[cursor] == 123 { depth += 1 } else if units[cursor] == 125 { depth -= 1 }
                cursor += 1
            }
            position = min(cursor, limit)
            add(start, position, .key)
            evidence(1); return
        }
        position += 1
        if nameStart(next) { while position < limit && namePart(unit()) { position += 1 } }
        else {
            position += 1
            if [UInt16(64), 35, 63].contains(next) { evidence(2) }
        }
        add(start, position, .key)
        if nameStart(next) { evidence(1) }
    }

    private func backtick() {
        add(position, position + 1, .marker); position += 1
        backticks += 1
        list(until: 96)
        backticks -= 1
    }

    /// `((…))` and `$((…))`: names are variables, and nothing inside is a command.
    private func arithmetic(_ opening: Int) {
        add(position, position + opening, .marker); position += opening
        var depth = 0
        while position < limit && !source.cancelled() {
            let character = unit()
            if character == 41 {
                if depth == 0 {
                    let length = unit(1) == 41 ? 2 : 1
                    add(position, position + length, .marker); position += length; return
                }
                depth -= 1
            } else if character == 40 { depth += 1 }
            else if character == 36 && expands() { expansion(); continue }
            else if digit(character) || nameStart(character) {
                let start = position
                while position < limit && (namePart(unit()) || unit() == 35) { position += 1 }
                add(start, position, digit(character) ? .number : .key); continue
            }
            position += 1
        }
    }
}
