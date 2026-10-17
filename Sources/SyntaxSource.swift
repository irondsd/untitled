import Foundation

struct SyntaxLine {
    let text: String
    let offset: Int
    var length: Int { (text as NSString).length }
    var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    var indent: Int { text.prefix(while: { $0 == " " }).count }
}

/// UTF-16 offsets are shared by every tokenizer and match TextKit, including CRLF and emoji.
struct SyntaxSource {
    let text: String
    let lines: [SyntaxLine]
    let cancelled: () -> Bool

    init(_ text: String, cancelled: @escaping () -> Bool = { false }) {
        self.text = text
        self.cancelled = cancelled
        let source = text as NSString
        var lines: [SyntaxLine] = [], start = 0
        while start < source.length && !cancelled() {
            var end = 0, contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            lines.append(SyntaxLine(text: source.substring(with: NSRange(location: start, length: contentsEnd - start)), offset: start))
            start = end
        }
        self.lines = lines
    }
    func first(_ expression: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        SyntaxRegex.first(expression, text, cancelled: cancelled)
    }
    func matches(_ expression: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        SyntaxRegex.matches(expression, text, cancelled: cancelled)
    }
}

enum SyntaxRegex {
    static func compile(_ pattern: String) -> NSRegularExpression {
        // Patterns are fixed internal constants, never user input.
        try! NSRegularExpression(pattern: pattern)
    }
    static func matches(_ expression: NSRegularExpression, _ text: String,
                                cancelled: @escaping () -> Bool) -> [NSTextCheckingResult] {
        var result: [NSTextCheckingResult] = []
        expression.enumerateMatches(in: text, options: [.reportProgress],
            range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
                if cancelled() { stop.pointee = true }
                else if let match { result.append(match) }
            }
        return result
    }
    static func first(_ expression: NSRegularExpression, _ text: String,
                              cancelled: @escaping () -> Bool) -> NSTextCheckingResult? {
        var result: NSTextCheckingResult?
        expression.enumerateMatches(in: text, options: [.reportProgress],
            range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
                if cancelled() { stop.pointee = true }
                else if let match { result = match; stop.pointee = true }
            }
        return result
    }
}
