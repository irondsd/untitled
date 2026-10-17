# untitled

A small, native macOS scratchpad. Swift + AppKit, no dependencies, no browser engine, no accounts, no network code.

## Build and launch

Requires macOS 13+ and Apple's Command Line Tools (`xcode-select --install`). A full Xcode installation and an Apple developer account are not required.

```sh
./build.sh --run
```

The result is `build/untitled.app`. To also install it, run `./build.sh --install` (add `--run` to open the installed copy). This replaces `/Applications/untitled.app` after checking it is this app and is not running; set `INSTALL_DIR` to install elsewhere, such as `~/Applications`. The installed app runs independently of the source directory and uses the same notes as the local build, so run only one copy at a time. The build script signs it locally with an ad hoc signature. This is a personal/local build, not a notarized public release.

### Command line

`unt` opens files from the shell, like `subl`: `unt notes.md config.yaml` opens each file as a tab (or focuses its existing tab), launching the app if needed. With no arguments it brings untitled to the front. It uses `/Applications/untitled.app` (so it follows `./build.sh --install`), then `~/Applications/untitled.app`, then the local `build/untitled.app` next to the script; set `UNTITLED_APP` to use another copy. Missing files and directories are rejected. To put it on your `PATH`, link it rather than copying it, so it can still find the local build:

```sh
ln -s "$PWD/unt" ~/bin/unt
```

To regenerate the existing app icon, run `./make-icon.sh`, then `./build.sh`. The icon script renders the ten standard/Retina sizes from `MakeIcon.swift` and packages them with Apple's `iconutil`. Keep this packaging step: manually placing PNGs in the small ICNS representation slots can produce scrambled icons in Finder and Activity Monitor even when the Dock looks correct.

## Behavior

- One tab: no tab strip; the note title is centered in the title bar.
- Multiple tabs: a compact tab strip alongside the native window buttons.
- The active tab shares the editor background; inactive tabs are slightly darker, including the window-button area when the first tab is inactive.
- Scratch notes are named `untitled`. Right-click a tab to rename it, click the single-note title, or use ⇧⌘R. A custom title changes the note label, not a file's name on disk.
- Closing a tab archives it unless it is an unnamed scratch note containing only whitespace, or a file opened from disk with no unsaved edits. Those local copies are discarded; the original file stays on disk. An opened file with unsaved edits is archived so the edits are not lost. Renamed empty notes and scratch notes saved to a file are retained. Closing the last tab creates a fresh blank note.
- Archive rows have a small trash button that permanently deletes the local note immediately, without confirmation. Original files opened from disk are never deleted. Existing archived blank notes remain until explicitly deleted.
- Drag the top row, a tab label, or the centered note title to move the window. Buttons and right-click tab menus remain usable.
- The red window button hides the window without archiving its tabs. Click the Dock icon to show it again.
- Automatic saving follows edits after a 0.4-second pause, and runs before tab switches, closing, app deactivation, and quitting. A sudden crash can lose the last unsaved fraction of a second.
- Open tabs, their order, selected tab, titles, cursor position, and scroll position survive relaunch. Undo history is retained while a tab stays open, but not across app restarts or archiving.
- Holding ⌘V repeats pasting while the keys remain held. Queued repeat pastes are discarded after releasing V or Command; a single quick paste still works.
- Selecting text highlights exact repeats in the current note, with Find closed. ⌘D adds the next occurrence to the selection and wraps around; with a caret, the first ⌘D selects the word under it. ⇧⌘D selects all occurrences at once, using the word under the caret if nothing is selected. Matching is literal and case-sensitive, independent of Find settings. Typing, paste, and deletion affect every selected occurrence, with native undo. Esc reduces multiple selections to one; clicking elsewhere clears the preview. Whitespace-only selections do not trigger highlighting.
- Line numbers count real logical lines; soft-wrapped rows share a line number. Word wrapping and a native bottom find/replace panel are included.
- YAML, Markdown, JavaScript/TypeScript (including JSX/TSX), HTML and CSS are detected automatically from note content when you paste, type, open or restore a note. Highlighting updates after a brief pause and switches formats as the content changes. YAML colors keys, quoted strings, numbers, booleans/nulls, comments, anchors, aliases and block scalars; Markdown colors headings, emphasis, links, list/quote markers and code. Markdown front matter uses YAML colors. Source text stays visible and unchanged; code fences use a single code color. Detection is heuristic and samples the first 32,768 characters: ambiguous prose stays plain, while simple lowercase `key: value` entries are treated as YAML. JavaScript and TypeScript share one mode, coloring keywords, types, functions, strings/template expressions, regexes, numbers, comments and punctuation. Colors follow font brightness, and Find/selection highlights remain available.
- JSX/TSX elements color tag names, components and attributes inside the JavaScript mode; `{…}` expressions are highlighted as code, text children stay plain, and TypeScript generics or `<Type>` assertions are not mistaken for elements. HTML colors tags, attributes, values, comments, doctypes and entities, and highlights `<script>` and `<style>` bodies as JavaScript and CSS. CSS (including nested SCSS-style rules and `//` comments) colors selectors, pseudo-classes, properties, numbers with units, hex colors, functions, at-rules and `!important`.
- The Syntax menu overrides detection per note: choose Plain Text or a specific format, or Detect Automatically (the default, which shows the detected format). The choice is saved with the note.
- Save As suggests a file extension from the note's syntax (`.yaml`, `.md`, `.html`, `.css`, `.js`/`.jsx`/`.ts`/`.tsx` depending on JSX and type annotations, otherwise `.txt`) unless the note title already has one.
- Settings (⌘,) adjusts background opacity, background black level (50–100%), font brightness, default font size (10.0–36.0 pt in 0.1 pt steps), and line-number visibility. Changes apply immediately to open and new tabs and persist locally. Changing the default size also sets the current size; temporary zoom leaves the default unchanged, and ⌘0 returns to it.
- View → Background also offers transparency presets, kept in sync with Settings. The window uses native background blur; its appearance respects macOS transparency settings.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘, | Settings |
| ⌘T / ⌘N | New tab/note |
| ⌘1…⌘9 | Select tab by position |
| ⌃Tab / ⇧⌃Tab | Next/previous tab |
| ⌘W | Close and archive current tab (or close Settings/the archive window) |
| ⇧⌘T | Reopen most recently closed tab |
| ⇧⌘R | Rename note |
| ⇧⌘A | Search the archive, preview and restore notes |
| ⇧⌘F | Search all notes, including open notes |
| ⌘O | Open text files |
| ⌘S / ⇧⌘S | Save to an external file / Save As |
| ⌘F / ⌘G / ⇧⌘G | Find / next / previous |
| ⌘D | Select word / add next occurrence to selection |
| ⇧⌘D | Select all occurrences of selected text / word under caret |
| ⌥⌘F | Focus replacement field |
| Return / ⇧Return in Find | Find next / previous (wraps) |
| Return in Replace | Replace selected match, then find next; All replaces every match |
| Esc | Close find panel, or reduce multiple editor selections to one |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘+ / ⌘= / ⌘− / ⌘0 | Increase / increase / decrease / reset text size |
| ⌃⌘F | Fullscreen |
| ⌘Q | Save local notes and quit |

## Find and replace

⌘F opens two rows at the bottom: Find and Replace. The three switches on the right are `.*` (regular expressions), `Aa` (case sensitive), and `All` (Find All / Replace All). Search ignores case by default. All operates only on the current note. Matches highlight live regardless of the All switch, with a match count and inline errors for invalid expressions. Find All selects every match; next/previous still navigate individual matches. Empty regex matches are marked with a thin yellow bar.

Regex uses Foundation's ICU expressions. Parentheses capture groups: finding `name=(\w+)` and replacing with `Hello, $1!` changes `name=Alice` to `Hello, Alice!`. `$0` inserts the whole match; `$1`, `$2`, etc. insert capture groups. Regex replacements also accept `\n`, `\r`, and `\t`; use `\$` for a literal dollar sign and `\\` for a literal backslash. In plain mode, replacement text is literal. `^` and `$` match line boundaries; use `\A` and `\z` for note boundaries, and `(?s)` when `.` should span newlines.

Opening the panel prefills Find from selected text. Tab moves from Find to Replace; Shift-Tab moves back. Return finds the next match, Shift-Return finds the previous, and both wrap. Replace changes an exactly selected match and moves to the next; if none is selected, it selects the next match first. Replace All is one undo step, with ⌘Z / ⇧⌘Z undoing/redoing the replacement even while an input still has focus. Editing an input returns undo to that field. Searches run in the background and follow the selected tab while preserving each tab's editor and undo history. Esc or the close button clears highlights and returns focus to the note.

## Storage

Everything lives in `~/Library/Application Support/untitled/`:

```text
session.json        open tab order and selected tab
notes/<UUID>.txt    plain UTF-8 text, one file per note
notes/<UUID>.json   title, dates, archive status, cursor, syntax choice and optional original file path
```

Files are saved with atomic replacement. The app reconstructs notes from the individual text files if session or metadata files are missing/corrupt. Archive bodies are loaded on demand rather than held in memory. Search runs on demand in the background; there is no background polling or always-running indexer. File → Show Notes Folder reveals the data.

Opening a file creates a local working copy associated with its path. Automatic saving updates that local copy only; ⌘S explicitly writes UTF-8 back to the external file. Reopening the same path focuses/restores the retained local copy. External changes are not automatically reloaded. There is no app-managed sync; ordinary system backups can still include Application Support.

## Tests

```sh
./test.sh
```

Native UI integration checks can be run against a disposable folder in an active desktop session:

```sh
./build.sh
test_dir="$(mktemp -d)"
build/untitled.app/Contents/MacOS/untitled --data-dir "$test_dir" --smoke-test
cat "$test_dir/smoke-results.json"
```

The UI smoke test exercises real NSTextView typing/undo, Command-T, tab switching, archiving, restoration, session persistence, and find/replace. The find update passes 58 storage/line-index/search checks and 129 native integration checks. Command-F, Return/Shift-Return, capture replacement, focused-input undo/redo, and Escape were also checked in a separately identified preview app using disposable notes. `--data-dir` is only a test/development override.

The selection-occurrence update passes 69 storage/line-index/search checks and 192 native integration checks. It covers exact selection previews, Command-D wraparound, Command-Shift-D selection of all occurrences, queued shortcuts, multiple selection typing, continued caret editing, Unicode deletion, multiline paste, undo/redo, tab retention, and interaction with Find. Selection highlighting and actual keyboard typing/deletion/undo were also verified in a separately identified preview app with disposable notes.

The initial release passed 23 storage checks and 26 native integration checks. Mouse selection, right-click renaming, archive content search/restore, native Find and the single-note title bar were also checked in the running app. On the development Mac (Apple Silicon, macOS 15.4.1), the app bundle measured 0.67 MiB and a performance sample after editing/searching reported a 42.3 MiB physical footprint. These are small-note measurements, not limits or guarantees for large documents.

Version 0.1.1 passed 45 storage/line-index checks and 42 native integration checks, including the single-character empty-line baseline regression. Its line-number index is updated incrementally; only visible labels are drawn. Window dragging, active/inactive tab colors and the archive delete confirmation were also checked in the running preview.

Version 0.1.2 passed 45 storage/line-index checks and 64 native integration checks. Settings persistence, live font/brightness changes, default-size reset, gutter toggling, and retained text/selection/undo are covered. The Settings layout and Command-comma/Command-W behavior were also checked in the active preview. Test data directories use separate preference domains.

Version 0.1.3 clips the line-number gutter below the title bar, separates background black level from opacity, and replaces the font-size dropdown with a decimal field and stepper.
The update passed 66 native integration checks; the clipped gutter, decimal entry/stepper, maximum font size, and independent background slider were also verified in the running preview.

Version 0.1.4 filters queued auto-repeat paste commands using the current key state, while preserving completed single presses and menu paste actions. It passed 74 native checks, including release of either key, continuing repeats while both keys are held, and preservation of other shortcuts. Autosave timing is unchanged.

Automatic YAML/Markdown highlighting passes 127 storage/line-index/search/syntax checks and 220 native integration checks. Coverage includes paste detection, format changes, stale background work, UTF-16 ranges, YAML scalars/comments/front matter, Markdown fences/inline syntax, copy, undo/redo, brightness, Find, tab retention, plain-text persistence and archive restoration. Both formats were visually checked in a separately identified preview using disposable notes. This is a tolerant source highlighter, not a full validator or renderer.

Syntax formats are separate modules behind a small registry, with shared UTF-16 ranges, cancellable background work and semantic token colors. See [Adding syntax formats](Docs/SyntaxHighlighting.md) for the extension contract and testing guidance.

The extensible-engine and JavaScript/TypeScript update passes 212 storage/line-index/search/syntax checks and 243 native integration checks. It adds a shared JS/TS lexer with comments, escaped strings, template interpolation, regex/division handling, numeric literals, TypeScript keywords/types and function calls. Tests also cover registration of an additional format, deterministic detection ties and conflicts with YAML/Markdown. JavaScript and TypeScript colors were visually checked in a separately identified preview with disposable notes.

Syntax colors are applied only to the visible text and one screen above and below, repainting as the note scrolls, and each token kind shares one color object. On an 8 MB JavaScript note, the physical footprint after highlighting fell from about 345 MB to 135 MB, and the main-thread time spent applying colors fell from about 0.5 s to about 1 ms. The idle footprint is unchanged at about 19 MB. The update passes 340 storage/line-index/search/syntax checks, including a new span index, and 272 native integration checks covering scroll repainting, shared colors, edits, brightness, tab switching and undo in a 4,000-line note.
