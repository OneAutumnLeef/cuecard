// SpeechSpike: measures how fast Apple's on-device SpeechAnalyzer reports words.
//
//   SpeechSpike file <audio> [--ref script.txt] [--locale en-US] [--log out.txt] [--no-realtime] [--no-fast]
//   SpeechSpike mic [--seconds 40] [--ref script.txt] [--locale en-IN] [--log out.txt]
//
// "file" streams an audio file into the recognizer in 100 ms chunks, paced like a live mic.
// "mic" listens to the real microphone (needs the .app bundle for the permission prompt).

import AVFoundation
import CoreMedia
import Foundation
import Speech

enum SpikeError: Error, CustomStringConvertible {
    case msg(String)
    var description: String { if case .msg(let s) = self { return s }; return "" }
}

enum Log {
    nonisolated(unsafe) static var handle: FileHandle?
    static func open(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }
    static func line(_ s: String) {
        print(s)
        fflush(stdout)
        if let h = handle, let d = (s + "\n").data(using: .utf8) { h.write(d) }
    }
}

struct Options {
    var mode = "file"
    var audioPath: String?
    var refPath: String?
    var seconds: Double = 40
    var locale = "en-US"
    var logPath: String?
    var realtime = true
    var fast = true
    var auth = false
    var recordPath: String?
    var engine = "speech"        // speech = SpeechTranscriber, dictation = DictationTranscriber
    var contextMode: String?     // words | phrases (uses --ref text as hints)
}

/// Plays a system sound without needing an AppKit run loop.
func chime(_ name: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = ["/System/Library/Sounds/\(name).aiff"]
    try? p.run()
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "file": o.mode = "file"; o.audioPath = it.next()
        case "mic": o.mode = "mic"
        case "--ref": o.refPath = it.next()
        case "--seconds": o.seconds = Double(it.next() ?? "") ?? 40
        case "--locale": o.locale = it.next() ?? "en-US"
        case "--log": o.logPath = it.next()
        case "--no-realtime": o.realtime = false
        case "--no-fast": o.fast = false
        case "--auth": o.auth = true
        case "--record": o.recordPath = it.next()
        case "--engine": o.engine = it.next() ?? "speech"
        case "--context": o.contextMode = it.next()
        default: Log.line("ignoring unknown argument: \(a)")
        }
    }
    return o
}

func tokenize(_ s: String) -> [String] {
    s.lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .map { $0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" }.map(String.init).joined() }
        .filter { !$0.isEmpty }
}

func editDistance(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    for i in 1...a.count {
        var cur = [i] + Array(repeating: 0, count: b.count)
        for j in 1...b.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return prev[b.count]
}

func percentile(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
}

func ms(_ x: Double?) -> String { x.map { String(format: "%4.0f ms", $0 * 1000) } ?? "   n/a" }

final class Probe: @unchecked Sendable {
    struct Event {
        let wall: Double, audioStart: Double, audioEnd: Double
        let isFinal: Bool, words: [String], runs: Int, timedRuns: Int
    }

    let opts: Options
    private let lock = NSLock()
    private var t0: Date?
    private var events: [Event] = []
    private var finalWords: [(word: String, end: Double)] = []
    private var finalizedCount = 0
    private var shown: [(wall: Double, count: Int)] = []

    init(_ o: Options) { opts = o }

    private func now() -> Double { t0.map { Date().timeIntervalSince($0) } ?? 0 }

    func handle(_ attr: AttributedString, _ range: CMTimeRange, _ isFinal: Bool) {
        lock.lock(); defer { lock.unlock() }
        let wall = now()
        let text = String(attr.characters)
        let words = tokenize(text)
        var runs = 0, timed = 0
        for run in attr.runs {
            runs += 1
            guard let tr = run.audioTimeRange else { continue }
            timed += 1
            if isFinal {
                let w = String(attr[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !w.isEmpty { finalWords.append((w, tr.end.seconds)) }
            }
        }
        let e = Event(wall: wall, audioStart: range.start.seconds, audioEnd: range.end.seconds,
                      isFinal: isFinal, words: words, runs: runs, timedRuns: timed)
        events.append(e)
        if isFinal { finalizedCount += words.count }
        shown.append((wall, isFinal ? finalizedCount : finalizedCount + words.count))
        Log.line(String(format: "[%6.2fs] %@ audio %5.2f–%5.2f  lag %+5.2fs  runs %2d timed %2d | %@",
                        wall, isFinal ? "FINAL" : "vol  ", e.audioStart, e.audioEnd, wall - e.audioEnd, runs, timed, text))
    }

    /// Script words or phrases handed to the recognizer as hints.
    private func contextStrings() -> [String]? {
        guard let mode = opts.contextMode, let ref = opts.refPath,
              let text = try? String(contentsOfFile: ref, encoding: .utf8) else { return nil }
        if mode == "phrases" {
            return text.components(separatedBy: CharacterSet(charactersIn: ".,;:!?\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.split(separator: " ").count >= 2 }
        }
        var seen = Set<String>()
        return text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func run() async throws {
        if opts.auth {
            let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            Log.line("Speech recognition authorization: \(status.rawValue) (3 = authorized)")
        }
        let locale = Locale(identifier: opts.locale)
        let module: any SpeechModule
        let results: Task<Void, Error>
        if opts.engine == "dictation" {
            var reporting: Set<DictationTranscriber.ReportingOption> = [.volatileResults]
            if opts.fast { reporting.insert(.frequentFinalization) }
            let d = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: reporting, attributeOptions: [.audioTimeRange])
            module = d
            results = Task { for try await r in d.results { self.handle(r.text, r.range, r.isFinal) } }
        } else {
            var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
            if opts.fast { reporting.insert(.fastResults) }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                      reportingOptions: reporting, attributeOptions: [.audioTimeRange])
            module = t
            results = Task { for try await r in t.results { self.handle(r.text, r.range, r.isFinal) } }
        }
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Log.line("Downloading speech model for \(opts.locale)…")
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw SpikeError.msg("No compatible audio format")
        }
        Log.line("Engine \(opts.engine), locale \(opts.locale), fast \(opts.fast), context \(opts.contextMode ?? "none"), format: \(fmt)")
        let tPrep = Date()
        try await analyzer.prepareToAnalyze(in: fmt)
        Log.line(String(format: "Model ready in %.2fs", Date().timeIntervalSince(tPrep)))
        if let strings = contextStrings() {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = strings
            try await analyzer.setContext(ctx)
            Log.line("Gave the recognizer \(strings.count) hint strings")
        }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        if opts.mode == "mic" { try await feedMic(cont, fmt) } else { try await feedFile(cont, fmt) }
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results.value
        summarize()
    }

    private func convert(_ buf: AVAudioPCMBuffer, _ conv: AVAudioConverter, _ fmt: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { throw SpikeError.msg("buffer alloc") }
        var given = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, st in
            if given { st.pointee = .noDataNow; return nil }
            given = true
            st.pointee = .haveData
            return buf
        }
        if status == .error { throw err ?? SpikeError.msg("conversion failed") }
        return out
    }

    private func feedFile(_ cont: AsyncStream<AnalyzerInput>.Continuation, _ fmt: AVAudioFormat) async throws {
        guard let path = opts.audioPath else { throw SpikeError.msg("file mode needs an audio path") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let inFmt = file.processingFormat
        guard let conv = AVAudioConverter(from: inFmt, to: fmt) else { throw SpikeError.msg("no converter") }
        let chunk = AVAudioFrameCount(inFmt.sampleRate * 0.1)
        Log.line(String(format: "Feeding %.1fs of audio %@", Double(file.length) / inFmt.sampleRate,
                        opts.realtime ? "paced like a live mic" : "as fast as possible"))
        lock.withLock { t0 = Date() }
        var fed = 0.0
        func push(_ buf: AVAudioPCMBuffer) async throws {
            let end = fed + Double(buf.frameLength) / inFmt.sampleRate
            if opts.realtime, end - now() > 0 { try await Task.sleep(for: .seconds(end - now())) }
            cont.yield(AnalyzerInput(buffer: try convert(buf, conv, fmt)))
            fed = end
        }
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            try await push(buf)
        }
        for _ in 0..<15 {  // 1.5 s of silence, like the speaker stopping
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk) else { break }
            buf.frameLength = chunk
            for ch in 0..<Int(inFmt.channelCount) { buf.floatChannelData?[ch].update(repeating: 0, count: Int(chunk)) }
            try await push(buf)
        }
    }

    private func feedMic(_ cont: AsyncStream<AnalyzerInput>.Continuation, _ fmt: AVAudioFormat) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SpikeError.msg("Microphone permission denied") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        Log.line("Mic format: \(inFmt)")
        guard let conv = AVAudioConverter(from: inFmt, to: fmt) else { throw SpikeError.msg("no converter") }
        // Optionally keep the raw mic audio so one reading can be replayed through other settings later.
        let recording = try opts.recordPath.map { try AVAudioFile(forWriting: URL(fileURLWithPath: $0), settings: inFmt.settings) }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { buf, _ in
            self.lock.lock()
            if self.t0 == nil { self.t0 = Date().addingTimeInterval(-Double(buf.frameLength) / inFmt.sampleRate) }
            self.lock.unlock()
            try? recording?.write(from: buf)
            if let out = try? self.convert(buf, conv, fmt) { cont.yield(AnalyzerInput(buffer: out)) }
        }
        engine.prepare()
        try engine.start()
        chime("Glass")
        Log.line("LISTENING for \(Int(opts.seconds))s. Read the test script aloud now.")
        try await Task.sleep(for: .seconds(opts.seconds))
        input.removeTap(onBus: 0)
        engine.stop()
        chime("Submarine")
        Log.line("Stopped listening." + (opts.recordPath.map { " Audio saved to \($0)" } ?? ""))
    }

    private func summarize() {
        lock.lock(); defer { lock.unlock() }
        let vol = events.filter { !$0.isFinal }, fin = events.filter { $0.isFinal }
        Log.line("\n=== Summary ===")
        Log.line("Results: \(vol.count) volatile, \(fin.count) final")
        let walls = events.map(\.wall)
        let gaps = zip(walls.dropFirst(), walls).map { $0 - $1 }
        Log.line("Gap between results:            median \(ms(percentile(gaps, 0.5)))   p90 \(ms(percentile(gaps, 0.9)))")
        let vLag = vol.map { $0.wall - $0.audioEnd }, fLag = fin.map { $0.wall - $0.audioEnd }
        Log.line("Volatile result lag (vs audio): median \(ms(percentile(vLag, 0.5)))   p90 \(ms(percentile(vLag, 0.9)))")
        Log.line("Final result lag (vs audio):    median \(ms(percentile(fLag, 0.5)))   p90 \(ms(percentile(fLag, 0.9)))")
        var wordLags: [Double] = []
        for (k, fw) in finalWords.enumerated() {
            if let first = shown.first(where: { $0.count >= k + 1 }) { wordLags.append(first.wall - fw.end) }
        }
        Log.line("Word lag (spoken → first shown): median \(ms(percentile(wordLags, 0.5)))   p90 \(ms(percentile(wordLags, 0.9)))   max \(ms(wordLags.max()))")
        Log.line("Word timings present: \(vol.filter { $0.timedRuns > 0 }.count)/\(vol.count) volatile, \(fin.filter { $0.timedRuns > 0 }.count)/\(fin.count) final")
        if let ref = opts.refPath, let text = try? String(contentsOfFile: ref, encoding: .utf8) {
            let refW = tokenize(text), hyp = fin.flatMap(\.words)
            let d = editDistance(refW, hyp)
            Log.line(String(format: "Word error rate vs script: %d edits / %d words = %.1f%%", d, refW.count, 100 * Double(d) / Double(max(1, refW.count))))
        }
    }
}

@main
struct SpeechSpikeMain {
    static func main() async {
        let o = parseOptions()
        if let p = o.logPath { Log.open(p) }
        do { try await Probe(o).run() } catch { Log.line("ERROR: \(error)"); exit(1) }
        exit(0)
    }
}
