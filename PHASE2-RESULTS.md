# Phase 2 Results: Following Your Voice

*24 Nov 2026 · You confirmed it keeps up, follows your pace, recovers from skips and re-reads, and stays mostly green.*

## How it works

```
Mic ─► SpeechListener (AVAudioEngine → SpeechAnalyzer, volatile + fastResults, on-device)
          │ heard text (~0.7 s late, bursts ≈1/s)        │ mic level (dBFS, 10–20×/s)
          ▼                                                ▼
     VoiceTracker.hear()                           VoiceTracker.level()  → voice on / off
          │  match the last 8 heard words against the script
          │  (local alignment; numbers/ordinals/% normalised; near-spellings and half-words count)
          ▼
     confirmed position ──► predicted display position (your measured pace × time talking,
                             capped at max(4.5 words, 1.6 s of speech) past the evidence,
                             frozen the moment you stop) ──► lit word = display + 0.5
```

**Movement rules.**
- Small forward steps need ordinary evidence.
- Jumping ahead or back (skips, re-reads) needs 3+ solid word matches in the new place.
- Ad-libbing holds the position.
- After 3 s of talking with no match, it searches the whole script.
- Clicking a word, or jumping a sentence, re-anchors and waits for speech before predicting again.

**Voice detection** treats the quietest fifth of the last 10 seconds as the room's background noise, and counts anything 10 dB above that as speech. The first version learned your room wrongly, which is why the highlight kept moving through your pauses.

## Benchmark (`prompter-bench`)

The tracker was tuned against real recogniser output, not guesses:
- **Five readings with a macOS voice**: exact, a skipped sentence, a re-read sentence, an ad-lib, and a 3.5 s pause.
- **Your Phase 0 reading.**
- **Your live diagnostic take.**

Each was played through the real recogniser at live speed and recorded once. The tracker then replays instantly against ground-truth word timings, which makes tuning fast and repeatable.

Scores below measure **the word that actually lights up** against the word being spoken:

| Recording | Within ±1 word | ±2 | ±3 | Average lag | Without prediction (±2) |
|---|---|---|---|---|---|
| Clean reading | 79% | **98%** | 100% | 0.1 ahead | 26% |
| Skipped sentence | 78% | 92% | 94% | 0.35 behind | 31% |
| Re-read sentence | 70% | 84% | 86% | 0.4 ahead | 28% |
| Ad-lib | 72% | 88% | 91% | 0.6 ahead | 38% |
| 3.5 s pause | 73% | 90% | 100% | 0.4 ahead | 39% |
| Your Phase 0 reading | 64% | 83% | 94% | 0.4 ahead | 42% |
| **Your live take** | **68%** | **94%** | **100%** | **0.0** | 20% |

**What changed along the way:**
- Fixed the voice detector, which had been treating your steady speech as background noise.
- Widened the backward search: re-reads used to take about 5 s to catch; now about 2.5 s.
- Smoothed the pace estimate, which used to spike to 300 wpm.
- Made the lead cap time-based and nudged the lit word forward. On your live take, lag went from 1.3 words to 0.

**The live app matches the replay** (80% vs 80% within ±2 before tuning), so the app itself adds no delay.

## In the app

- **Voice is the default mode.** `⌃⌥V` switches between voice and fixed speed, and so does the waveform/metronome button on hover. Your place is kept when switching.
- **Beside the notch:**
  - "Start reading" until it locks on, then the time left.
  - A mic icon on the right: **green** = locked on, **amber** = coasting between matches, **red** = lost, red-slashed = mic problem.
  - Your live pace in words per minute.
- **Settings → Voice:** scrolling mode, microphone (or System default), and language (Automatic = the Mac's language, here English (India); or any installed English model).
- **Menu (right-click the prompter):**
  - *Follow My Voice*
  - *Microphone ▸*
  - *Record Diagnostic Take*: saves the next voice session's audio and log to `~/Library/Caches/MacTele/sessions` for tuning. Delete that folder any time.
- **Microphone switching** (AirPods connecting, a mic unplugged) rebuilds the audio engine and keeps listening.
- **Only the microphone permission is used.** It persists across rebuilds thanks to the stable signing identity.

## Commands

```bash
make test        # 44 unit tests (parsing, pacing, layout, settings, spoken forms, tracker simulations)
```
```bash
make install     # build + install ~/Applications/Notch Prompter.app
```
```bash
swift run --scratch-path ~/Library/Caches/MacTele/build/root prompter-bench score Spikes/fixtures/script1.txt ~/Library/Caches/MacTele/fixtures/bench/*.json
```

The other bench commands are `variants` (make test readings), `record` (play audio through the recogniser and save a fixture) and `live` (score a diagnostic take). Fixtures and recordings live in `~/Library/Caches/MacTele/fixtures`, outside iCloud and the repo.

## Known limits

- **Recognition errors still cause short stalls.** On phrases the recogniser mangles (about 25% of your words), the highlight coasts up to about 1.6 s of speech, then waits.
- **Re-reading takes about 2.5 s to catch.** It needs three solid words in the new place. That's deliberate: fewer false jumps.
- **Repeated phrases** (the welcome text says "Control Option" many times) are handled by context. A script that repeats whole sentences could still confuse it briefly.
- **The live take used the old welcome script.** A take on one of your real scripts would be the next best tuning data.
