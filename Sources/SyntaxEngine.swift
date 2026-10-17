import Foundation

enum NoteLanguage: String { case plain, yaml, markdown, javascript }
enum SyntaxKind { case heading, marker, key, string, number, literal, comment, code, emphasis, link, keyword, type, function }
struct SyntaxSpan {
    let range: NSRange
    let kind: SyntaxKind
}
struct SyntaxResult {
    let language: NoteLanguage
    let spans: [SyntaxSpan]
}

/// Stateless format modules return semantic tokens; they never know about AppKit, colors or storage.
protocol SyntaxDefinition {
    static var language: NoteLanguage { get }
    /// 0 = no evidence, 1–69 = ambiguous, 70–94 = distinctive syntax, 95+ = an enclosing format.
    /// Strictly greater confidence wins; registry order breaks ties deterministically.
    static func confidence(in source: SyntaxSource) -> Int
    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan]
}

/// A tolerant source highlighter, not a validator or renderer. Add formats to this registry.
enum SyntaxEngine {
    static let definitions: [SyntaxDefinition.Type] = [MarkdownSyntax.self, YAMLSyntax.self, JavaScriptSyntax.self]

    static func analyze(_ text: String, using definitions: [SyntaxDefinition.Type] = SyntaxEngine.definitions,
                        cancelled: @escaping () -> Bool = { false }) -> SyntaxResult {
        let plain = SyntaxResult(language: .plain, spans: [])
        guard !cancelled() else { return plain }
        // Detection is bounded; the chosen tokenizer receives the complete source.
        let sample = SyntaxSource(String(text.prefix(32_768)), cancelled: cancelled)
        var winner: SyntaxDefinition.Type?, confidence = 0
        for definition in definitions {
            guard !cancelled() else { return plain }
            let candidate = definition.confidence(in: sample)
            if candidate > confidence { winner = definition; confidence = candidate }
        }
        guard let winner, !cancelled() else { return plain }
        let spans = winner.highlight(SyntaxSource(text, cancelled: cancelled))
        return cancelled() ? plain : SyntaxResult(language: winner.language, spans: spans)
    }
}
