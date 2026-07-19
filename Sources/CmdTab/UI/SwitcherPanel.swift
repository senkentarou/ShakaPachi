// SwitcherPanel.swift
// §7.1–7.4: NSPanel-based switcher UI.
//
// Lifetime rule (§7.2): the panel is created ONCE at app startup and retained
// forever. show/hide use orderFrontRegardless / orderOut(nil). Never destroy
// or recreate the panel — doing so would cost hundreds of milliseconds and
// make N1 ≤ 50ms impossible.
//
// The panel is nonactivating (§7.1): it must NEVER steal focus from the app
// the user is switching away from, because AppDelegate reads "the previously
// active window" after the panel appears.

import AppKit

final class SwitcherPanel {

    // MARK: - Stored panel (created once, never destroyed)

    private let panel: NSPanel
    private let effectView: NSVisualEffectView
    private let listView: SwitcherListView
    private let sheenLayer = CAGradientLayer()

    /// Liquid-glass corner radius (user request: pronounced rounding).
    private static let cornerRadius: CGFloat = 24

    // MARK: - Init

    init() {
        // §7.1: panel configuration.
        let initialSize = SwitcherLayout.panelSize(itemCount: 1)
        let initialRect = NSRect(origin: .zero, size: initialSize)

        let p = NSPanel(
            contentRect: initialRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        // §7.1 content: NSVisualEffectView, liquid-glass styling.
        // .popover (not .hudWindow): the user chose the system-standard look
        // that follows the light/dark appearance over the always-dark HUD.
        let ev = NSVisualEffectView(frame: initialRect.insetBy(dx: 0, dy: 0))
        ev.material = .popover
        ev.blendingMode = .behindWindow
        ev.state = .active
        ev.wantsLayer = true
        // behindWindow blur is clipped by the window server, which ignores
        // layer.cornerRadius — the blur region itself must be shaped through
        // maskImage or the corners stay square.
        ev.maskImage = Self.roundedCornerMask(radius: Self.cornerRadius)
        ev.layer?.cornerRadius = Self.cornerRadius
        ev.layer?.masksToBounds = true
        // Glass rim: 1px light border reads as the edge of a liquid pane.
        ev.layer?.borderWidth = 1
        ev.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        // Top sheen gradient for the liquid-glass feel.
        let sheen = sheenLayer
        sheen.colors = [
            NSColor.white.withAlphaComponent(0.14).cgColor,
            NSColor.white.withAlphaComponent(0.04).cgColor,
            NSColor.clear.cgColor,
        ]
        sheen.locations = [0.0, 0.4, 0.75]
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)   // layer coords: y=1 is the top
        sheen.endPoint = CGPoint(x: 0.5, y: 0.0)
        sheen.cornerRadius = Self.cornerRadius
        sheen.masksToBounds = true
        sheen.frame = ev.bounds
        ev.layer?.addSublayer(sheen)

        // SwitcherListView fills the effect view; padding is drawn internally.
        let lv = SwitcherListView(frame: ev.bounds)
        lv.translatesAutoresizingMaskIntoConstraints = false
        ev.addSubview(lv)

        NSLayoutConstraint.activate([
            lv.leadingAnchor.constraint(equalTo: ev.leadingAnchor),
            lv.trailingAnchor.constraint(equalTo: ev.trailingAnchor),
            lv.topAnchor.constraint(equalTo: ev.topAnchor),
            lv.bottomAnchor.constraint(equalTo: ev.bottomAnchor),
        ])

        p.contentView = ev

        self.panel = p
        self.effectView = ev
        self.listView = lv
    }

    // MARK: - Public API

    var isVisible: Bool { panel.isVisible }

    /// The currently highlighted row index, forwarded from the list view.
    var currentSelectedIndex: Int { listView.selectedIndex }

    /// Show the panel with the given items, placing the initial selection at
    /// `selectedIndex`. Repositions to the screen containing the mouse cursor.
    func show(items: [SwitcherItem], selectedIndex: Int) {
        listView.setItems(items, selectedIndex: selectedIndex)
        repositionPanel(itemCount: items.count)
        panel.orderFrontRegardless()
    }

    /// Move the highlight to a different row without reloading the table (§7.5).
    func updateSelection(to newIndex: Int) {
        listView.moveSelection(to: newIndex)
    }

    /// Hide the panel without destroying it (§7.2).
    func hide() {
        panel.orderOut(nil)
    }

    /// Force a display pass so the N1/N2 end-timestamp is taken after the
    /// draw has actually happened, not just after the order call.
    func displayIfNeeded() {
        panel.contentView?.displayIfNeeded()
    }

    // MARK: - Layout (§7.4)

    private func repositionPanel(itemCount: Int) {
        let size = SwitcherLayout.panelSize(itemCount: itemCount)

        // Find the screen containing the mouse cursor; fall back to main.
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
                     ?? NSScreen.main
                     ?? NSScreen.screens.first

        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0,
                                                          width: 1440, height: 900)
        // Overflow strategy for very many windows (tile shrink / wrapping) is
        // a Step 8 concern; for now the width is simply capped to the screen.
        let width = min(size.width, screenFrame.width - 40)
        let height = size.height
        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2

        let newFrame = NSRect(x: x, y: y, width: width, height: height)
        panel.setFrame(newFrame, display: false)

        // Resize the effect view and its sheen without implicit animations.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectView.frame = NSRect(origin: .zero, size: newFrame.size)
        sheenLayer.frame = effectView.bounds
        CATransaction.commit()
    }

    // MARK: - Liquid-glass helpers

    /// Resizable rounded-rect mask that shapes the behind-window blur region.
    private static func roundedCornerMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius,
                                       bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
