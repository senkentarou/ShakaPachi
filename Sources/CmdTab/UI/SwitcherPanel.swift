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

    // MARK: - Init

    init() {
        // §7.1: panel configuration.
        let initialRect = NSRect(x: 0, y: 0,
                                  width: SwitcherLayout.panelWidth,
                                  height: SwitcherLayout.panelHeight(itemCount: 1))

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

        // §7.1 content: HUD-style NSVisualEffectView with 12pt corner radius.
        let ev = NSVisualEffectView(frame: initialRect.insetBy(dx: 0, dy: 0))
        ev.material = .hudWindow
        ev.blendingMode = .behindWindow
        ev.state = .active
        ev.wantsLayer = true
        ev.layer?.cornerRadius = 12
        ev.layer?.masksToBounds = true

        // SwitcherListView fills the effect view with padding.
        let lv = SwitcherListView(frame: ev.bounds)
        lv.translatesAutoresizingMaskIntoConstraints = false
        ev.addSubview(lv)

        NSLayoutConstraint.activate([
            lv.leadingAnchor.constraint(equalTo: ev.leadingAnchor),
            lv.trailingAnchor.constraint(equalTo: ev.trailingAnchor),
            lv.topAnchor.constraint(equalTo: ev.topAnchor,
                                    constant: SwitcherLayout.verticalPadding),
            lv.bottomAnchor.constraint(equalTo: ev.bottomAnchor,
                                       constant: -SwitcherLayout.verticalPadding),
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
        let height = SwitcherLayout.panelHeight(itemCount: itemCount)
        let width  = SwitcherLayout.panelWidth

        // Find the screen containing the mouse cursor; fall back to main.
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
                     ?? NSScreen.main
                     ?? NSScreen.screens.first

        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0,
                                                          width: 1440, height: 900)
        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2

        let newFrame = NSRect(x: x, y: y, width: width, height: height)
        panel.setFrame(newFrame, display: false)

        // Resize the effect view to match.
        effectView.frame = NSRect(origin: .zero, size: newFrame.size)
        effectView.layer?.cornerRadius = 12
    }
}
