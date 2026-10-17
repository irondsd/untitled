import Foundation

enum NoteLanguage: String, CaseIterable { case plain, yaml, markdown, javascript }
extension NoteLanguage {
    var displayName: String {
        switch self {
        case .plain: return "Plain Text"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .javascript: return "JavaScript / TypeScript"
        }
    }
    /// Suggested for Save As when the note title has no extension of its own.
    var fileExtension: String {
        switch self {
        case .plain: return "txt"
        case .yaml: return "yaml"
        case .markdown: return "md"
        case .javascript: return "js"
        }
    }
}
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

    /// Pass `language` to skip detection and tokenize with a manually chosen format.
    static func analyze(_ text: String, using definitions: [SyntaxDefinition.Type] = SyntaxEngine.definitions,
                        language: NoteLanguage? = nil, cancelled: @escaping () -> Bool = { false }) -> SyntaxResult {
        let plain = SyntaxResult(language: .plain, spans: [])
        guard !cancelled() else { return plain }
        let chosen: SyntaxDefinition.Type?
        if let language { chosen = definitions.first { $0.language == language } }
        else { chosen = detect(text, using: definitions, cancelled: cancelled) }
        guard let chosen, !cancelled() else { return plain }
        let spans = chosen.highlight(SyntaxSource(text, cancelled: cancelled))
        return cancelled() ? plain : SyntaxResult(language: chosen.language, spans: spans)
    }

    static func detectLanguage(_ text: String) -> NoteLanguage {
        detect(text, using: definitions, cancelled: { false })?.language ?? .plain
    }

    private static func detect(_ text: String, using definitions: [SyntaxDefinition.Type],
                               cancelled: @escaping () -> Bool) -> SyntaxDefinition.Type? {
        // Detection is bounded; the chosen tokenizer receives the complete source.
        let sample = SyntaxSource(String(text.prefix(32_768)), cancelled: cancelled)
        var winner: SyntaxDefinition.Type?, confidence = 0
        for definition in definitions {
            guard !cancelled() else { return nil }
            let candidate = definition.confidence(in: sample)
            if candidate > confidence { winner = definition; confidence = candidate }
        }
        return winner
    }
}
