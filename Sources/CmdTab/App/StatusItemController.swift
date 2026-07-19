import AppKit

/// Manages the menu bar status item for CmdTab.
// Created and accessed exclusively from applicationDidFinishLaunching (@MainActor).
@MainActor
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let permissionManager: PermissionManager

    // Held references to menu items that need runtime updates.
    private var permissionStatusItem: NSMenuItem?
    private var toggleItem: NSMenuItem?

    // Tap state mirrored from HotkeyTap for icon/menu rendering.
    private var tapEnabled = false
    private var tapStopReason: String?

    /// Called when the user toggles 「ウィンドウ切替を有効化」.
    /// Receives the desired new state.
    var onToggleTap: ((Bool) -> Void)?

    // Retained while open: NSWindow.delegate is weak, so a local variable
    // would deallocate the controller and leave the activation policy stuck
    // at .regular when the window closes.
    private var onboardingWindow: OnboardingWindow?

    init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupButton()
        setupMenu()
        updatePermissionWarning()
    }

    // MARK: - Public

    /// Refresh the permission badge on the status icon and menu item.
    func updatePermissionWarning() {
        let allGranted = permissionManager.allPermissionsGranted()
        permissionStatusItem?.title = allGranted
            ? "権限の状態…"
            : "⚠ 権限の状態…"
        refreshIcon()
    }

    /// Reflect the event-tap state on the toggle item and status icon (§10).
    func updateTapState(enabled: Bool, reason: String?) {
        tapEnabled = enabled
        tapStopReason = reason
        toggleItem?.state = enabled ? .on : .off
        refreshIcon()
    }

    // Icon precedence: permission problem > tap stopped > normal.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        if !permissionManager.allPermissionsGranted() {
            button.image = makeWarningIcon()
            button.toolTip = "CmdTab — 権限が不足しています"
        } else if !tapEnabled {
            button.image = makeStoppedIcon()
            button.toolTip = "CmdTab — 停止中" + (tapStopReason.map { " (\($0))" } ?? "")
        } else {
            button.image = makeStatusIcon()
            button.toolTip = "CmdTab"
        }
        button.image?.isTemplate = true
    }

    // MARK: - Private: button

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = makeStatusIcon()
        button.image?.isTemplate = true
    }

    /// Draws a simple 16x16 template image representing two overlapping window frames.
    private func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setStroke()

        // Back window frame
        let back = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 11, height: 11), xRadius: 2, yRadius: 2)
        back.lineWidth = 1.5
        back.stroke()

        // Front window frame (offset to simulate overlap)
        let front = NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 11, height: 11), xRadius: 2, yRadius: 2)
        front.lineWidth = 1.5
        NSColor.white.setFill()
        front.fill()
        front.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Draws a 16x16 warning-variant icon (exclamation mark in triangle).
    private func makeWarningIcon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setStroke()
        NSColor.black.setFill()

        // Triangle outline
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: 8, y: 15))
        tri.line(to: NSPoint(x: 1, y: 2))
        tri.line(to: NSPoint(x: 15, y: 2))
        tri.close()
        tri.lineWidth = 1.5
        tri.stroke()

        // Exclamation body
        let rect = NSRect(x: 7, y: 5, width: 2, height: 6)
        NSBezierPath(rect: rect).fill()

        // Exclamation dot
        let dot = NSRect(x: 7, y: 2.5, width: 2, height: 2)
        NSBezierPath(ovalIn: dot).fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Private: menu

    private func setupMenu() {
        // Tap enable/disable toggle (§10) — also the recovery path after an
        // emergency stop or deadman fire without relaunching the app.
        let toggle = NSMenuItem(
            title: "ウィンドウ切替を有効化",
            action: #selector(toggleTap),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        menu.addItem(.separator())

        // "About CmdTab" item
        let aboutItem = NSMenuItem(
            title: "CmdTab について",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Permission status item — shows ⚠ when missing
        let permItem = NSMenuItem(
            title: "権限の状態…",
            action: #selector(showPermissions),
            keyEquivalent: ""
        )
        permItem.target = self
        menu.addItem(permItem)
        permissionStatusItem = permItem

        menu.addItem(.separator())

        // "Quit" item with Cmd+Q shortcut
        let quitItem = NSMenuItem(
            title: "終了",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Draws a 16x16 stopped-variant icon (square inside a circle outline).
    private func makeStoppedIcon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setStroke()
        NSColor.black.setFill()

        let circle = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14))
        circle.lineWidth = 1.5
        circle.stroke()

        NSBezierPath(rect: NSRect(x: 5.5, y: 5.5, width: 5, height: 5)).fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Menu actions

    @objc private func toggleTap() {
        onToggleTap?(!tapEnabled)
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showPermissions() {
        // Show the onboarding window regardless of current status so
        // the user can check or re-request permissions at any time.
        let ow = OnboardingWindow(permissionManager: permissionManager) { [weak self] in
            self?.updatePermissionWarning()
        }
        onboardingWindow = ow
        ow.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
