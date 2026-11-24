# Notch Prompter

A teleprompter that grows out of the MacBook notch, right under the camera, and highlights your script word by word.
Menu-bar app, macOS 26+, built with only the Command Line Tools (no Xcode needed).

**Status:** Phases 0–4 are done ([PHASE4-RESULTS.md](PHASE4-RESULTS.md): rehearsal reports, phone remote, PowerPoint notes, `notchprompter://` links and the `prompter` command, on-device AI rewrite). It follows your voice (on-device speech recognition), keeps a script library, has looks, floating and mirror modes, and stays hidden from screen sharing (verified in a real screen share). See [PHASE3-RESULTS.md](PHASE3-RESULTS.md), [PHASE2-RESULTS.md](PHASE2-RESULTS.md), [PLAN.md](PLAN.md) and [PHASE0-FINDINGS.md](PHASE0-FINDINGS.md).

## Use it

- **Start / pause:** `⌃⌥Space`. In voice mode it shows "Start reading" and follows you from the first words (the first time, macOS asks for the microphone). In fixed-speed mode it counts down 3-2-1 and scrolls at your set pace.
- **Voice / fixed speed:** `⌃⌥V`, or the waveform/metronome button on hover. The mic beside the notch is green while it's locked on to you, amber while coasting, and red if it has lost your place.
- **Hover over the prompter** for a control bar: restart, sentence back and forward, play/pause, speed, editor, settings, hide.
- **Right-click the prompter** for the full menu. The menu-bar icon can end up hidden behind the island while it's showing.
- **Click a word** to jump to it. **Scroll on the panel** to move line by line.
- The time left shows to the left of the notch; play state and speed show to the right.
- **Scripts:** `⌃⌥E` opens the editor with your script library (new, import, rename, Trash). Switch scripts from right-click → Scripts ▸.
- **Settings → Display:** in the notch or floating (drag by the grip), which screen, and mirrored text. **Settings → Looks:** five presets. **Settings → General:** open at login.
- **Rehearsal report:** opens after you read a script to the end in voice mode (pace chart, pauses, fillers, skips, history). Menu → Rehearsal Report… shows it any time.
- **Phone remote:** menu → Phone Remote… → scan the QR code (same Wi-Fi).
- **Rewrite** (wand, in the editor): Easier to Say, Shorter, Add Pauses, Spell Out Numbers, using Apple Intelligence on this Mac. Always previewed first.
- **From other apps:** `scripts/prompter add file.md --title "Talk" --start`, or `notchprompter://` links (see PHASE4-RESULTS.md).

| Shortcut | Action |
|---|---|
| `⌃⌥Space` | Start / pause |
| `⌃⌥P` | Show / hide the prompter |
| `⌃⌥R` | Restart |
| `⌃⌥[` / `⌃⌥]` | Previous / next sentence |
| `⌃⌥−` / `⌃⌥=` | Slower / faster (10 wpm steps) |
| `⌃⌥E` | Edit script |
| `⌃⌥,` | Settings |
| `⌃⌥V` | Follow my voice / fixed speed |

**Script tips:**
- Each line of your script starts a new line on the prompter.
- `[PAUSE]` holds for 1.5 s; `[PAUSE 3]` holds for 3 s.
- Anything else in square brackets, like `[smile]` or `[look at camera]`, shows as a stage note and takes no time.
- Markdown headings, bullets and bold markers are cleaned up automatically.
- **Import** reads .txt, .md, .rtf, .docx, .pdf and **.pptx** (speaker notes, with `[Slide N]` markers).

**Settings** apply live while the window is open: size, weight, typeface, line spacing, alignment, panel width, visible lines, all colours, highlight style (colour, pill or underline), how dim spoken words get, background opacity, speed, countdown, and **Hide from screen sharing** (on by default; tested invisible to ScreenCaptureKit captures on macOS 27).

## Build, test, install

```bash
make test        # 62 unit tests (Swift Testing)
```
```bash
make install     # release build → ~/Applications/Notch Prompter.app, then opens it
```
```bash
make run         # build and run without installing
```

One-time setup, already done on this Mac: `make signing` creates a local "MacTele Local Dev" signing identity in its own keychain file, so macOS keeps permissions across rebuilds.

Build output lives in `~/Library/Caches/MacTele`, outside iCloud Drive. Settings and scripts are saved in `~/Library/Application Support/MacTele` (`settings.json`, `Scripts/*.md`).

## Layout

```
Sources/PrompterCore/    pure logic, unit-tested: Script (parsing, cues, sentences), Pacing (AutoScroller),
                         LineLayout (word wrap), Settings, Store (files), SpokenForm (numbers → words, matching),
                         VoiceTracker (alignment + pace prediction + voice detection), ScriptLibrary, Presets,
                         Rehearsal (reports), Handoff (notchprompter:// links, PowerPoint notes)
Sources/PrompterSpeech/  SpeechListener: mic or file → SpeechAnalyzer, levels, device switching
Sources/PrompterBench/   prompter-bench: make test readings, record recogniser output, score the tracker
Sources/NotchPrompter/   the app: AppModel (state), NotchPanel (window + display-link ticker),
                         PrompterView (island, text, hover controls), Commands (menu bar + global hotkeys),
                         Windows (editor with library + settings), Welcome, DiagnosticTake, RehearsalWindow,
                         PhoneRemote (local web remote), AIRewrite (FoundationModels), AppDelegate
Tests/PrompterCoreTests/ unit tests
Spikes/                  Phase 0 prototypes (notch panel, speech latency harness)
scripts/                 build-app.sh, install.sh, setup-signing.sh, make-icon.swift, prompter (CLI)
```

### Launch flags for automated checks
`--store <dir>` (use another settings folder), `--script <file>`, `--listen-file <audio>` (voice mode from a recording),
`--show`, `--play`, `--seek <word>`, `--hover`, `--editor`, `--settings`, `--welcome`, `--report`, `--remote`,
`--snapshot <png>` (renders the prompter), `--window-shot <png>`, `--snapshot-after <s>`, `--quit-after <s>`.
