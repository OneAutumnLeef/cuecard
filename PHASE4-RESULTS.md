# Phase 4 Results: Extras

*24 Nov 2026 · You confirmed all four: rehearsal report, phone remote, PowerPoint import and AI rewrite.*

## Rehearsal report

When you read a script to the end in voice mode, a report opens. You can turn that off in Settings → Voice, and **Rehearsal Report…** in the menu shows it any time. It covers:
- **Time**, **pace** (words per minute) and **coverage** (how much of the script you said)
- **Pauses**, including the longest
- **Filler words**: "um", "uh" and "erm" always count; "basically", "actually", "you know", "I mean", "sort of" and "kind of" count only beyond their uses in the script
- **Pace through the script**, as a chart against your average
- **Skipped** and **read again** passages, quoted
- **Tips**, only when something stands out: too fast or slow, uneven pace, lots of fillers, skipped parts
- **History** of your rehearsals of the same script, to see progress

Reports are saved in `~/Library/Application Support/MacTele/Rehearsals/`.

Two analysis bugs were caught on your recording and fixed:
- **A false "skip":** when the tracker caught up after misheard words, that counted as a skip. Now a jump counts as a skip only if it's bigger than what you could have said in the time.
- **"Stopped at 86%" on a finished read:** the last words are confirmed after you stop talking, and the report ignored them. On your recording it now reads 100%, with no false skips.

## Phone remote

Menu → **Phone Remote…** → switch it on and scan the QR code. Your phone's browser gets:
- big Start/Pause, sentence back and forward, Restart, Slower/Faster, voice/fixed, and show/hide
- the current lines with the live word highlighted, a progress bar, time left and pace

How it works and stays private:
- A tiny web server built into the app, on port 47321, local Wi-Fi only. Nothing to install on the phone.
- **Off by default.** Every request must include a private code; anything else gets "not found". **New Private Link** makes old links stop working.

## Getting scripts in

- **PowerPoint speaker notes:** Import a .pptx and you get each slide's notes in presentation order, with a `[Slide N]` stage note before each slide. Slides without notes are skipped.
- **`notchprompter://` links,** for Shortcuts and other apps:

  ```
  notchprompter://add?title=Pitch&text=Hello%20there&start=1
  notchprompter://open?title=Pitch&start=1
  notchprompter://start | pause | toggle | show | hide | restart
  notchprompter://mode?voice=1        (0 = fixed speed)
  ```

- **The `prompter` command** in `scripts/prompter`. I can use it to put a script I've written straight into your prompter:

  ```bash
  scripts/prompter add talk.md --title "Q3 Review" --start
  ```
  ```bash
  echo "Hello everyone…" | scripts/prompter add - --title "Opening"
  ```
  ```bash
  scripts/prompter open "Q3 Review"; scripts/prompter toggle; scripts/prompter voice off; scripts/prompter list
  ```

  Long scripts go through an Inbox folder the app empties after importing. Links can't point at files anywhere else.

## AI rewrite (Apple Intelligence, on this Mac)

The **Rewrite** (wand) menu in the editor offers four rewrites:
- **Easier to Say**
- **Shorter (about 20%)**
- **Add Pauses** (inserts `[PAUSE]`)
- **Spell Out Numbers and Symbols** ("40%" → "forty percent")

It works paragraph by paragraph and keeps stage notes and line breaks. You always get an editable preview first, then **Replace Script** or **Save as New Script**. When the model isn't ready, the button says why: downloading, Apple Intelligence off, or Mac not eligible.

## Fixed along the way

Two app copies claimed `notchprompter://` (the installed app and the build copy in the cache folder). During testing, a link reached a fresh copy on your real settings and switched you to fixed speed. That's restored to voice, and `make install` now unregisters the build copy so links only ever reach the installed app.

## Numbers

- **62 unit tests** pass: link parsing and safety, PowerPoint notes order, rehearsal pace/pauses/skips/catch-ups/fillers, report storage.
- **App version 0.4.0.**

## Still not done

- **Configurable shortcuts.**
- **Sharing the app with others.** Needs an Apple Developer account ($99/yr) for Developer ID signing and notarisation, plus a DMG and auto-updates.
