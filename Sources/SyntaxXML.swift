import Foundation

/// XML documents, feeds, SVG, plists and config files. Tokens come from the shared HTML scanner in XML mode.
struct XMLSyntax: SyntaxDefinition {
    static let language = NoteLanguage.xml
    private static let prolog = SyntaxRegex.compile(#"^\x{FEFF}?\s*<\?xml[\s?]"#)
    private static let start = SyntaxRegex.compile(#"^\x{FEFF}?\s*(?:<!--|<!\[CDATA\[|<!DOCTYPE|<[A-Za-z_][\w.:-]*[\s/>])"#)
    private static let tag = SyntaxRegex.compile(#"<(/?)([A-Za-z_][\w.:-]*)(?:\s[^<>]*?)?(/?)>"#)
    private static let distinctive = SyntaxRegex.compile(#"<!\[CDATA\[|\sxmlns(?::[\w.-]+)?\s*=|<!DOCTYPE\s+(?!(?i:html)[\s>])"#)
    private static let markdownBlock = SyntaxRegex.compile(#"(?m)^ {0,3}(?:#{1,6}\s|```|~~~)"#)
    /// Fragments, `{…}` attribute values and className belong to JSX.
    private static let jsx = SyntaxRegex.compile(#"<>|</>|=\s*\{|\bclassName\s*="#)
    private static let htmlElements: Set<String> = [
        "html", "head", "body", "title", "meta", "link", "script", "style", "base", "div", "span", "p", "a", "img", "ul", "ol",
        "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "colgroup", "col", "form",
        "input", "button", "select", "option", "optgroup", "textarea", "label", "fieldset", "legend", "h1", "h2", "h3", "h4",
        "h5", "h6", "header", "footer", "nav", "main", "section", "article", "aside", "figure", "figcaption", "blockquote",
        "pre", "code", "em", "strong", "b", "i", "u", "s", "small", "sub", "sup", "br", "hr", "iframe", "video", "audio",
        "source", "track", "canvas", "noscript", "template", "slot", "details", "summary", "dialog", "menu", "abbr", "cite",
        "q", "dfn", "mark", "time", "data", "var", "samp", "kbd", "del", "ins", "picture", "embed", "object", "param", "map",
        "area", "output", "progress", "meter", "datalist", "wbr", "bdi", "bdo", "ruby", "rt", "rp", "address", "center", "font"
    ]

    static func confidence(in source: SyntaxSource) -> Int {
        let text = source.text
        // The XML declaration encloses everything after it, including XHTML.
        if source.first(prolog, text) != nil { return 100 }
        guard source.first(start, text) != nil, source.first(markdownBlock, text) == nil, source.first(jsx, text) == nil else { return 0 }
        let tags = source.matches(tag, text)
        let opening = tags.filter { $0.range(at: 1).length == 0 }
        func name(_ match: NSTextCheckingResult) -> String { (text as NSString).substring(with: match.range(at: 2)) }
        // An HTML root element leaves the note to HTML, even when it embeds SVG.
        if let root = opening.first, htmlElements.contains(name(root).lowercased()) { return 0 }
        if source.first(distinctive, text) != nil || opening.contains(where: { name($0).contains(":") }) { return 90 }
        guard tags.count >= 2 || tags.contains(where: { $0.range(at: 3).length > 0 }) else { return 0 }
        let foreign = opening.filter { !htmlElements.contains(name($0).lowercased()) }.count
        // Plain markup with non-HTML elements and no JSX expressions is XML, even with capitalized names.
        return foreign * 2 > opening.count ? 89 : 0
    }

    static func highlight(_ source: SyntaxSource) -> [SyntaxSpan] { HTMLScanner(source, xml: true).scan() }
}
