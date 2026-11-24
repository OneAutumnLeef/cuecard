import Foundation
import PrompterCore

/// One voice session, recorded on request for tuning: what the recogniser heard and when, the mic level,
/// and where the highlight was. Saved next to the session's audio in ~/Library/Caches/MacTele/sessions.
struct DiagnosticTake: Codable {
    struct Heard: Codable { var t: Double; var text: String; var final: Bool }
    struct Level: Codable { var t: Double; var db: Double }
    struct Sample: Codable { var t: Double; var display: Double; var confirmed: Double; var speaking: Bool }

    var script: String
    var locale: String
    var audioFile: String
    var events: [Heard] = []
    var levels: [Level] = []
    var samples: [Sample] = []

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTele/sessions", isDirectory: true)
    }

    static func newBaseURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("take-\(f.string(from: Date()))")
    }

    func save(to base: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try enc.encode(self).write(to: base.appendingPathExtension("json"))
    }
}
