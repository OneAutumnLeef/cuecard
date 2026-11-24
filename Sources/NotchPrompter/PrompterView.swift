import PrompterCore
import SwiftUI

/// Flush with the top of the screen, concave top corners like the real notch, rounded bottom.
struct IslandShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 20

    func path(in r: CGRect) -> Path {
        let t = min(topRadius, r.width / 4), b = min(bottomRadius, r.height / 2, r.width / 4)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct PrompterView: View {
    let model: AppModel

    var body: some View {
        let g = model.geometry
        let s = model.settings
        let expanded = model.isExpanded
        ZStack(alignment: .top) {
            if g.floating {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(s.backgroundColor.color.opacity(s.backgroundOpacity))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
                    .frame(width: g.panelWidth, height: g.panelHeight)
                    .opacity(expanded ? 1 : 0)
                    .scaleEffect(expanded ? 1 : 0.94)
            } else {
                IslandShape()
                    .fill(s.backgroundColor.color.opacity(s.backgroundOpacity))
                    .frame(width: expanded ? g.panelWidth : max(g.notchWidth, 2),
                           height: expanded ? g.panelHeight : g.notchHeight)
            }
            if expanded {
                VStack(spacing: 0) {
                    StatusStrip(model: model)
                        .frame(width: g.panelWidth, height: g.notchHeight)
                    ZStack {
                        TextArea(model: model)
                        CountdownOverlay(model: model)
                    }
                    .frame(width: g.textWidth, height: g.textHeight)
                    .scaleEffect(x: s.mirror ? -1 : 1, y: 1)   // for beam-splitter teleprompter glass
                    .overlay(alignment: .bottom) {
                        if model.isHovering {
                            HoverControls(model: model)
                                .transition(.opacity.combined(with: .offset(y: 6)))
                        } else {
                            NoticeOverlay(model: model)
                        }
                    }
                    .animation(.easeOut(duration: 0.16), value: model.isHovering)
                    .animation(.easeOut(duration: 0.2), value: model.notice)
                    .padding(.top, PanelGeometry.topGap)
                }
                .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.08)))
            }
        }
        .frame(width: g.panelWidth, height: g.panelHeight, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: expanded)
    }
}

/// Left of the notch: time left (or a prompt to start reading). Right: mode, state and pace.
/// In voice mode the mic turns green while it's locked on, amber while coasting between matches,
/// and red when it has lost your place.
struct StatusStrip: View {
    let model: AppModel

    var body: some View {
        let g = model.geometry
        let show = g.wingWidth >= 48
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if show { left }
            }
            .frame(width: g.wingWidth)
            Spacer(minLength: 0)
            if g.floating {
                // Drag handle for the floating panel (the notch occupies this spot otherwise).
                Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 5)
                    .padding(.vertical, 8).padding(.horizontal, 14)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                if show { right }
            }
            .frame(width: g.wingWidth)
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var left: some View {
        if model.isVoiceMode, model.isPlaying, model.voiceConfidence == .waiting {
            Text(model.listening == .starting ? "Starting mic…" : "Start reading")
                .foregroundStyle(.white.opacity(0.75))
        } else {
            Image(systemName: "timer")
            Text(formatClock(model.remainingSeconds))
        }
    }

    @ViewBuilder private var right: some View {
        if model.isFinished {
            Image(systemName: "checkmark")
        } else if model.isVoiceMode {
            if case .failed = model.listening {
                Image(systemName: "mic.slash.fill").foregroundStyle(.red.opacity(0.85))
            } else if model.isPlaying {
                Image(systemName: "mic.fill")
                    .foregroundStyle(micColor)
                    .scaleEffect(model.voiceActive ? 1.15 : 1)
                    .animation(.easeOut(duration: 0.15), value: model.voiceActive)
                if model.voiceConfidence == .locked || model.voiceConfidence == .coasting {
                    Text("\(model.measuredWPM)")
                }
            } else {
                Image(systemName: "pause.fill")
                Image(systemName: "waveform").font(.system(size: 10))
            }
        } else {
            Image(systemName: model.isPlaying ? "play.fill" : "pause.fill")
                .contentTransition(.symbolEffect(.replace))
            Text("\(Int(model.settings.wpm))")
        }
    }

    private var micColor: Color {
        switch model.voiceConfidence {
        case .waiting: .white.opacity(0.75)
        case .locked: Color(red: 0.35, green: 0.85, blue: 0.5)
        case .coasting: Color(red: 1.0, green: 0.75, blue: 0.3)
        case .lost: Color(red: 1.0, green: 0.42, blue: 0.38)
        }
    }
}

/// Short messages ("Following your voice", microphone problems) shown over the bottom of the text.
struct NoticeOverlay: View {
    let model: AppModel

    var body: some View {
        if let text = model.notice, !model.isHovering {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color(white: 0.17)))
                .padding(.bottom, 2)
                .transition(.opacity)
        }
    }
}

struct TextArea: View {
    let model: AppModel

    var body: some View {
        let g = model.geometry
        if model.script.isEmpty || model.lines.isEmpty {
            Text("Your script is empty. Press ⌃⌥E to write one.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let cur = model.currentLine
            let lo = max(0, cur - 1)
            let hi = min(model.lines.count - 1, cur + g.visibleLines)
            ZStack(alignment: .top) {
                ForEach(lo...hi, id: \.self) { li in
                    LineView(model: model, line: li)
                        .frame(width: g.textWidth, height: g.lineHeight,
                               alignment: model.settings.alignment == .center ? .center : .leading)
                        .offset(y: CGFloat(li - cur) * g.lineHeight)
                        .transition(.opacity)
                }
            }
            .frame(width: g.textWidth, height: g.textHeight, alignment: .top)
            .animation(.spring(response: 0.5, dampingFraction: 0.86), value: cur)
            .clipped()
            .mask(fade(lines: g.visibleLines))
        }
    }

    /// A light fade at the top edge, and across the lower part of the last line so text scrolling in looks soft.
    private func fade(lines: Int) -> LinearGradient {
        let n = Double(lines)
        let top = 0.10 / n
        let bottom = lines == 1 ? 0.96 : 1 - 0.45 / n
        return LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: top),
            .init(color: .black, location: bottom), .init(color: .black.opacity(0.0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

struct LineView: View {
    let model: AppModel
    let line: Int

    var body: some View {
        let s = model.settings
        let tokens = model.script.tokens
        HStack(spacing: model.spaceWidth) {
            ForEach(model.lines[line], id: \.self) { ti in
                WordView(token: tokens[ti], state: state(ti), settings: s, font: model.font)
                    .contentShape(Rectangle())
                    .onTapGesture { model.jump(to: ti) }
            }
        }
        .fixedSize()
    }

    private func state(_ ti: Int) -> WordState {
        ti < model.currentIndex ? .spoken : (ti == model.currentIndex ? .current : .upcoming)
    }
}

enum WordState { case spoken, current, upcoming }

struct WordView: View {
    let token: Token
    let state: WordState
    let settings: PrompterSettings
    let font: NSFont

    var body: some View {
        let isCurrent = state == .current
        Text(token.text)
            .font(Font(font as CTFont))
            .foregroundStyle(foreground)
            .background {
                if isCurrent && settings.highlightStyle == .pill {
                    Capsule().fill(settings.highlightColor.color)
                        .padding(.horizontal, -5)
                        .padding(.vertical, 1)
                }
            }
            .overlay(alignment: .bottom) {
                if isCurrent && settings.highlightStyle == .underline {
                    Capsule().fill(settings.highlightColor.color).frame(height: 3).offset(y: 2)
                }
            }
            .animation(.easeOut(duration: 0.12), value: state)
    }

    private var foreground: Color {
        let isCue = token.kind == .cue
        let base = isCue ? settings.cueColor.color : settings.textColor.color
        switch state {
        case .spoken:
            return base.opacity(settings.spokenOpacity)
        case .upcoming:
            return isCue ? base.opacity(0.85) : base
        case .current:
            switch settings.highlightStyle {
            case .color: return isCue ? base : settings.highlightColor.color
            case .pill: return settings.backgroundColor.color
            case .underline: return base
            }
        }
    }
}

/// Appears while the cursor is over the island, so everything is reachable even when the
/// menu-bar icon sits behind the island.
struct HoverControls: View {
    let model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(white: 0.17)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .foregroundStyle(.white.opacity(0.92))
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(.plain)
        .padding(.bottom, 2)
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: compact ? 11 : 15) {
            icon(model.isVoiceMode ? "waveform" : "metronome") { model.toggleVoiceMode() }
                .foregroundStyle(model.isVoiceMode ? Color(red: 0.45, green: 0.85, blue: 0.6) : .white.opacity(0.92))
            separator
            icon("arrow.counterclockwise") { model.restart() }
            if !compact { icon("backward.end.fill") { model.previousSentence() } }
            icon(model.countdown != nil ? "xmark.circle" : (model.isPlaying ? "pause.fill" : "play.fill")) { model.togglePlay() }
            if !compact { icon("forward.end.fill") { model.nextSentence() } }
            if !model.isVoiceMode {
                separator
                icon("minus") { model.slower() }
                Text("\(Int(model.settings.wpm))").font(.system(size: 11, weight: .semibold).monospacedDigit())
                icon("plus") { model.faster() }
            }
            separator
            icon("square.and.pencil") { model.openEditor?() }
            icon("gearshape") { model.openSettings?() }
            icon("eye.slash") { model.hide() }
        }
        .fixedSize()
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 14)
    }

    private func icon(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).frame(width: 18, height: 18).contentShape(Rectangle())
        }
    }
}

struct CountdownOverlay: View {
    let model: AppModel

    var body: some View {
        if let n = model.countdown {
            ZStack {
                model.settings.backgroundColor.color.opacity(0.88)
                Text("\(n)")
                    .font(.system(size: min(model.geometry.textHeight * 0.75, 64), weight: .bold, design: .rounded))
                    .foregroundStyle(model.settings.highlightColor.color)
                    .contentTransition(.numericText(countsDown: true))
            }
            .animation(.snappy, value: n)
            .transition(.opacity)
        }
    }
}
