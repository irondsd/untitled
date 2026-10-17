# Adding syntax formats

Syntax highlighting has three layers:

- `SyntaxEngine` chooses a format from its registry, using a bounded sample of the note, then tokenizes the whole note. It discards cancelled results.
- Each `SyntaxDefinition` supplies content detection and UTF-16 token spans. YAML, Markdown, and the combined JavaScript/TypeScript mode live in separate `Syntax*.swift` files. These modules depend only on Foundation.
- `EditorSyntaxHighlighter` schedules background work and maps semantic token kinds to temporary foreground colors. It owns AppKit integration, brightness, and stale-result protection. It never changes text storage or undo history.

To add a format:

1. Add a case to `NoteLanguage` in `SyntaxEngine.swift`.
2. Add `Sources/SyntaxYourFormat.swift` conforming to `SyntaxDefinition`, with `language`, `confidence(in:)`, and `highlight(_:)`.
3. Register its type in `SyntaxEngine.definitions`. No dispatch branches or editor changes are needed. Build and test scripts discover `Syntax*.swift` files automatically.
4. Add fixtures to `Tests/main.swift` covering positive detection, ambiguous prose, conflicts with existing formats, Unicode/CRLF offsets, unfinished edits and cancellation. For new editor behavior, extend the isolated native smoke tests.

Use `SyntaxSource.lines` for logical lines and their absolute UTF-16 offsets. Its `first`/`matches` methods share cancellable regex enumeration. Stateful syntaxes can use a lexer instead, as JavaScript does. Return `SyntaxSpan` values with existing semantic kinds whenever possible; the editor decides their colors. Ranges must be nonempty and within the complete source. Later overlapping spans override earlier ones, which allows Markdown's front matter to reuse YAML tokens. Single-pass lexers should emit non-overlapping tokens in source order.

Confidence values are comparable across formats: zero means no evidence; 1–69 is ambiguous; 70–94 is distinctive syntax; 95 and above identifies an enclosing format. Highest confidence wins. Equal scores retain registry order. Fenced Markdown and front matter should outrank enclosed snippets, and YAML block scalars should outrank code within them. Check strings and comments before treating their contents as language evidence. New formats should add evidence rather than raise scores to beat existing formats blindly.

Detection samples the first 32,768 characters, remains content based, and falls back to plain text when there is no evidence. JavaScript and TypeScript intentionally share the `javascript` language identifier and one lexer; TypeScript keywords and type names extend JavaScript's tokens. Regex-versus-division detection is heuristic, and the lexer does not validate code or provide semantic type analysis. Markdown code fences retain a single code color.

Run `./test.sh`, then `./build.sh`. Native smoke tests must use a fresh disposable `--data-dir` as documented in the README. Never use real notes for tests.
