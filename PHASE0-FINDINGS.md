# Phase 0 Findings

*24 Nov 2026 · MacBook Air M5, macOS 27.0 · Spike code in [Spikes/](Spikes/), build script in [scripts/build-app.sh](scripts/build-app.sh)*

## The answers

| Question | Answer |
|---|---|
| **Can a panel sit in the notch and look right?** | **Yes.** You confirmed it on the built-in display. The panel is 440×142 pt around a 179×32 pt notch, at window level `mainMenu + 3`, and it joins the notch cleanly. |
| **Does "hide from screen share" work on macOS 27?** | **Yes, for ScreenCaptureKit**, which Zoom, Meet and OBS use. With `sharingType = .none` the panel was **invisible** in a full-display capture: the window behind it showed instead (0% black pixels in the text area). With `.readOnly` it was captured (78% black). The forum reports that macOS 15.4+ ignores the flag don't hold on 27. Still worth one real Zoom screen share before relying on it on a live call. |
| **How quickly do spoken words arrive?** | About **0.7 s median, 1.0 s p90, 1.6 s worst** from the moment a word is spoken to the moment it appears. That was the same for generated voices at 130–220 WPM and for your own voice. Results come in **bursts about once a second**. |
| **Does `.fastResults` matter?** | **Hugely.** Without it, delay is 2.4 s median and 3.6 s p90. It stays on. |
| **How accurate is recognition?** | Generated voices: **3.4%** word errors once number formatting is normalised. **Your voice, built-in mic: 26%** (78% of words right). The en-IN and en-US models gave identical results on your recording. Boosting your quiet recording by +10 dB helped only a little (28.6% → 26.1% raw). |
| **Is that accurate enough to track position?** | **Yes, with the right design.** On your recording, **70% of script words** sit inside a run of 3+ correctly heard words (solid anchors). The longest stretch without an anchor was **16 words (about 6 s)**. The tracker locks on at anchors and coasts at your pace in between. |
| **Do script hints help (`contextualStrings`)?** | **No measurable effect** on `SpeechTranscriber`. The older `DictationTranscriber` was worse: 41% errors, or 35% with phrase hints. **Use `SpeechTranscriber`.** |
| **Which permissions are needed?** | **Microphone only.** `SpeechAnalyzer` didn't need the Speech Recognition permission. Transcribing files needs no permission at all, so automated tests can run without prompts. |
| **Can it be built and installed with only the Command Line Tools?** | **Yes.** `swift build` → `.app` bundle → codesign → `open`. Microphone and screen-recording prompts work. **But with ad-hoc signing, macOS forgets permissions after every rebuild** (confirmed: the screen-recording grant was lost after a rebuild). Daily development needs a stable signing certificate. |
| **Does replaying a recording behave like live?** | **Yes.** Your recording replayed through the engine gave the same delay (726 ms vs 719 ms median) and the same errors as the live run. Recordings are valid regression tests. |

## Raw numbers

All runs use `SpeechTranscriber`, with audio fed in 100 ms chunks at live-mic pace (`SpeechSpike file …`), unless noted.

| Run | Word delay median / p90 / max | Raw WER | WER (numbers normalised) |
|---|---|---|---|
| Generated US voice, 170 WPM, `.fastResults` | 699 / 1013 / 1081 ms | 8.4% | 3.4% |
| Same, **without** `.fastResults` | 2387 / 3647 / 3947 ms | 8.4% | — |
| Generated US voice, 220 WPM | 633 / 938 / 1079 ms | 10.9% | — |
| Generated Indian voice, 170 WPM, en-IN model | 660 / 963 / 1083 ms | 8.4% | 3.4% |
| **Your voice, live mic, en-IN** | **719 / 1035 / 1547 ms** | 28.6% | **26.1%** |
| Your recording replayed, en-IN | 726 / 1038 / 1507 ms | 28.6% | 26.1% |
| Your recording replayed, en-US | 735 / 1055 / 1680 ms | 28.6% | — |
| Your recording +10 dB | — | 26.1% | — |

Other observations:
- The speech model starts in **0.03 s** once it has been used before. It transcribes about **90× faster than real time** on the M5 (47 s of audio in 0.5 s).
- **Volatile results carry no per-word timings.** They have one time range for the whole string. Final results have per-word timings but arrive only at sentence ends, every 4–10 s.
- Volatile results include **half-words** ("join", "wa", "disapp"). Prefix matching gives the tracker an earlier signal.
- The common recogniser errors on the generated voices are number formats: "3" for three, "40%" for forty percent, "1st" for first. Normalising numbers is mandatory.
- Your recording was quiet: −30 dBFS RMS while speaking, versus −20 dBFS for the generated voice. Speaking closer to the Mac or using an external mic should help a little.

## What changes in the plan

1. **The pace model is essential, not a nice-to-have.** Words arrive in bursts about 0.7–1 s late. Highlighting only from recognition would look jumpy and late, so the display must predict your position at your WPM and correct itself on each burst.
2. **The aligner must handle about 25% recognition errors.** That means sequence alignment with phonetic and near-spelling similarity, number normalisation, prefix matches for half-words, and coasting through stretches of up to about 6 s with no anchor. Exact matching (as in Textream) would stall on your voice.
3. **Always use `SpeechTranscriber` with `.volatileResults` + `.fastResults`.** No vocabulary hints (no effect), and no dictation engine (worse).
4. **Only one permission prompt** (microphone), which makes onboarding simpler.
5. **A stable code-signing identity is needed before Phase 1**, so macOS keeps the microphone permission across rebuilds.
6. **Recordings are the test suite.** Your reading is saved at `~/Library/Caches/MacTele/fixtures/you-read-1.caf`, outside iCloud and only on this Mac. More takes (fast, slow, skipping, ad-libbing) make the tracker tuning honest.
7. **Visual polish to fix:** during the scroll animation the next line peeks through the bottom fade. The fade should reach zero at the bottom edge.
8. **Hide-from-share stays a headline feature.** It works on macOS 27. Keep the toggle and keep one real-Zoom check on the test list.

## Spike code

- `Spikes/Sources/NotchSpike`: the notch panel (island shape, word wrapping, highlight, spring scroll), plus `--snapshot` (renders a PNG) and `--capture-test` (ScreenCaptureKit leak test).
- `Spikes/Sources/SpeechSpike`: the speech pipeline with live-paced file replay, mic capture and recording, latency and WER metrics, and `--engine` / `--context` switches.
- `scripts/build-app.sh`: builds any target into a signed `.app`, with build output kept outside iCloud.

```bash
scripts/build-app.sh Spikes NotchSpike dev.mactele.notchspike
```
```bash
open ~/Library/Caches/MacTele/apps/NotchSpike.app --args --seconds 30 --script "$PWD/Spikes/fixtures/script1.txt"
```
