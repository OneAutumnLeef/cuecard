# Notch Teleprompter: Research and Build Plan

*Written 24 Nov 2026. Covers research, feasibility on this Mac, architecture, build/install, testing and a phased roadmap.*

> **Status (24 Nov 2026):** Phase 4 is done: rehearsal reports, phone remote, PowerPoint notes, links and the `prompter` command, and on-device AI rewrite, all confirmed by you ([PHASE4-RESULTS.md](PHASE4-RESULTS.md)). Remaining: configurable shortcuts, and paid-account distribution if you ever want to share it.
>
> Phase 3 is done: script library, looks, floating, screen choice, mirror, welcome, mic status and launch at login. **Hide-from-screen-share was confirmed in a real screen share.** Details are in [PHASE3-RESULTS.md](PHASE3-RESULTS.md). Remaining ideas are Phase 4 extras.
>
> Phase 2 is done. Voice tracking is live and confirmed by you ("keeps up now"). On your own live reading the lit word is within 2 words 94% of the time, with zero average lag. Details are in [PHASE2-RESULTS.md](PHASE2-RESULTS.md). **Next: Phase 3, polish.**
>
> Phase 1 is done. The fixed-speed prompter is installed at `~/Applications/Notch Prompter.app`, with hover controls, a right-click menu, global hotkeys, an editor, live settings, a stable signing identity and 32 unit tests. Usage is in [README.md](README.md). **Next: Phase 2, voice tracking.**
>
> Phase 0 is done. Results are in [PHASE0-FINDINGS.md](PHASE0-FINDINGS.md). Headlines: the notch panel works; hiding from screen share works on macOS 27; words arrive about 0.7 s after they're spoken; recognition gets about 78% of your words right (enough to track with anchors plus the pace model); only the microphone permission is needed; vocabulary hints don't help.

---

## 1. The verdict

**Yes, all of it is possible, and on this Mac every piece runs on-device with no paid services.** I checked the machine directly:

| Check | Result on this Mac |
|---|---|
| Hardware | MacBook Air M5 (Mac17,3), built-in display 1470×956 pt @2x |
| Notch | **179 pt wide × 32 pt tall**, centred (measured with `NSScreen.auxiliaryTopLeftArea/RightArea`) |
| macOS | 27.0 |
| Apple's new speech engine (`SpeechAnalyzer` + `SpeechTranscriber`) | Available. **English models already installed**: en-US, en-IN, en-GB, en-AU, en-CA, en-IE, en-NZ, en-SG, en-ZA |
| Old speech engine (`SFSpeechRecognizer`) on-device | Available (fallback) |
| Swift toolchain | Swift 6.3.3 via Command Line Tools. Swift Testing is included |
| Xcode | **Not installed.** Not required (see §7) |
| Homebrew | Not installed. Not required |

**Honest market note:** this idea has been built many times in 2026. At least eight Mac notch teleprompters exist, and several free open-source ones already highlight words as you speak. So building our own makes sense if you want **full control, your own feature set, and better tracking than the existing apps**, or if you want to learn how to build it. On tracking specifically, the open-source matchers I read are simple, and there is clear room to beat them (see §4).

---

## 2. What already exists (inspiration)

| App | Price | What to borrow |
|---|---|---|
| **Textream** (open source, MIT, macOS 15+) | Free | Word-by-word highlighting, Dynamic-Island overlay, floating and full-screen modes, "Director mode", a browser remote, Sidecar output, PPTX speaker-notes import, `[annotation]` words skipped by the matcher. **Its source is the best reference we have.** |
| **NotchPrompt** (aliarain, open source, MIT) | Free | Clean module split (ScrollingController / SpeechRecognitionManager / WordFlowView), Classic mode that needs no permissions, CJK word splitting |
| **OpenTeleprompter** (open source) | Free | "Real concave corners, Apple spring physics, pixel-perfect notch fit", which is the visual target for the island shape |
| **Notchie 4.0** | $29.99 | A hover menu on the island (play, record, editor, hide) and your phone as a clicker |
| **Moody** | $39 | High-contrast text, Shift/arrow shortcuts |
| **Tellie**, **CueNotch**, **Mootch**, **VoicePrompter** | $0–29 | Word-level tracking. Mootch has a "Smart Mode" |
| **Avocado** | n/a | An MCP server, so Claude can write scripts straight into the prompter. Worth copying: I could push scripts to your app |
| **Speakflow "Flow"** (web/desktop) | Subscription | Three modes (Flow / Auto / Manual). Listening stops after about 30 s of silence |
| **PromptSmart VoiceTrack** (iPad) | Subscription | The original voice-follow product. Its reviews are the best list of what goes wrong: skipping ahead in quiet rooms, freezing, unreliable with built-in mics |
| **boring.notch**, **NotchDrop**, **DynamicNotchKit** (open source notch utilities) | Free | Hover-to-expand behaviour, island shapes and animation code |

**Lessons from user complaints:** voice tracking that *jumps ahead* or *freezes* loses trust fast. Some users switch it off and scroll manually. So:
1. Tracking must be conservative about big jumps.
2. A manual nudge must always be one key away.
3. Auto-scroll and manual modes must always be available as fallbacks.

---

## 3. What goes into the app (feature list)

### Must-have (MVP)
- **Notch island**: a black shape that grows out of the notch (Dynamic Island style), expands on start and collapses back to the notch when idle.
- **Script display**: word-by-word highlighting with three states: *spoken* (dimmed), *current* (accent colour), *upcoming* (full brightness). The current line stays at a fixed height, right under the camera.
- **Three scroll modes**
  - **Voice** (default): follows your speech word by word.
  - **Auto**: constant speed (WPM slider).
  - **Manual**: arrow keys, trackpad, or a clicker.
- **Pace following**: it learns your speaking rate live, keeps moving smoothly at your pace, and pauses when you pause.
- **Customisation**: panel width, number of visible lines, font, size, weight, line spacing, text/highlight/dimmed colours, background colour and opacity, corner radius, highlight style (colour / underline / pill).
- **Controls**: menu-bar icon (start, pause, restart, pick script, settings) and global hotkeys (start/pause, back a sentence, forward a sentence, faster/slower, show/hide).
- **Script editor**: paste or type a script. Scripts are saved locally.

### Should-have (v1)
- Import from .txt / .md / .rtf / **.docx** (macOS reads Word files natively) / .pdf.
- **Cue markup**: `[PAUSE]`, `[SMILE]`, `(breathe)` appear styled in the script and the voice tracker ignores them.
- **Click any word to jump there.**
- **Hide from screen sharing** toggle (see the risk in §8).
- Countdown (3-2-1), a mirror mode for beam-splitter glass rigs, floating mode, external-display mode (draws a fake notch on monitors without one).
- Microphone picker, language/accent picker (e.g. **en-IN** versus en-US), theme presets.
- Launch at login.

### Nice-to-have (later)
- **Rehearsal report**: words per minute over time, pauses, filler words ("um", "uh"), sections skipped.
- **Script vocabulary boost**: feed the script's names and jargon to the speech engine so it recognises them (`AnalysisContext.contextualStrings`, confirmed in the SDK).
- **On-device AI rewrite**: "make this more speakable" and auto-insert pauses, using Apple's `FoundationModels` framework (present on this Mac). Free and private.
- A URL scheme or CLI (`notchprompter://load?...`) so Claude or Shortcuts can push scripts into the app.
- iPhone as a remote, PPTX speaker-notes import.

---

## 4. How it works (architecture)

```
┌─────────────────────────── Notch Prompter.app (menu-bar app, no Dock icon) ───────────────────────────┐
│                                                                                                         │
│  Mic ──► AudioCapture (AVAudioEngine tap) ──┬──► SpeechAnalyzer + SpeechTranscriber ──► word hypotheses │
│                                             │      (on-device, volatile + final results)       │        │
│                                             └──► Level meter / SpeechDetector ──► "speaking?"  │        │
│                                                                                                ▼        │
│  Script ──► Tokenizer/Normalizer ──► [script words] ──────────────────────────────► ScriptAligner      │
│              (lowercase, punctuation, numbers,                                     (where am I?)        │
│               contractions, phonetic keys, cues)                                          │             │
│                                                                                           ▼             │
│                                                                              PaceModel (how fast am I?) │
│                                                                    smooth "display cursor" at your WPM, │
│                                                                    corrected by aligner, stops on pause │
│                                                                                           │             │
│                                                                                           ▼             │
│  NotchPanel (NSPanel, borderless, above everything) ◄── PrompterView (SwiftUI word layout, highlight,   │
│     positioned on the notch, expands/collapses           smooth scroll that keeps current line fixed)   │
│                                                                                                         │
│  MenuBarExtra · Settings window · Script library/editor · Global hotkeys · Persistence (JSON files)    │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 The notch window (feasible, done by every app listed above)
- `NSPanel` with `[.borderless, .nonactivatingPanel]`, so it never steals focus from Zoom or the recording app.
- Window level above the menu bar (`.statusBar` or higher). Collection behaviour `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` keeps it on every Space and over full-screen apps.
- Positioned at the screen's top centre. Width and height come from `NSScreen.auxiliaryTopLeftArea/RightArea` and `safeAreaInsets.top`, so the shape lines up with the real notch (179×32 here). On a monitor without a notch it draws a pill.
- **Shape**: the top strip stays notch-width so it never covers your menu-bar icons. Below the menu bar, the panel widens into the text area, with concave "ears" where it meets the notch. Expansion and collapse use spring animations.
- `sharingType = .none` hides it from capture, with a caveat (§8).
- Optional click-through, so the mouse passes through the text.

### 4.2 Hearing you (speech engine)
- **Default engine: Apple `SpeechAnalyzer` + `SpeechTranscriber`** (new in macOS 26, confirmed on this Mac). It runs on-device, costs nothing, handles long sessions, and the English models are already installed. Options confirmed in the SDK:
  - `reportingOptions: [.volatileResults, .fastResults]` gives quick, rough results that are refined later.
  - `attributeOptions: [.audioTimeRange]` gives word timings.
  - `setContext(AnalysisContext)` with `contextualStrings` biases recognition toward the script's words.
  - `SpeechDetector` provides voice-activity detection.
- **Fallback: `SFSpeechRecognizer`** (older API, on-device). Textream uses it, but it needs periodic restarts.
- **Swappable engine.** The engine sits behind a `TranscriptionEngine` protocol, so others can be added if Apple's isn't good enough:
  - **FluidAudio (Parakeet / Nemotron streaming)**: open source, runs on the Neural Engine, about 0.5–2 s latency tiers.
  - **WhisperKit**: less suited because Whisper works in 30-second windows.
  - **Cloud engines** (Deepgram, AssemblyAI): not needed, and they cost money and send your audio off the Mac.

### 4.3 Knowing where you are (`ScriptAligner`), which is the core of the product
Textream walks forward character by character from the last position. It cannot recover if you skip a sentence or go back. Ours will do better:

1. **Normalise both sides.** Lowercase, strip punctuation, expand numbers ("2026" ↔ "twenty twenty six"), handle contractions ("don't" ↔ "do not"), and add a phonetic key per word (Double Metaphone) so "their" / "there" and accent variations still match.
2. **Match the tail, not the whole transcript.** On every new hypothesis, take the last 6–8 spoken words and run a **local alignment (Smith-Waterman)** against a window of the script, from 10 words behind to 40 words ahead of the cursor. Exact, phonetic and near-spelling (Levenshtein) matches are scored differently.
3. **Asymmetric rules for moving.**
   - Small forward moves are accepted quickly.
   - Jumps forward of more than one sentence need about 4 strongly matched words in a row.
   - Going back (re-reading a line) needs about 3.
   - If nothing matches for a few seconds (you are ad-libbing), the cursor holds still. It then **widens the search to the whole script** to find you again.
4. **Volatile and final results.** Volatile results move the *display*. Final results *commit* the position. If a volatile guess is rewritten, the highlight corrects itself smoothly instead of jumping.
5. **Cue words** (`[PAUSE]`) and stage directions are excluded from matching.

### 4.4 Matching your pace (`PaceModel`), which makes it feel alive
Recognition results arrive in bursts, about 200–600 ms behind your voice. Highlighting only on results looks jerky and laggy, so:
- Keep a **live WPM estimate**, a smoothed average of words advanced per second while you are speaking.
- Run a **display cursor** that advances continuously at your WPM between results. This is a predicted highlight that hides recognition lag. It is capped at about 2 words ahead of the last confirmed word.
- When a new aligner position arrives, steer the display cursor toward it (a gentle catch-up, like a car's cruise control). It snaps only if it is more than about 5 words off.
- **Silence** (level meter or `SpeechDetector`) stops the display cursor within about 300 ms. Speaking again restarts it.
- Smooth scrolling (spring animation) keeps the current line at a fixed spot, so your eyes barely move.

### 4.5 Display (`PrompterView`)
- A custom SwiftUI `Layout` for word wrapping, with one view per word so each word can animate its own highlight. Only the visible lines plus a buffer are rendered, so long scripts stay fast.
- **Eye-contact defaults**: a narrow panel (about 380–450 pt), large text, 2–3 visible lines. Wide text makes your eyes visibly scan on camera.

### 4.6 Tech stack
Swift 6.3 · SwiftUI + AppKit (`NSPanel`) · Speech · AVFAudio · Observation · JSON files in Application Support for scripts and settings · Carbon `RegisterEventHotKey` for global hotkeys (no Accessibility permission needed) · `SMAppService` for launch at login. **Minimum macOS 26**, because of `SpeechAnalyzer`.

### 4.7 Project layout (Swift Package, no Xcode needed)
```
Mac Tele/
├── Package.swift
├── Sources/
│   ├── PrompterCore/          ← pure logic, fully unit-tested
│   │   ├── Tokenizer.swift  Normalizer.swift  Phonetic.swift
│   │   ├── ScriptAligner.swift  PaceModel.swift
│   │   └── Script.swift  Settings.swift
│   ├── PrompterSpeech/        ← audio + speech engines
│   │   ├── AudioCapture.swift  TranscriptionEngine.swift
│   │   ├── AppleSpeechEngine.swift  LegacySpeechEngine.swift
│   └── NotchPrompter/         ← the app
│       ├── App.swift  MenuBar.swift  Hotkeys.swift
│       ├── NotchPanel.swift  IslandShape.swift  PrompterView.swift
│       ├── ScriptEditor.swift  SettingsView.swift
├── Tests/PrompterCoreTests/   ← aligner/pace tests with synthetic transcripts
├── Tools/prompter-bench/      ← replays audio files through the engine, scores accuracy
├── Resources/Info.plist  AppIcon.icns
└── scripts/build-app.sh  install.sh  make-fixtures.sh
```

---

## 5. Build plan (phases)

| Phase | What gets built | You can… |
|---|---|---|
| **0. Spikes** (first session) | (a) Notch panel prototype on this Mac, plus a test of whether `sharingType = .none` hides it from Zoom/QuickTime on macOS 27. (b) `SpeechAnalyzer` streaming from the mic, measuring real latency and whether volatile results carry word timings. (c) Build, sign and permission flow using only the Command Line Tools | See text in your notch and get numbers for latency and screen-share hiding |
| **1. MVP** | Island with expand/collapse, paste a script, Auto mode with word highlighting, core settings (width, lines, font, size, colours), menu bar, hotkeys | Use it as a normal notch teleprompter |
| **2. Voice tracking** | Speech pipeline, `ScriptAligner`, `PaceModel`, silence pause, mic picker, click-to-jump, a small "tracking confidence" dot | Read naturally and have it follow you |
| **3. Polish** | Script library and imports, cue markup, presets/themes, floating and external-display modes, mirror, countdown, hide-from-share toggle, onboarding for permissions, launch at login | Use it daily |
| **4. Extras** | Rehearsal report, vocabulary boost, on-device AI rewrite, URL scheme/CLI so Claude can push scripts, phone remote | Rehearse and improve |

---

## 6. How we'll test it

1. **Unit tests** (`swift test`, Swift Testing, works without Xcode): tokenizer edge cases (numbers, punctuation, contractions, cues) and the aligner against scripted transcripts:
   - a perfect read
   - recognition errors ("their"/"there", dropped words)
   - **skipping a sentence or paragraph**
   - **going back and re-reading a line**
   - **ad-libbing** a sentence not in the script
   - stopping mid-sentence
   - volatile results that get rewritten

   Scoring: percentage of time the highlight is within ±1 word of the truth, worst lag, and the number of false jumps.
2. **Automated audio benchmark (`prompter-bench`)**: macOS's built-in voices generate readings of test scripts at 120 / 160 / 200 / 240 WPM. `AVSpeechSynthesizer` reports the exact moment each word is spoken, which gives the ground truth. The bench feeds the audio through the real speech engine at real-time speed and scores tracking, including variants with background noise, inserted ad-libs and skipped sections. Every change to the aligner gets checked against this.
3. **Your own voice**: you record 5–6 short takes of a sample script (normal, fast, slow, one with a skip, one with ad-libs). These become permanent regression fixtures, so the tracker is tuned to *your* accent and pace.
4. **Real-world checklist** (manual):
   - notch alignment on the built-in display
   - an external monitor (fake notch)
   - full-screen apps
   - multiple Spaces and Stage Manager
   - sleep/wake
   - **switching mics mid-session (AirPods connecting)**
   - **screen sharing in Zoom, Google Meet, Teams, QuickTime and OBS** (is it hidden?)
   - recording in Photo Booth / QuickTime / Loom at the same time
   - light and dark wallpapers
5. **Performance**: CPU and energy while tracking (target: under about 10% CPU on M5, no fan, minimal battery drain). The latency target is that the highlight *feels* instant (under 300 ms perceived, with the pace model's prediction).
6. **Visual checks**: I can take screenshots of the notch area while it runs to confirm layout and alignment without you checking by hand.

---

## 7. How it gets built and installed

**Recommended: Command Line Tools only (what's installed now).**
- `scripts/build-app.sh` runs `swift build -c release`, assembles `Notch Prompter.app` (binary, `Info.plist`, icon), and code-signs it. `Info.plist` sets `LSUIElement` (menu-bar only, no Dock icon) and the microphone and speech-recognition permission prompts.
- **Signing so permissions stick:** macOS ties mic and speech permission to the app's signature. With throwaway "ad-hoc" signing, every rebuild looks like a new app and macOS asks again or silently denies access. The fix is a one-time self-signed **code-signing certificate** made in Keychain Access (about 2 minutes, I'll walk you through it). Every build is then signed with it and permissions persist.
- `scripts/install.sh` copies the app to `~/Applications` (or `/Applications`) and launches it. A settings toggle adds it to Login Items.
- **Optional: install Xcode** (free, App Store, about 10+ GB). This adds the visual debugger, Instruments (detailed CPU/energy profiling) and SwiftUI previews. It's useful but not needed to start.
- **If you ever share or sell it:** an Apple Developer account ($99/yr) for Developer ID signing and notarization, a DMG, a Homebrew cask, and Sparkle for auto-updates. Without notarization, other people must run `xattr -cr` on the app to open it, as several open-source notch apps tell users to.

**⚠️ iCloud Drive warning:** this folder is in iCloud Drive. Swift builds create thousands of temporary files, and iCloud syncing them causes slow builds and occasional corruption. Either:
- keep the source here and send build output outside iCloud (`--scratch-path ~/Library/Caches/NotchPrompter`, which I'll set up in the scripts), or
- move the project to `~/Developer/MacTele` and use git for backup (my recommendation).

---

## 8. Risks and unknowns (tested first, in Phase 0)

| Risk | Detail | Plan |
|---|---|---|
| ~~Hiding from screen share may not work~~ **Works on macOS 27** | Developer reports said macOS 15.4+ ScreenCaptureKit ignores `sharingType = .none`. **Phase 0 test: the panel was invisible in a ScreenCaptureKit display capture with `.none` and visible with `.readOnly`** | Keep one real Zoom share on the test checklist |
| Recognition misses names/jargon | Any speech engine stumbles on rare words | Vocabulary boost from the script, phonetic matching, conservative jump rules |
| Other voices (call audio, room) move the cursor | The mic hears the other side of a video call through speakers | Multi-word match required to move; headphones recommended; optional echo cancellation (it can lower other apps' volume, so it's off by default) |
| AirPods mic lowers audio quality | Using AirPods as a mic switches them to low-quality call mode | Default to the built-in mic; mic picker |
| Mic switching crashes the audio engine | Textream has a lot of code for this exact case | Rebuild the audio engine on configuration-change notifications (lesson borrowed from Textream) |
| Eye movement visible on camera | Wide text makes your eyes scan | Narrow default width, large text, current line fixed under the camera |
| Volatile results lack word timings | Forum reports conflict | The pace model doesn't depend on them. It uses arrival time and word count |

---

## 9. Decisions for you

1. **Name**, e.g. "Notch Prompter" (placeholder).
2. **Project location**: stay in iCloud Drive (with build output outside it) or move to `~/Developer`? *Recommendation: move it.*
3. **Xcode**: install now or later? *Recommendation: later. Command Line Tools are enough for Phases 0–3.*
4. **Start Phase 0** (three spikes, about one session): get text into your notch, measure speech latency, and answer the screen-share question.

---

### Sources
- Textream source: [github.com/f/textream](https://github.com/f/textream), [SpeechRecognizer.swift](https://github.com/f/textream/blob/main/Textream/Textream/SpeechRecognizer.swift), [NotchOverlayController.swift](https://github.com/f/textream/blob/main/Textream/Textream/NotchOverlayController.swift)
- [NotchPrompt (aliarain)](https://github.com/aliarain/notchprompt) · [OpenTeleprompter](https://github.com/ArunNGun/openTeleprompt) · [NotchPrompter](https://github.com/jpomykala/NotchPrompter) · [Notchy](https://github.com/lucianodiisouza/notchy-desktop-macos)
- [Notchie](https://notchie.app/) · [ShareSpeak: 12 Mac teleprompters compared (Oct 2026)](https://sharespeak.co/best-teleprompter-mac) · [Avocado: 8 notch teleprompters compared](https://avocadonotch.com/blog/notch-teleprompter-macbook) · [Tellie on r/macapps](https://www.reddit.com/r/macapps/comments/1ux5xyb/tellie_the_mac_notch_teleprompter_that_highlights/)
- [Speakflow Flow mode docs](https://www.speakflow.com/docs/scroll-modes-flow-auto) · [PromptSmart](https://promptsmart.com/) · [PromptSmart Pro App Store reviews](https://apps.apple.com/us/app/id894811756)
- [Apple Dev Forums: sharingType none still captured on macOS 15.4+](https://developer.apple.com/forums/thread/792152) · [Write-up on what broke in macOS 15](https://www.producthunt.com/p/jobpath/how-apps-hide-windows-from-screen-capture-and-what-broke-in-macos-15)
- [WWDC25 session 277: SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) · [Forum: audioTimeRange on volatile results](https://developer.apple.com/forums/thread/794510) · [SpeechAnalyzer volatileRange docs](https://developer.apple.com/documentation/speech/speechanalyzer/volatilerange.md)
- [FluidAudio (Parakeet/Nemotron on Apple Silicon)](https://github.com/FluidInference/FluidAudio) · [FluidAudio benchmarks](https://docs.fluidinference.com/reference/benchmarks) · [Microsoft paper on on-device streaming ASR (Apr 2026)](https://arxiv.org/html/2604.14493v2)
- [autocue (fuzzy-matching speech tracker)](https://github.com/EdNutting/autocue)
