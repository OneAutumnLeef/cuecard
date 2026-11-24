# Phase 3 Results: Polish

*24 Nov 2026 · You confirmed everything below works, including a real screen share where the prompter stayed invisible.*

## What's new

**Script library**
- Scripts are plain Markdown files in `~/Library/Application Support/MacTele/Scripts/`, so you can also open them in any editor.
- The editor (`⌃⌥E`) has a sidebar, newest first. You can:
  - make a new script, or **import** a .txt, .md, .rtf, .docx or .pdf file
  - rename a script by editing its title (names never overwrite each other)
  - move a script to the Trash, which can be undone
- Switch scripts mid-session: right-click the prompter → **Scripts ▸**.
- Your old single script moved into the library automatically. Because it was the built-in welcome text, it was replaced by the current welcome script.

**Looks**
- Five presets in Settings: **Classic**, **High Contrast** (bigger, bold, yellow pill), **Calm** (rounded font, blue underline), **Large** (32 pt, two lines, wider) and **Serif Reader** (New York, warm colours, left-aligned).
- A preset changes appearance only, never your speed, voice, microphone or display settings. Fine-tune anything afterwards.

**Display**
- **Placement:** *In the notch*, or *Floating*: a rounded panel you drag by its grip, which remembers where you left it. **Reset** puts it back.
- **Screen:** automatic (the built-in display with the notch), or any connected screen. On screens without a notch, the island hangs from the top centre.
- **Mirror text** flips it for beam-splitter teleprompter glass.

**Getting started**
- A **Welcome** window appears on first launch and stays under *Welcome & Shortcuts…* in the menu. It explains the essentials, shows the microphone permission with an Allow button, and lists every shortcut.
- **Settings → Voice** shows microphone access, with the right button for each state: Allow, or Open Privacy Settings.
- **Settings → General → Open Notch Prompter at login** uses macOS's own login-item system. It's off unless you turn it on.

**Verified**
- **Hidden from screen sharing works with a real app.** You checked it in a screen share while the prompter was showing (the Phase 0 test used ScreenCaptureKit directly).
- 51 unit tests pass, including the library (unique names, rename, delete, migration), presets (look-only) and the new settings.

## Where things live

| What | Where |
|---|---|
| App | `~/Applications/Notch Prompter.app` |
| Scripts | `~/Library/Application Support/MacTele/Scripts/*.md` |
| Settings | `~/Library/Application Support/MacTele/settings.json` |
| Diagnostic takes and test recordings | `~/Library/Caches/MacTele/sessions` and `…/fixtures` (safe to delete) |
| Build output | `~/Library/Caches/MacTele/build`, `…/apps` |

## Not done (Phase 4 ideas from the plan)

- **Rehearsal report:** pace over time, pauses, filler words, skipped sections.
- **On-device AI rewrite** ("make this more speakable") using Apple's FoundationModels.
- **A URL scheme or CLI** so Claude or Shortcuts can push scripts into the library.
- **iPhone as a remote**, and PPTX speaker-notes import.
- **Configurable shortcuts.**
- **Sharing with others:** Developer ID signing and notarisation ($99/yr Apple Developer account), a DMG, and auto-updates.
