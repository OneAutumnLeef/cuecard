import AppKit
import CoreImage
import Network
import PrompterCore
import SwiftUI
import SystemConfiguration

/// A tiny web server on your Wi-Fi so a phone can drive the prompter: open the page (QR code in the
/// Phone Remote window) and tap. Off until you turn it on; every request must carry the private code.
@Observable
final class PhoneRemote {
    static let port: UInt16 = 47321

    private(set) var isRunning = false
    private(set) var status = "Off"
    private(set) var lastSeen: Date?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var listener: NWListener?

    init(model: AppModel) { self.model = model }

    var token: String {
        if model.settings.remoteToken.isEmpty {
            let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
            model.settings.remoteToken = String((0..<8).map { _ in chars.randomElement()! })
        }
        return model.settings.remoteToken
    }

    /// e.g. http://MacBook-Air.local:47321/k3m9xq2a
    var address: String { "http://\(Self.hostName()):\(Self.port)/\(token)" }
    var ipAddress: String? { Self.lanIPv4().map { "http://\($0):\(Self.port)/\(token)" } }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.isRunning = true; self?.status = "On: open the link on your phone"
                    case .failed(let e): self?.status = "Couldn't start: \(e.localizedDescription)"; self?.stop()
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.serve(conn) }
            }
            l.start(queue: .main)
            listener = l
            status = "Starting…"
        } catch {
            status = "Couldn't start: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        if !status.hasPrefix("Couldn't") { status = "Off" }
    }

    func newToken() {
        model.settings.remoteToken = ""
        _ = token
    }

    // MARK: - HTTP

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                guard let self, let data, let request = String(data: data, encoding: .utf8) else { conn.cancel(); return }
                let (status, type, body) = self.respond(to: request)
                let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                    + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    private func respond(to request: String) -> (String, String, Data) {
        let parts = request.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return ("400 Bad Request", "text/plain", Data()) }
        let method = String(parts[0])
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
        let segments = path.split(separator: "/").map(String.init)
        guard segments.first == token else { return ("404 Not Found", "text/plain", Data("Not found".utf8)) }
        lastSeen = Date()
        switch (method, segments.dropFirst().first) {
        case ("GET", nil):
            return ("200 OK", "text/html; charset=utf-8", Data(Self.page(token: token).utf8))
        case ("GET", "state"):
            return ("200 OK", "application/json", stateJSON())
        case ("POST", "cmd"):
            let name = segments.count > 2 ? segments[2] : ""
            perform(name)
            return ("200 OK", "application/json", stateJSON())
        default:
            return ("404 Not Found", "text/plain", Data("Not found".utf8))
        }
    }

    private func perform(_ command: String) {
        switch command {
        case "toggle": model.togglePlay()
        case "back": model.previousSentence()
        case "next": model.nextSentence()
        case "restart": model.restart()
        case "faster": model.faster()
        case "slower": model.slower()
        case "show": model.toggleShown()
        case "voice": model.toggleVoiceMode()
        default: break
        }
    }

    private func stateJSON() -> Data {
        let lines = model.lines
        let tokens = model.script.tokens
        func text(_ li: Int) -> String {
            guard li >= 0, li < lines.count else { return "" }
            return lines[li].map { tokens[$0].text }.joined(separator: " ")
        }
        let cur = model.currentLine
        var current = ""
        if cur < lines.count {
            current = lines[cur].map { ti in ti == model.currentIndex ? "[[\(tokens[ti].text)]]" : tokens[ti].text }
                .joined(separator: " ")
        }
        let state: [String: Any] = [
            "title": model.currentScriptID,
            "playing": model.isPlaying,
            "shown": model.isShown,
            "voice": model.isVoiceMode,
            "wpm": model.isVoiceMode ? model.measuredWPM : Int(model.settings.wpm),
            "remaining": formatClock(model.remainingSeconds),
            "progress": tokens.isEmpty ? 0 : Double(model.currentIndex) / Double(max(tokens.count - 1, 1)),
            "previous": text(cur - 1), "current": current, "next": text(cur + 1) + " " + text(cur + 2),
        ]
        return (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
    }

    // MARK: - Network names

    static func hostName() -> String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } ?? (Host.current().name ?? "localhost")
    }

    static func lanIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }

    static func qrCode(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: - The phone page

    static func page(token: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="apple-mobile-web-app-capable" content="yes"><title>Notch Prompter Remote</title>
        <style>
        :root{color-scheme:dark}*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
        body{margin:0;background:#0b0b0d;color:#f2f2f2;font:16px -apple-system,system-ui,sans-serif;padding:16px;
             padding-top:max(16px,env(safe-area-inset-top));min-height:100vh;display:flex;flex-direction:column;gap:14px}
        header{display:flex;justify-content:space-between;align-items:baseline;color:#9a9aa0;font-size:14px}
        #title{color:#f2f2f2;font-weight:600;font-size:17px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:65%}
        .lines{background:#18181b;border-radius:16px;padding:16px;min-height:150px;line-height:1.35}
        #prev{color:#6d6d73;font-size:17px}#cur{font-size:24px;font-weight:600;margin:6px 0}#next{color:#c9c9ce;font-size:18px}
        mark{background:none;color:#ffcc40}
        .bar{height:4px;background:#26262a;border-radius:2px;overflow:hidden}.bar i{display:block;height:100%;background:#ffcc40;width:0}
        .grid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px}
        button{appearance:none;border:0;border-radius:16px;background:#232327;color:#f2f2f2;font-size:17px;font-weight:600;
               padding:18px 6px;touch-action:manipulation}
        button:active{background:#34343a}
        #toggle{grid-column:1/-1;font-size:24px;padding:28px;background:#2d5bff}
        #toggle.playing{background:#3a3a40}
        .small{font-size:15px;color:#c9c9ce}
        </style></head><body>
        <header><span id="title">Notch Prompter</span><span id="meta"></span></header>
        <div class="bar"><i id="bar"></i></div>
        <div class="lines"><div id="prev"></div><div id="cur">Connecting…</div><div id="next"></div></div>
        <div class="grid">
          <button id="toggle" onclick="cmd('toggle')">Start</button>
          <button onclick="cmd('back')">◀︎ Sentence</button>
          <button onclick="cmd('restart')">Restart</button>
          <button onclick="cmd('next')">Sentence ▶︎</button>
          <button class="small" id="slower" onclick="cmd('slower')">Slower</button>
          <button class="small" id="voice" onclick="cmd('voice')">Voice</button>
          <button class="small" id="faster" onclick="cmd('faster')">Faster</button>
          <button class="small" style="grid-column:1/-1" onclick="cmd('show')">Show / hide prompter</button>
        </div>
        <script>
        const base='/\(token)';
        const esc=s=>s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
        function render(s){
          document.getElementById('title').textContent=s.title||'Notch Prompter';
          document.getElementById('meta').textContent=(s.voice?'🎙 ':'')+(s.wpm?s.wpm+' wpm · ':'')+s.remaining;
          document.getElementById('prev').textContent=s.previous;
          document.getElementById('cur').innerHTML=esc(s.current).replace(/\\[\\[(.*?)\\]\\]/,'<mark>$1</mark>');
          document.getElementById('next').textContent=s.next;
          document.getElementById('bar').style.width=(s.progress*100)+'%';
          const t=document.getElementById('toggle');t.textContent=s.playing?'Pause':'Start';t.classList.toggle('playing',s.playing);
          document.getElementById('voice').textContent=s.voice?'Voice ✓':'Fixed speed';
          for(const id of ['slower','faster'])document.getElementById(id).style.opacity=s.voice?.35:1;
        }
        async function poll(){try{render(await (await fetch(base+'/state')).json())}catch(e){document.getElementById('cur').textContent='Not connected: is the Mac awake and on the same Wi-Fi?'}}
        async function cmd(c){try{render(await (await fetch(base+'/cmd/'+c,{method:'POST'})).json())}catch(e){}}
        poll();setInterval(poll,500);
        </script></body></html>
        """
    }
}

// MARK: - Window

final class PhoneRemoteWindowController: NSObject {
    private var window: NSWindow?
    private let remote: PhoneRemote

    init(remote: PhoneRemote) { self.remote = remote }

    var nsWindow: NSWindow? { window }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Phone Remote"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PhoneRemoteView(remote: remote))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PhoneRemoteView: View {
    let remote: PhoneRemote

    var body: some View {
        VStack(spacing: 16) {
            Toggle("Phone remote", isOn: Binding(get: { remote.isRunning }, set: { $0 ? remote.start() : remote.stop() }))
                .toggleStyle(.switch)
                .font(.headline)
            Text(remote.status).font(.callout).foregroundStyle(.secondary)
            if remote.isRunning {
                if let qr = PhoneRemote.qrCode(remote.address) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .padding(10).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text("Scan with your phone's camera (same Wi-Fi), or open:").font(.callout)
                Text(remote.address).font(.callout.monospaced()).textSelection(.enabled)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if let ip = remote.ipAddress {
                    Text("If that doesn't load: \(ip)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if let seen = remote.lastSeen {
                    Text("Phone connected \(seen.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.green)
                }
            } else {
                Text("Turn this on to control the prompter from your phone's browser: start, pause, jump sentences, change speed, and see the current lines. Nothing is installed on the phone, and the link includes a private code.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
            Button("New Private Link") { remote.newToken() }
                .help("Makes old links stop working")
        }
        .padding(24)
        .frame(width: 380, height: 520)
    }
}
