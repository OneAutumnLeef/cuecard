import AppKit
import PrompterCore
import QuartzCore
import SwiftUI

/// Hosts the SwiftUI prompter. Forwards trackpad scrolling, reports hover (even while another app is
/// active), and shows the app menu on right-click.
final class PrompterHostingView: NSHostingView<PrompterView> {
    var onScroll: ((CGFloat) -> Void)?
    var onHover: ((Bool) -> Void)?
    var menuProvider: (() -> NSMenu)?
    private var hoverArea: NSTrackingArea?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Owns the borderless panel that sits on the notch: positions it, keeps it above everything,
/// and applies the screen-share setting.
final class NotchPanelController {
    private let model: AppModel
    private var panel: NSPanel?
    private(set) var screen: NSScreen?
    private var screenObserver: NSObjectProtocol?
    /// Builds the right-click menu (set by the app delegate once the menu bar exists).
    var menuProvider: (() -> NSMenu)?
    private var moveObserver: NSObjectProtocol?
    private var applyingFrame = false

    init(model: AppModel) {
        self.model = model
        model.onShownChange = { [weak self] shown in shown ? self?.present() : self?.dismiss() }
        model.onLayoutChange = { [weak self] in self?.applyFrame() }
        model.onScreenPreferenceChange = { [weak self] in self?.refreshScreen() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreen() }
        }
        refreshScreen()
    }

    /// The chosen screen (Settings → Display), else the built-in display with a notch, else the main display
    /// (where the island hangs from the top centre like a notch).
    func refreshScreen() {
        let name = model.settings.screenName
        let s = (name.isEmpty ? nil : NSScreen.screens.first { $0.localizedName == name })
            ?? NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main ?? NSScreen.screens.first
        screen = s
        guard let s else { return }
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            model.setNotch(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        } else {
            let menuBar = s.frame.maxY - s.visibleFrame.maxY
            model.setNotch(width: 0, height: menuBar > 10 ? menuBar : 24)
        }
        applyFrame()
    }

    func applyFrame() {
        guard let panel, let screen else { return }
        let g = model.geometry
        let f = screen.frame
        var frame = NSRect(x: (f.midX - g.panelWidth / 2).rounded(), y: f.maxY - g.panelHeight,
                           width: g.panelWidth, height: g.panelHeight)
        if g.floating {
            // Where you left it (top-left corner), kept on screen; first time: centred under the menu bar.
            let vis = screen.visibleFrame
            let left = model.settings.floatingX ?? Double(vis.midX - g.panelWidth / 2)
            let top = model.settings.floatingY ?? Double(vis.maxY - 60)
            frame.origin.x = min(max(CGFloat(left), vis.minX), vis.maxX - g.panelWidth)
            frame.origin.y = min(max(CGFloat(top) - g.panelHeight, vis.minY), vis.maxY - g.panelHeight)
        }
        panel.isMovableByWindowBackground = g.floating
        applyingFrame = true
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        applyingFrame = false
        let sharing: NSWindow.SharingType = model.settings.hideFromScreenShare ? .none : .readOnly
        if panel.sharingType != sharing { panel.sharingType = sharing }
    }

    private func present() {
        if panel == nil { panel = makePanel() }
        refreshScreen()
        panel?.orderFrontRegardless()
    }

    private func dismiss() { panel?.orderOut(nil) }

    /// Remembers where you dragged the floating panel.
    private func panelMoved() {
        guard let panel, model.geometry.floating, !applyingFrame else { return }
        let left = Double(panel.frame.minX), top = Double(panel.frame.maxY)
        if model.settings.floatingX != left || model.settings.floatingY != top {
            model.settings.floatingX = left
            model.settings.floatingY = top
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        let host = PrompterHostingView(rootView: PrompterView(model: model))
        host.sizingOptions = []
        host.onScroll = { [weak self] dy in self?.model.scroll(by: dy) }
        host.onHover = { [weak self] inside in self?.model.setHovering(inside) }
        host.menuProvider = { [weak self] in self?.menuProvider?() ?? NSMenu() }
        p.contentView = host
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        }
        return p
    }
}

/// Drives playback from the display's refresh, and sleeps when nothing is playing.
final class Ticker: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private let onTick: (Double) -> Void

    init(onTick: @escaping (Double) -> Void) { self.onTick = onTick }

    func setRunning(_ running: Bool, screen: NSScreen?) {
        if running {
            if link == nil, let s = screen ?? NSScreen.main {
                let l = s.displayLink(target: self, selector: #selector(tick(_:)))
                l.add(to: .main, forMode: .common)
                link = l
            }
            last = nil
            link?.isPaused = false
        } else {
            link?.isPaused = true
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        defer { last = now }
        guard let last else { return }
        onTick(min(now - last, 0.1))
    }
}
