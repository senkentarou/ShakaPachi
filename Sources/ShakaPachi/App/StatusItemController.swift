import AppKit

/// Manages the menu bar status item for ShakaPachi.
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

    /// Called when the user chooses 「設定…」 from the menu.
    var onOpenSettings: (() -> Void)?

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
            button.toolTip = "ShakaPachi — 権限が不足しています"
        } else if !tapEnabled {
            button.image = makeStoppedIcon()
            button.toolTip = "ShakaPachi — 停止中" + (tapStopReason.map { " (\($0))" } ?? "")
        } else {
            button.image = makeStatusIcon()
            button.toolTip = "ShakaPachi"
            // Normal icon is template; badged icons set isTemplate = false in their builders.
            button.image?.isTemplate = true
        }
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

    // MARK: - Private: icon helpers

    /// Draws the overlapping-windows ShakaPachi glyph into the current graphics context.
    /// The glyph is anchored toward the top-left so the bottom-right corner is free for a badge.
    /// - Parameter bounds: the canvas rect passed by the drawingHandler (origin is flipped-aware).
    private func drawWindowGlyph(in bounds: NSRect) {
        // Scale the glyph to roughly 11/16 of the canvas, leaving the bottom-right open.
        let scale = bounds.width / 16.0

        // Back window frame — top-left anchor
        let backRect = NSRect(
            x: bounds.minX,
            y: bounds.minY + 5 * scale,
            width: 10 * scale,
            height: 10 * scale
        )
        let back = NSBezierPath(roundedRect: backRect, xRadius: 1.5 * scale, yRadius: 1.5 * scale)
        back.lineWidth = 1.5 * scale
        back.stroke()

        // Front window frame — offset to simulate overlap, clipped to keep bottom-right open
        let frontRect = NSRect(
            x: bounds.minX + 4 * scale,
            y: bounds.minY + 1 * scale,
            width: 10 * scale,
            height: 10 * scale
        )
        let front = NSBezierPath(roundedRect: frontRect, xRadius: 1.5 * scale, yRadius: 1.5 * scale)
        // Punch the region the front frame covers to transparent (.clear compositing)
        // so it occludes the back frame — matching makeStatusIcon's solid-front look —
        // then stroke the front outline.
        if let ctx = NSGraphicsContext.current {
            let previous = ctx.compositingOperation
            ctx.compositingOperation = .clear
            front.fill()
            ctx.compositingOperation = previous
        }
        front.lineWidth = 1.5 * scale
        front.stroke()
    }

    /// Draws a 16×16 warning icon: the ShakaPachi glyph with an amber triangle-exclamation badge
    /// in the bottom-right corner. Non-template so the amber badge color renders.
    private func makeWarningIcon() -> NSImage {
        let canvasSize = NSSize(width: 16, height: 16)
        let image = NSImage(size: canvasSize, flipped: false) { bounds in
            // Base glyph drawn with the appearance-adaptive label color so it follows light/dark.
            NSColor.labelColor.setStroke()
            self.drawWindowGlyph(in: bounds)

            // Warning badge: an amber triangle-exclamation in the bottom-right corner.
            let cx = bounds.maxX - 5.0
            let baseY = bounds.minY + 0.5
            let halfWidth: CGFloat = 4.8
            let triHeight: CGFloat = 8.5
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: cx, y: baseY + triHeight))     // apex (top)
            triangle.line(to: NSPoint(x: cx - halfWidth, y: baseY))     // base-left
            triangle.line(to: NSPoint(x: cx + halfWidth, y: baseY))     // base-right
            triangle.close()

            // Halo: a wide labelColor stroke behind the fill separates the badge
            // from the glyph lines (the amber fill covers the stroke's inner half).
            NSColor.labelColor.setStroke()
            triangle.lineWidth = 2.5
            triangle.lineJoinStyle = .round
            triangle.stroke()

            // Amber fill.
            NSColor(srgbRed: 1.0, green: 0.72, blue: 0.0, alpha: 1.0).setFill()
            triangle.fill()

            // Exclamation mark (dark, for contrast on amber).
            NSColor.black.setFill()
            let bodyRect = NSRect(x: cx - 0.8, y: baseY + 3.0, width: 1.6, height: 3.0)
            NSBezierPath(rect: bodyRect).fill()
            let dotRect = NSRect(x: cx - 0.8, y: baseY + 1.2, width: 1.6, height: 1.6)
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        image.isTemplate = false
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

        // §10 / §11.3: Settings… with Cmd+, shortcut
        let settingsItem = NSMenuItem(
            title: "設定…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

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

        // "About ShakaPachi" item
        let aboutItem = NSMenuItem(
            title: "ShakaPachi について",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

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

    /// Draws a 16×16 stopped icon: the ShakaPachi glyph with a red filled-circle-with-square badge
    /// in the bottom-right corner. Non-template so the red badge color renders.
    private func makeStoppedIcon() -> NSImage {
        let canvasSize = NSSize(width: 16, height: 16)
        let image = NSImage(size: canvasSize, flipped: false) { bounds in
            // Base glyph drawn with the appearance-adaptive label color so it follows light/dark.
            NSColor.labelColor.setStroke()
            self.drawWindowGlyph(in: bounds)

            // Badge: red background disc in the bottom-right corner.
            let badgeRadius: CGFloat = 4.5
            let badgeCenter = NSPoint(x: bounds.maxX - badgeRadius + 0.5, y: bounds.minY + badgeRadius - 0.5)
            let badgeRect = NSRect(
                x: badgeCenter.x - badgeRadius,
                y: badgeCenter.y - badgeRadius,
                width: badgeRadius * 2,
                height: badgeRadius * 2
            )

            // Halo: slightly larger disc in labelColor to separate badge from glyph lines.
            NSColor.labelColor.setFill()
            let haloPath = NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.0, dy: -1.0))
            haloPath.fill()

            // Red fill disc.
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            // Filled square stop-mark in the badge (white, for contrast on red).
            NSColor.white.setFill()
            let squareSide: CGFloat = 3.0
            let squareRect = NSRect(
                x: badgeCenter.x - squareSide / 2,
                y: badgeCenter.y - squareSide / 2,
                width: squareSide,
                height: squareSide
            )
            NSBezierPath(rect: squareRect).fill()

            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Menu actions

    @objc private func toggleTap() {
        onToggleTap?(!tapEnabled)
    }

    @objc private func openSettings() {
        onOpenSettings?()
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
