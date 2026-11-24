import AppKit
import Charts
import PrompterCore
import SwiftUI

final class RehearsalWindowController: NSObject {
    private var window: NSWindow?
    private var host: NSHostingView<RehearsalReportView>?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    var nsWindow: NSWindow? { window }

    func show(_ report: RehearsalReport) {
        let history = model.store.rehearsals.all(script: report.scriptTitle)
        let view = RehearsalReportView(report: report, history: history)
        if let host {
            host.rootView = view
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Rehearsal Report"
            w.isReleasedWhenClosed = false
            let h = NSHostingView(rootView: view)
            w.contentView = h
            w.center()
            w.setFrameAutosaveName("RehearsalReport")
            window = w
            host = h
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct RehearsalReportView: View {
    let report: RehearsalReport
    let history: [RehearsalReport]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.scriptTitle).font(.title.weight(.bold))
                    Text("\(report.date.formatted(date: .abbreviated, time: .shortened)) · "
                         + (report.finished ? "Read to the end" : "Stopped at \(Int(report.coverage * 100))%"))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    tile("Time", formatClock(Int(report.duration.rounded())), "clock")
                    tile("Pace", "\(Int(report.averageWPM.rounded())) wpm", "speedometer")
                    tile("Covered", "\(Int((report.coverage * 100).rounded()))%", "text.badge.checkmark")
                    tile("Pauses", report.pauses.isEmpty ? "None" : "\(report.pauses.count) · longest \(String(format: "%.1f", report.longestPause)) s", "pause.circle")
                    tile("Fillers", report.fillerCount == 0 ? "None" : "\(report.fillerCount)", "bubble.left.and.exclamationmark.bubble.right")
                }

                if !tips.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tips, id: \.self) { tip in
                            Label(tip, systemImage: "lightbulb").font(.callout)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.1)))
                }

                if report.pace.count >= 2 {
                    section("Pace through the script") {
                        Chart {
                            ForEach(Array(report.pace.enumerated()), id: \.offset) { _, p in
                                LineMark(x: .value("Time", p.t), y: .value("Words per minute", p.wpm))
                                    .interpolationMethod(.catmullRom)
                                PointMark(x: .value("Time", p.t), y: .value("Words per minute", p.wpm))
                                    .symbolSize(18)
                            }
                            RuleMark(y: .value("Average", report.averageWPM))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .foregroundStyle(.secondary)
                                .annotation(position: .top, alignment: .leading) {
                                    Text("average \(Int(report.averageWPM.rounded()))").font(.caption2).foregroundStyle(.secondary)
                                }
                        }
                        .chartXAxis { AxisMarks { v in
                            AxisGridLine()
                            AxisValueLabel { if let s = v.as(Double.self) { Text(formatClock(Int(s))) } }
                        } }
                        .chartYAxisLabel("wpm")
                        .frame(height: 170)
                    }
                }

                if !report.skipped.isEmpty {
                    section("Skipped") { list(report.skipped.map { "“\($0.excerpt)”" }) }
                }
                if !report.reread.isEmpty {
                    section("Read again") { list(report.reread.map { "“\($0.excerpt)”" }) }
                }
                if report.fillerCount > 0 {
                    section("Filler words") {
                        Text(report.fillers.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: " · "))
                    }
                }
                if report.pauses.contains(where: { $0.seconds >= 3 }) {
                    section("Long pauses") {
                        list(report.pauses.filter { $0.seconds >= 3 }.map {
                            "\(String(format: "%.1f", $0.seconds)) s at \(formatClock(Int($0.t)))"
                        })
                    }
                }

                if history.count > 1 {
                    section("Your rehearsals of this script") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                            GridRow {
                                Text("When").bold(); Text("Pace").bold(); Text("Covered").bold(); Text("Fillers").bold()
                            }
                            ForEach(Array(history.prefix(8).enumerated()), id: \.offset) { _, r in
                                GridRow {
                                    Text(r.date.formatted(date: .abbreviated, time: .shortened))
                                    Text("\(Int(r.averageWPM.rounded())) wpm")
                                    Text("\(Int((r.coverage * 100).rounded()))%")
                                    Text("\(r.fillerCount)")
                                }
                                .foregroundStyle(r.date == report.date ? .primary : .secondary)
                            }
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    /// A few plain suggestions, only when something stands out.
    private var tips: [String] {
        var t: [String] = []
        if report.averageWPM > 175 { t.append("You were fast (\(Int(report.averageWPM.rounded())) wpm). Around 140–160 is easier to follow.") }
        if report.averageWPM < 115 { t.append("A relaxed pace (\(Int(report.averageWPM.rounded())) wpm). A little faster may sound more confident.") }
        let spread = (report.pace.map(\.wpm).max() ?? 0) - (report.pace.map(\.wpm).min() ?? 0)
        if spread > 70 { t.append("Your pace swung by \(Int(spread)) wpm. Look for the rushed parts in the chart.") }
        let perMinute = report.speakingTime > 0 ? Double(report.fillerCount) / (report.speakingTime / 60) : 0
        if perMinute > 3 { t.append("About \(Int(perMinute.rounded())) filler words a minute. A short pause works better than “um”.") }
        if !report.skipped.isEmpty { t.append("You skipped \(report.skipped.count) part\(report.skipped.count == 1 ? "" : "s"). Intended, or worth another pass?") }
        return t
    }

    private func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func list(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items, id: \.self) { Text("• \($0)").fixedSize(horizontal: false, vertical: true) }
        }
    }
}
