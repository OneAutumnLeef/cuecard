// prompter-bench: measures how well the voice tracker follows real speech.
//
//   prompter-bench variants <script.txt> <outdir> [--voice NAME] [--rate WPM]
//       Writes test readings of the script made with a macOS voice: exact, skip (a sentence left out),
//       reread (a sentence read twice), adlib (an unscripted sentence), pause (a 3.5 s stop).
//   prompter-bench record <audio> --out <fixture.json> [--locale en-IN] [--meta <variant.meta.json>]
//       Plays the audio through the real recogniser at live speed and saves what it heard, when,
//       plus microphone levels and word timings for ground truth. Needs no permissions.
//   prompter-bench score <script.txt> <fixture.json>... [--trace] [--lag S] [--lead W] [--gain G] [--hangover S]
//       Replays the fixtures through the tracker (instantly) and reports how close the highlight stays.

import Foundation
import PrompterCore
import PrompterSpeech

struct Fixture: Codable {
    struct Event: Codable { var t: Double; var text: String; var final: Bool }
    struct Level: Codable { var t: Double; var db: Double }
    var audio: String
    var locale: String
    var events: [Event]
    var levels: [Level]
    var words: [TimedWord]
    var spoken: [SpokenWord]?
}

struct SpokenWord: Codable { var word: String; var script: Int? }

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

func option(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func positional(_ args: [String]) -> [String] {
    var out: [String] = []
    var skip = false
    for a in args {
        if skip { skip = false; continue }
        if a.hasPrefix("--") { skip = !["--trace"].contains(a); continue }
        out.append(a)
    }
    return out
}

// MARK: - variants

func makeVariants(scriptPath: String, outDir: String, voice: String, rate: Int) throws {
    let script = Script(text: try String(contentsOfFile: scriptPath, encoding: .utf8))
    let spokenScript = SpokenScript(script)
    let starts = script.sentenceStarts + [script.tokens.count]
    let sentences = (0..<(starts.count - 1)).map { starts[$0]..<starts[$0 + 1] }
    guard sentences.count >= 5 else { fail("Need a script with at least 5 sentences") }

    enum Segment { case sentence(Int), adlib(String), pause(Double) }
    let adlib = "And honestly, nobody on the team believed it would work."
    let all = Array(sentences.indices)
    let variants: [(String, [Segment])] = [
        ("exact", all.map { .sentence($0) }),
        ("skip", all.filter { $0 != 2 }.map { .sentence($0) }),
        ("reread", [0, 1, 2, 3, 2].map { Segment.sentence($0) } + all.dropFirst(4).map { .sentence($0) }),
        ("adlib", [0, 1, 2, 3].map { Segment.sentence($0) } + [.adlib(adlib)] + all.dropFirst(4).map { .sentence($0) }),
        ("pause", [0, 1, 2].map { Segment.sentence($0) } + [.pause(3.5)] + all.dropFirst(3).map { .sentence($0) }),
    ]
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    for (name, segments) in variants {
        var sayText: [String] = []
        var spoken: [SpokenWord] = []
        for seg in segments {
            switch seg {
            case .sentence(let k):
                var parts: [String] = []
                for ti in sentences[k] where script.tokens[ti].kind == .word {
                    parts.append(script.tokens[ti].text)
                    for (j, w) in SpokenForm.words(script.tokens[ti].text).enumerated() {
                        spoken.append(SpokenWord(word: w, script: spokenScript.firstWordOfToken[ti] + j))
                    }
                }
                sayText.append(parts.joined(separator: " "))
            case .adlib(let text):
                sayText.append(text)
                for token in text.split(separator: " ") {
                    for w in SpokenForm.words(String(token)) { spoken.append(SpokenWord(word: w, script: nil)) }
                }
            case .pause(let s):
                sayText.append("[[slnc \(Int(s * 1000))]]")
            }
        }
        let base = (outDir as NSString).appendingPathComponent(name)
        try sayText.joined(separator: " ").write(toFile: base + ".txt", atomically: true, encoding: .utf8)
        try JSONEncoder().encode(spoken).write(to: URL(fileURLWithPath: base + ".meta.json"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-r", String(rate), "-o", base + ".aiff", "-f", base + ".txt"]
        try p.run()
        p.waitUntilExit()
        print("wrote \(base).aiff (\(spoken.count) spoken words)")
    }
}

// MARK: - record

@MainActor final class Recorder {
    var events: [Fixture.Event] = []
    var levels: [Fixture.Level] = []
    let start = Date()
    func now() -> Double { Date().timeIntervalSince(start) }
}

@MainActor func record(audio: String, out: String, locale: String, meta: String?) async throws {
    let url = URL(fileURLWithPath: audio)
    let rec = Recorder()
    let listener = SpeechListener(locale: Locale(identifier: locale),
                                  onText: { h in rec.events.append(.init(t: rec.now(), text: h.text, final: h.isFinal)) },
                                  onLevel: { db in rec.levels.append(.init(t: rec.now(), db: db)) },
                                  onNotice: { print("note: \($0)") })
    print("Replaying \(url.lastPathComponent) at live speed…")
    try await listener.runFile(url, realtime: true)
    print("Getting word timings…")
    let words = try await SpeechListener.transcribeWords(url, locale: Locale(identifier: locale))
    var spoken: [SpokenWord]?
    if let meta { spoken = try JSONDecoder().decode([SpokenWord].self, from: Data(contentsOf: URL(fileURLWithPath: meta))) }
    let fixture = Fixture(audio: url.lastPathComponent, locale: locale, events: rec.events, levels: rec.levels,
                          words: words, spoken: spoken)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted]
    try enc.encode(fixture).write(to: URL(fileURLWithPath: out))
    print("Saved \(rec.events.count) results, \(rec.levels.count) levels, \(words.count) timed words → \(out)")
}

// MARK: - score

/// Global alignment of heard words to spoken words; returns, for each spoken word, the index of the heard word matched to it.
func alignGlobal(_ heard: [String], _ spoken: [String]) -> [Int?] {
    let m = heard.count, n = spoken.count
    var d = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { d[i][0] = Double(i) * 0.8 }
    for j in 0...n { d[0][j] = Double(j) * 0.8 }
    if m > 0 && n > 0 {
        for i in 1...m {
            for j in 1...n {
                let sim = WordMatch.similarity(heard[i - 1], spoken[j - 1])
                d[i][j] = min(d[i - 1][j] + 0.8, d[i][j - 1] + 0.8, d[i - 1][j - 1] + (sim >= 0.6 ? 1 - sim : 1.2))
            }
        }
    }
    var match = [Int?](repeating: nil, count: n)
    var i = m, j = n
    while i > 0 && j > 0 {
        let sim = WordMatch.similarity(heard[i - 1], spoken[j - 1])
        if d[i][j] == d[i - 1][j - 1] + (sim >= 0.6 ? 1 - sim : 1.2) {
            if sim >= 0.6 { match[j - 1] = i - 1 }
            i -= 1; j -= 1
        } else if d[i][j] == d[i - 1][j] + 0.8 {
            i -= 1
        } else {
            j -= 1
        }
    }
    return match
}

struct Metrics {
    var within1 = 0.0, within2 = 0.0, within3 = 0.0, meanAbs = 0.0, meanLag = 0.0, p90Lag = 0.0, maxAhead = 0.0
    var reachedEnd = false
}

func metrics(_ samples: [(t: Double, pos: Double, truth: Double)], end reached: Bool) -> Metrics {
    guard !samples.isEmpty else { return Metrics() }
    let errs = samples.map { $0.pos - $0.truth }
    let n = Double(errs.count)
    let lags = errs.map { -$0 }.sorted()
    var m = Metrics()
    m.within1 = Double(errs.filter { abs($0) <= 1 }.count) / n
    m.within2 = Double(errs.filter { abs($0) <= 2 }.count) / n
    m.within3 = Double(errs.filter { abs($0) <= 3 }.count) / n
    m.meanAbs = errs.map(abs).reduce(0, +) / n
    m.meanLag = lags.reduce(0, +) / n
    m.p90Lag = lags[Int(Double(lags.count - 1) * 0.9)]
    m.maxAhead = errs.max() ?? 0
    m.reachedEnd = reached
    return m
}


/// When each script word was spoken, from the recogniser's settled word timings aligned to what was read.
func groundTruth(_ fx: Fixture, _ spokenScript: SpokenScript) -> ([(script: Int?, start: Double)], (Double) -> Double?)? {
        let spoken = fx.spoken ?? spokenScript.words.enumerated().map { SpokenWord(word: $1, script: $0) }
        // Ground truth: when each spoken word started, from the recogniser's settled word timings.
        let heard = fx.words.flatMap { w in SpokenForm.words(w.text).map { (word: $0, start: w.start) } }
        let match = alignGlobal(heard.map(\.word), spoken.map(\.word))
        var starts = match.map { $0.map { heard[$0].start } }
        let known = starts.indices.filter { starts[$0] != nil }
        guard let firstKnown = known.first, let lastKnown = known.last else { return nil }
        for k in starts.indices where starts[k] == nil {
            if k < firstKnown { starts[k] = starts[firstKnown]! - Double(firstKnown - k) * 0.4 }
            else if k > lastKnown { starts[k] = starts[lastKnown]! + Double(k - lastKnown) * 0.4 }
            else {
                let a = known.last { $0 < k }!, b = known.first { $0 > k }!
                starts[k] = starts[a]! + (starts[b]! - starts[a]!) * Double(k - a) / Double(b - a)
            }
        }
        let timeline = zip(spoken, starts.map { $0! }).map { (script: $0.script, start: $1) }
        func truth(_ t: Double) -> Double? {
            timeline.last { $0.start <= t && $0.script != nil }?.script.map(Double.init)
        }

        return (timeline, truth)
}

/// Scores a live diagnostic take: the app's own highlight positions against ground truth from replaying its audio.
func scoreLive(takePath: String, fixturePath: String) throws {
    struct Take: Codable {
        struct Sample: Codable { var t: Double; var display: Double; var confirmed: Double; var speaking: Bool }
        var script: String
        var samples: [Sample]
    }
    let take = try JSONDecoder().decode(Take.self, from: Data(contentsOf: URL(fileURLWithPath: takePath)))
    let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
    let spokenScript = SpokenScript(Script(text: take.script))
    guard let (timeline, truth) = groundTruth(fx, spokenScript) else { fail("no usable timings") }
    let from = (timeline.first?.start ?? 0) + 2, to = timeline.last?.start ?? 0
    var live: [(t: Double, pos: Double, truth: Double)] = [], confirmed = live
    for smp in take.samples where smp.t >= from && smp.t <= to {
        guard let tr = truth(smp.t) else { continue }
        live.append((smp.t, smp.display, tr))
        confirmed.append((smp.t, smp.confirmed, tr))
    }
    let m = metrics(live, end: true), c = metrics(confirmed, end: true)
    print(String(format: "LIVE app highlight: within ±1 %.0f%%  ±2 %.0f%%  ±3 %.0f%% | mean err %.2f  mean lag %.2f words  p90 lag %.2f | max ahead %.1f",
                 m.within1 * 100, m.within2 * 100, m.within3 * 100, m.meanAbs, m.meanLag, m.p90Lag, m.maxAhead))
    print(String(format: "LIVE confirmed only: within ±2 %.0f%% | mean lag %.2f words", c.within2 * 100, c.meanLag))
}

func score(scriptPath: String, fixtures: [String], config: TrackerConfig, trace: Bool) throws {
    let spokenScript = SpokenScript(Script(text: try String(contentsOfFile: scriptPath, encoding: .utf8)))
    print("fixture            | within ±1  ±2   ±3 | mean err  lag  p90 lag | max ahead | end | baseline ±2 (no prediction)")
    print(String(repeating: "-", count: 112))
    for path in fixtures {
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let (timeline, truth) = groundTruth(fx, spokenScript) else { print("\(path): no usable timings"); continue }
        var tracker = VoiceTracker(script: spokenScript, config: config)
        var ei = 0, li = 0
        var t = 0.0
        let endT = (timeline.last?.start ?? 0) + 2.5
        var samples: [(Double, Double, Double)] = []
        var baseline: [(Double, Double, Double)] = []
        let from = (timeline.first?.start ?? 0) + 2.0
        let to = timeline.last?.start ?? 0
        var nextTrace = 0.0
        while t < endT {
            while li < fx.levels.count, fx.levels[li].t <= t { tracker.level(fx.levels[li].db, at: fx.levels[li].t); li += 1 }
            while ei < fx.events.count, fx.events[ei].t <= t { tracker.hear(fx.events[ei].text, isFinal: fx.events[ei].final, at: fx.events[ei].t); ei += 1 }
            tracker.advance(to: t)
            if t >= from, t <= to, let tr = truth(t) {
                samples.append((t, Double(tracker.displayWord), tr))
                baseline.append((t, tracker.confirmed, tr))
            }
            if trace, t >= nextTrace {
                print(String(format: "  t=%5.1f display=%6.1f confirmed=%5.0f truth=%@ speaking=%@ %@ rate=%.0fwpm",
                             t, tracker.display, tracker.confirmed, truth(t).map { String(format: "%.0f", $0) } ?? "-",
                             tracker.isSpeaking ? "y" : "n", "\(tracker.confidence)", tracker.wordsPerMinute))
                nextTrace += 0.5
            }
            t += 1.0 / 60
        }
        let m = metrics(samples, end: tracker.confirmed >= Double(spokenScript.count - 3))
        let b = metrics(baseline, end: true)
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let padded = name.padding(toLength: 18, withPad: " ", startingAt: 0)
        print(String(format: "%@ |  %4.0f%% %4.0f%% %4.0f%% |   %4.2f  %5.2f   %5.2f  |   %5.1f   | %@ |   %4.0f%%",
                     padded as NSString, m.within1 * 100, m.within2 * 100, m.within3 * 100, m.meanAbs, m.meanLag, m.p90Lag,
                     m.maxAhead, (m.reachedEnd ? "yes" : " no") as NSString, b.within2 * 100))
    }
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: prompter-bench variants|record|score …") }
let rest = Array(args.dropFirst())
let pos = positional(rest)

switch command {
case "variants":
    guard pos.count >= 2 else { fail("usage: prompter-bench variants <script.txt> <outdir>") }
    try makeVariants(scriptPath: pos[0], outDir: pos[1], voice: option(rest, "--voice") ?? "Eddy (English (US))",
                     rate: Int(option(rest, "--rate") ?? "") ?? 170)
case "record":
    guard let audio = pos.first, let out = option(rest, "--out") else { fail("usage: prompter-bench record <audio> --out <fixture.json>") }
    let locale = option(rest, "--locale") ?? "en-US"
    let meta = option(rest, "--meta")
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        do { try await record(audio: audio, out: out, locale: locale, meta: meta) } catch { print("error: \(error)") }
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
case "score":
    guard pos.count >= 2 else { fail("usage: prompter-bench score <script.txt> <fixture.json>…") }
    var c = TrackerConfig()
    if let v = option(rest, "--lag").flatMap(Double.init) { c.recognitionLag = v }
    if let v = option(rest, "--lead").flatMap(Double.init) { c.maxLeadWords = v }
    if let v = option(rest, "--gain").flatMap(Double.init) { c.catchUpGain = v }
    if let v = option(rest, "--hangover").flatMap(Double.init) { c.voiceHangover = v }
    if let v = option(rest, "--lead-seconds").flatMap(Double.init) { c.maxLeadSeconds = v }
    if let v = option(rest, "--bias").flatMap(Double.init) { c.highlightBias = v }
    try score(scriptPath: pos[0], fixtures: Array(pos.dropFirst()), config: c, trace: rest.contains("--trace"))
case "live":
    guard pos.count >= 2 else { fail("usage: prompter-bench live <take.json> <fixture.json>") }
    try scoreLive(takePath: pos[0], fixturePath: pos[1])
default:
    fail("unknown command \(command)")
}
