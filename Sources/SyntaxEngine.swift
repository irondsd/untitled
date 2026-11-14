import Foundation

/// Case order is the Syntax menu order; raw values are stored in note metadata.
enum NoteLanguage: String, CaseIterable { case plain, bash, css, csv, html, javascript, json, markdown, tsv, xml, yaml }
extension NoteLanguage {
    var displayName: String {
        switch self {
        case .plain: return "Plain Text"
        case .bash: return "Bash"
        case .xml: return "XML"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .javascript: return "JavaScript / TypeScript"
        case .json: return "JSON"
        case .html: return "HTML"
        case .css: return "CSS"
        case .csv: return "CSV"
        case .tsv: return "TSV"
        }
    }
    /// Suggested for Save As when the note title has no extension of its own.
    var fileExtension: String {
        switch self {
        case .plain: return "txt"
        case .bash: return "sh"
        case .xml: return "xml"
        case .yaml: return "yaml"
        case .markdown: return "md"
        case .javascript: return "js"
        case .json: return "json"
        case .html: return "html"
        case .css: return "css"
        case .csv: return "csv"
        case .tsv: return "tsv"
        }
    }
}
enum SyntaxKind: Hashable {
    case heading, marker, key, string, number, literal, comment, code, emphasis, link, keyword, type, function, tag, attribute
    /// Characters that only format other text, such as Markdown's `#`, `**` and backticks; drawn dimmed.
    case markup
    /// Delimited text cycles through six column colors, independent of field contents.
    case column(Int)
}
struct SyntaxSpan {
    let range: NSRange
    let kind: SyntaxKind
}
/// Typography beyond color. Formats describe structure; the editor decides fonts, spacing and backgrounds.
enum SyntaxStyle: Hashable {
    /// A whole `#` heading line, level 1–6.
    case heading(Int)
    /// The title line above a `===` (level 1) or `---` (level 2) underline, and the underline itself.
    case setextHeading(Int), setextUnderline
    /// A fenced code block from the opening fence line to the closing one, inclusive.
    case codeBlock
    case inlineCode, strong, emphasis
}
struct SyntaxStyleSpan {
    let range: NSRange
    let style: SyntaxStyle
}
struct SyntaxResult {
    let language: NoteLanguage
    let spans: [SyntaxSpan]
    var styles: [SyntaxStyleSpan] = []
}

/// Stateless format modules return semantic tokens; they never know about AppKit, colors or storage.
protocol SyntaxDefinition {
    static var language: NoteLanguage { get }
    /// 0 = no evidence, 1–69 = ambiguous, 70–94 = distinctive syntax, 95+ = an enclosing format.
    /// Strictly greater confidence wins; registry order breaks ties deterministically.
    static func confidence(in source: SyntaxSource) -> Int
    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan]
    /// Colors plus optional typography, from one pass. Most formats only color.
    static func tokenize(_ source: SyntaxSource) -> (spans: [SyntaxSpan], styles: [SyntaxStyleSpan])
}
extension SyntaxDefinition {
    static func tokenize(_ source: SyntaxSource) -> (spans: [SyntaxSpan], styles: [SyntaxStyleSpan]) { (highlight(source), []) }
}

/// A tolerant source highlighter, not a validator or renderer. Add formats to this registry.
enum SyntaxEngine {
    static let definitions: [SyntaxDefinition.Type] = [MarkdownSyntax.self, YAMLSyntax.self, JSONSyntax.self, JavaScriptSyntax.self, HTMLSyntax.self, XMLSyntax.self, CSSSyntax.self, BashSyntax.self, CSVSyntax.self, TSVSyntax.self]

    /// Pass `language` to skip detection and tokenize with a manually chosen format.
    static func analyze(_ text: String, using definitions: [SyntaxDefinition.Type] = SyntaxEngine.definitions,
                        language: NoteLanguage? = nil, cancelled: @escaping () -> Bool = { false }) -> SyntaxResult {
        let plain = SyntaxResult(language: .plain, spans: [])
        guard !cancelled() else { return plain }
        let chosen: SyntaxDefinition.Type?
        if let language { chosen = definitions.first { $0.language == language } }
        else { chosen = detect(text, using: definitions, cancelled: cancelled) }
        guard let chosen, !cancelled() else { return plain }
        let tokens = chosen.tokenize(SyntaxSource(text, cancelled: cancelled))
        return cancelled() ? plain : SyntaxResult(language: chosen.language, spans: tokens.spans, styles: tokens.styles)
    }

    static func detectLanguage(_ text: String) -> NoteLanguage {
        detect(text, using: definitions, cancelled: { false })?.language ?? .plain
    }

    /// JavaScript notes pick js, jsx, ts or tsx from their contents.
    static func fileExtension(for text: String, language: NoteLanguage) -> String {
        language == .javascript ? JavaScriptSyntax.fileExtension(for: SyntaxSource(text)) : language.fileExtension
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
