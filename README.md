# untitled

A small, native macOS scratchpad. Swift + AppKit, no dependencies, no browser engine, no accounts, no network code.

## Build and launch

Requires macOS 13+ and Apple's Command Line Tools (`xcode-select --install`). A full Xcode installation and an Apple developer account are not required.

```sh
./build.sh --run
```

The result is `build/untitled.app`. Copy it to Applications if you want; it runs independently of the source directory. The build script signs it locally with an ad hoc signature. This is a personal/local build, not a notarized public release.

## Behavior

- One tab: no tab strip; the note title is centered in the title bar.
- Multiple tabs: a compact tab strip alongside the native window buttons.
- The active tab shares the editor background; inactive tabs are slightly darker, including the window-button area when the first tab is inactive.
- Scratch notes are named `untitled`. Right-click a tab to rename it, click the single-note title, or use ⇧⌘R. A custom title changes the note label, not a file's name on disk.
- Closing a tab archives it unless it is an unnamed scratch note containing only whitespace. Those blank notes are discarded. Renamed empty notes and files opened from disk are retained. Closing the last tab creates a fresh blank note.
- Archive rows have a small trash button to permanently delete the local note after confirmation. Original files opened from disk are never deleted. Existing archived blank notes remain until explicitly deleted.
- Drag the top row, a tab label, or the centered note title to move the window. Buttons and right-click tab menus remain usable.
- The red window button hides the window without archiving its tabs. Click the Dock icon to show it again.
- Automatic saving follows edits after a 0.4-second pause, and runs before tab switches, closing, app deactivation, and quitting. A sudden crash can lose the last unsaved fraction of a second.
- Open tabs, their order, selected tab, titles, cursor position, and scroll position survive relaunch. Undo history is retained while a tab stays open, but not across app restarts or archiving.
- Line numbers count real logical lines; soft-wrapped rows share a line number. Word wrapping and native find are included. Syntax highlighting and detection are intentionally not included yet.
- View → Background adjusts transparency. The window uses native background blur; its appearance respects macOS transparency settings.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘T / ⌘N | New tab/note |
| ⌘1…⌘9 | Select tab by position |
| ⌃Tab / ⇧⌃Tab | Next/previous tab |
| ⌘W | Close and archive current tab (or close the archive window) |
| ⇧⌘T | Reopen most recently closed tab |
| ⇧⌘R | Rename note |
| ⇧⌘A | Search the archive, preview and restore notes |
| ⇧⌘F | Search all notes, including open notes |
| ⌘O | Open text files |
| ⌘S / ⇧⌘S | Save to an external file / Save As |
| ⌘F / ⌘G / ⇧⌘G | Find / next / previous |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘+ / ⌘= / ⌘− / ⌘0 | Increase / increase / decrease / reset text size |
| ⌃⌘F | Fullscreen |
| ⌘Q | Save local notes and quit |

## Storage

Everything lives in `~/Library/Application Support/untitled/`:

```text
session.json        open tab order and selected tab
notes/<UUID>.txt    plain UTF-8 text, one file per note
notes/<UUID>.json   title, dates, archive status, cursor and optional original file path
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

The UI smoke test exercises real NSTextView typing/undo, Command-T, tab switching, archiving, restoration and session persistence. `--data-dir` is only a test/development override.

The initial release passed 23 storage checks and 26 native integration checks. Mouse selection, right-click renaming, archive content search/restore, native Find and the single-note title bar were also checked in the running app. On the development Mac (Apple Silicon, macOS 15.4.1), the app bundle measured 0.67 MiB and a performance sample after editing/searching reported a 42.3 MiB physical footprint. These are small-note measurements, not limits or guarantees for large documents.

Version 0.1.1 passed 45 storage/line-index checks and 42 native integration checks, including the single-character empty-line baseline regression. Its line-number index is updated incrementally; only visible labels are drawn. Window dragging, active/inactive tab colors and the archive delete confirmation were also checked in the running preview.
