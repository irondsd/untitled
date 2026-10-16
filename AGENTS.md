# untitled

This is a native macOS scratchpad built with Swift and AppKit. Read README.md before changing behavior.

- Keep it small: no Electron, web views, network services, telemetry, account requirements, or app-managed sync.
- Preserve the compact terminal-like window, native traffic lights, background blur, and integrated tab strip. One open note hides the tab strip.
- Closing a tab archives it; never delete note text automatically. Keep notes as individual UTF-8 files in Application Support, with atomic writes and recoverable metadata.
- Flush pending edits before switching, archiving, deactivation and quitting. Surface save failures and prevent closing/quitting when a flush fails.
- Each open tab owns its native editor and undo manager. Do not replace the editor on every tab switch.
- Keep language detection and syntax highlighting out of version 0.1 unless requested.
- Build with `./build.sh`; run storage checks with `./test.sh`. Use the documented isolated data directory for native integration tests. Never run smoke tests against real notes.
- AppKit scroll views in the full-size title bar must disable automatic content insets so tab buttons receive mouse input.
- Public distribution and installation into Applications are separate from the local build.
