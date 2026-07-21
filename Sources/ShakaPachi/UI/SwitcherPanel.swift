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
    // Accent background tint: a CALayer behind the tiles at α≈0.08.
    // Inserted below sheenLayer so it sits behind all tile content.
    // Set once per show(); never participates in the selection-move partial redraw.
    private let tintLayer = CALayer()

    // Window preview cache: owned here, injected into listView once in init().
    // Not cleared on hide() so cached images survive between panel sessions;
    // the selected window is force-refreshed on each show(), keeping it current.
    // Initialized in init() (not at the property declaration) because
    // WindowPreviewCache is @MainActor and stored-property initializers run in
    // a nonisolated context in Swift 6 strict concurrency.
    private let previewCache: WindowPreviewCache

    /// Liquid-glass corner radius (user request: pronounced rounding).
    private static let cornerRadius: CGFloat = 24

    // MARK: - Init

    @MainActor
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
        ev.layer?.borderColor = NSColor.white.withAlphaComponent(AccentColor.glassBorderAlpha).cgColor

        // Accent background tint: inserted first so it sits BELOW the sheen and
        // the listView. backgroundColor is set per-show from Settings.accentColor.
        let tint = tintLayer
        tint.cornerRadius = Self.cornerRadius
        tint.masksToBounds = true
        tint.frame = ev.bounds
        // backgroundColor is left nil here; show() sets it before orderFront.
        ev.layer?.addSublayer(tint)

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

        let cache = WindowPreviewCache()

        self.panel = p
        self.effectView = ev
        self.listView = lv
        self.previewCache = cache

        // Wire the preview cache to the list view.
        // Weak reference from listView avoids a retain cycle (panel owns cache).
        lv.previewCache = cache
        cache.onImageReady = { [weak lv] id in
            lv?.previewDidArrive(for: id)
        }
    }

    /// Inset kept between the panel and each screen edge.
    private static let screenEdgeInset: CGFloat = 20

    // MARK: - Public API

    var isVisible: Bool { panel.isVisible }

    /// The currently highlighted row index, forwarded from the list view.
    var currentSelectedIndex: Int { listView.selectedIndex }

    /// Number of items in the currently shown snapshot.
    var itemCount: Int { listView.count }

    /// Show the panel with the given items, placing the initial selection at
    /// `selectedIndex`. Repositions to the screen containing the mouse cursor,
    /// shrinking the tiles when the natural width would overflow that screen.
    ///
    /// - Parameter previewEnabled: When true (and screen-recording permission is
    ///   granted by the caller), a live window preview is drawn below the title.
    ///   Defaults to false so existing call sites without the parameter still work.
    @MainActor
    func show(items: [SwitcherItem], selectedIndex: Int, previewEnabled: Bool = false) {
        // Read accent color once per show — runs once per trigger, not on the
        // hot selection-move path, so calling into Settings here is fine.
        let accent = Settings.shared.accentColor.nsColor
        tintLayer.backgroundColor = accent.withAlphaComponent(AccentColor.backgroundTintAlpha).cgColor
        listView.accentColor = accent

        // Set previewEnabled BEFORE setItems so the first requestPreviews() call
        // inside setItems already sees the correct flag.
        listView.previewEnabled = previewEnabled

        let screenFrame = targetScreenFrame()
        let availableWidth = screenFrame.width - Self.screenEdgeInset * 2
        listView.setItems(items, selectedIndex: selectedIndex, availableWidth: availableWidth)

        let effectiveTile = SwitcherLayout.effectiveTileSize(
            itemCount: items.count, availableWidth: availableWidth)
        repositionPanel(itemCount: items.count,
                        effectiveTile: effectiveTile,
                        screenFrame: screenFrame,
                        previewEnabled: previewEnabled)
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

    /// The visibleFrame of the screen containing the mouse cursor (§7.4),
    /// falling back to the main screen and finally a sane default.
    private func targetScreenFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
                     ?? NSScreen.main
                     ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func repositionPanel(itemCount: Int,
                                 effectiveTile: CGFloat,
                                 screenFrame: NSRect,
                                 previewEnabled: Bool = false) {
        let size = SwitcherLayout.panelSize(itemCount: itemCount,
                                            effectiveTile: effectiveTile,
                                            previewEnabled: previewEnabled)
        // Tiles are shrunk to fit; if the count is so large they hit the 40pt
        // floor, the panel is still capped to the screen and the overflow
        // clips at the panel edge (acceptable, rare — §16 edge case).
        let width = min(size.width, screenFrame.width - Self.screenEdgeInset * 2)
        let height = size.height
        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2

        let newFrame = NSRect(x: x, y: y, width: width, height: height)
        panel.setFrame(newFrame, display: false)

        // Resize the effect view and its layers without implicit animations.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectView.frame = NSRect(origin: .zero, size: newFrame.size)
        tintLayer.frame = effectView.bounds
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
