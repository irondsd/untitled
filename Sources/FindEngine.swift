import Foundation

final class FindCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct FindQuery: Equatable {
    var text: String
    var regex = false
    var caseSensitive = false
}

struct FindEdit {
    let range: NSRange
    let replacement: String
}

struct SelectionMatches {
    let ranges: [NSRange]

    init(source: String, text: String, cancelled: @escaping () -> Bool = { false }) throws {
        guard !text.isEmpty else { ranges = []; return }
        // Lookahead includes overlapping literals, so a manually selected substring
        // can seed matching at any offset rather than only the first match's alignment.
        let pattern = "(?=" + NSRegularExpression.escapedPattern(for: text) + ")"
        let found = try FindResults(source: source, query: FindQuery(text: pattern, regex: true, caseSensitive: true), cancelled: cancelled)
        let length = (text as NSString).length
        ranges = found.matches.map { NSRange(location: $0.range.location, length: length) }
    }

    func next(after range: NSRange, excluding selections: [NSRange]) -> NSRange? {
        let available: (NSRange) -> Bool = { candidate in
            !selections.contains { NSIntersectionRange($0, candidate).length > 0 }
        }
        return ranges.first { $0.location >= NSMaxRange(range) && available($0) } ?? ranges.first(where: available)
    }
}

/// UTF-16 ranges match NSTextView's indexing, including emoji and combining marks.
struct FindResults {
    let source: String
    let query: FindQuery
    let expression: NSRegularExpression
    let matches: [NSTextCheckingResult]

    init(source: String, query: FindQuery, cancelled: @escaping () -> Bool = { false }) throws {
        self.source = source
        self.query = query
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        let pattern = query.text.isEmpty ? "(?!)" : query.regex ? query.text : NSRegularExpression.escapedPattern(for: query.text)
        expression = try NSRegularExpression(pattern: pattern, options: options)
        var found: [NSTextCheckingResult] = []
        if !query.text.isEmpty {
            expression.enumerateMatches(in: source, options: [.reportProgress], range: NSRange(location: 0, length: (source as NSString).length)) { match, _, stop in
                if cancelled() { stop.pointee = true }
                else if let match { found.append(match) }
            }
        }
        matches = found
    }

    func edits(replacement: String, indexes: [Int]) throws -> [FindEdit] {
        let template = query.regex ? try replacementTemplate(replacement) : replacement
        return indexes.map { index in
            let match = matches[index]
            return FindEdit(range: match.range, replacement: query.regex
                ? expression.replacementString(for: match, in: source, offset: 0, template: template)
                : replacement)
        }
    }

    private func replacementTemplate(_ input: String) throws -> String {
        let chars = Array(input)
        var output = "", index = 0
        let digits = String(expression.numberOfCaptureGroups).count
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count {
                index += 1
                switch chars[index] {
                case "n": output += "\n"
                case "r": output += "\r"
                case "t": output += "\t"
                default: output.append("\\"); output.append(chars[index])
                }
            } else if char == "$" {
                var end = index + 1
                while end < chars.count, end <= index + digits, chars[end].isASCII, chars[end].isNumber { end += 1 }
                if end > index + 1, let group = Int(String(chars[(index + 1)..<end])), group > expression.numberOfCaptureGroups {
                    throw NSError(domain: "Find", code: 1, userInfo: [NSLocalizedDescriptionKey: "No capture group $\(group). Use parentheses in Find, or \\$ for a literal dollar sign."])
                }
                output.append(char)
            } else { output.append(char) }
            index += 1
        }
        return output
    }
}
