# File formats

The editor reads UTF-8 and UTF-16 text regardless of its filename or extension. Use File → Open or `unt path/to/file` for text files, including extensionless files such as `Dockerfile`, `Makefile` and `.gitignore`. Finder's Open With list is a separate macOS registration; it is not the editor's allowlist.

`Info.plist` registers generic text, source and script types and explicit system types for plain text, Markdown, JSON, YAML, XML, property lists, SVG, RSS, HTML, CSS, common programming languages, logs, CSV, TSV and WebVTT. Property lists need their own registration because `com.apple.property-list` does not conform to `public.text`.

An additional extension-based declaration covers formats without a system type, names used by other apps and ambiguous extensions (for example, `.ts` also denotes a video transport stream). These entries deliberately live in a separate document-type dictionary: `LSItemContentTypes` takes precedence over `CFBundleTypeExtensions` within a dictionary. The app keeps the `Alternate` rank and the shared document icon for both declarations. It does not export or redefine other apps' file types, claim all binary data or change your default apps.

## Registered extensions

| Category | Extensions |
|---|---|
| Plain text | `txt`, `text`, `log` |
| Markdown | `md`, `markdown`, `mdown`, `mkd`, `mdx` |
| JSON and related text | `json`, `jsonc`, `json5`, `jsonl`, `ndjson`, `ipynb` |
| Configuration | `yaml`, `yml`, `toml`, `ini`, `cfg`, `conf`, `config`, `cnf`, `env`, `properties`, `editorconfig` |
| Apple configuration | `plist`, `strings`, `stringsdict`, `entitlements`, `xcconfig`, `pbxproj` |
| XML and markup | `xml`, `xsd`, `xsl`, `xslt`, `dtd`, `svg`, `rss`, `atom`, `xaml` |
| Web pages and templates | `html`, `htm`, `xhtml`, `vue`, `svelte`, `astro` |
| Stylesheets | `css`, `scss`, `sass`, `less` |
| JavaScript and TypeScript | `js`, `mjs`, `cjs`, `jsx`, `ts`, `tsx` |
| Shell scripts | `sh`, `bash`, `zsh`, `fish`, `ksh`, `command` |
| Python, Ruby and Swift | `py`, `pyw`, `pyi`, `rb`, `swift` |
| C family | `c`, `h`, `cc`, `cpp`, `cxx`, `hh`, `hpp`, `hxx`, `m`, `mm` |
| JVM, Go, Rust and PHP | `java`, `kt`, `kts`, `go`, `rs`, `php`, `phtml` |
| Other source code | `cs`, `fs`, `fsx`, `vb`, `scala`, `sc`, `dart`, `sql`, `lua`, `r`, `pl`, `pm`, `ex`, `exs`, `erl`, `hrl`, `hs`, `lhs`, `clj`, `cljs`, `cljc`, `edn`, `lisp`, `el`, `vim`, `graphql`, `gql`, `proto` |
| Data and documents | `csv`, `tsv`, `tex`, `bib`, `rst`, `adoc`, `org` |
| Captions, calendars and patches | `srt`, `vtt`, `ass`, `ics`, `diff`, `patch` |
| Development settings | `gitignore`, `gitattributes`, `gitmodules`, `dockerignore`, `npmrc`, `nvmrc` |
| Infrastructure and builds | `tf`, `tfvars`, `hcl`, `nix`, `cmake`, `make`, `mk` |

Extensions are case-insensitive. The generic text/source registrations also cover other types that macOS recognizes as text; no finite extension list can cover every text file. A new fallback extension can be added to the second `CFBundleDocumentTypes` entry in `Info.plist` without changing the editor.

## Syntax and file contents

Opening a format does not require a matching highlighter. Syntax detection uses the contents, with manual modes for Bash, CSS, HTML, JavaScript/TypeScript/JSX, JSON, Markdown, XML, YAML and Plain Text. For example, an XML plist uses XML colors, while an INI file can be edited as plain text. JSONC, JSON5 and newline-delimited JSON have no dedicated modes.

Plists may contain XML, older textual syntax or binary data. XML and readable text plists open as source. Binary plists are rejected with a specific message, without conversion or changes to the original. The same text-content checks apply to every registered extension; registering `.ts` does not make binary video editable.

As with other external files, automatic saving writes only a local working copy. Command-S explicitly writes UTF-8 back to the external file; text is never pretty-printed or reformatted automatically.

## Using the registrations

Build the app with `./build.sh`. To update the installed copy, quit it and run `./build.sh --install`. In Finder, select a representative file, choose Get Info → Open with → untitled → Change All. Repeat for each file type you want to associate. Finder may cache both app registrations and document icons.

To verify the built app's Finder registrations in an active desktop session, run `xcrun swift Tests/FileAssociations.swift build/untitled.app`. This registers the bundle and asks macOS which apps can open a disposable fixture for every listed extension; it does not open the app or change default apps.
