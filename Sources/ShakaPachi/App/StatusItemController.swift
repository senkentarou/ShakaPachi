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

    // Whether the Settings window is open — drives the blue "info" icon state.
    private var settingsOpen = false

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

        // Show a blue "info" icon while the Settings window is open.
        NotificationCenter.default.addObserver(
            forName: .settingsWindowStateChanged, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.settingsOpen = (note.userInfo?["open"] as? Bool) ?? false
                self?.refreshIcon()
            }
        }
    }

    // MARK: - Public

    /// Refresh the permission badge on the status icon and menu item, reorder items, and
    /// enable/disable the toggle based on whether permissions are granted.
    func updatePermissionWarning() {
        let allGranted = permissionManager.allPermissionsGranted()

        // Fix #3: Gray out the toggle when permissions are missing so the user
        // cannot click something that has no effect. Re-enable when granted.
        toggleItem?.isEnabled = allGranted

        // The 「権限の状態…」 item is shown ONLY when a permission is missing,
        // pinned to the very top of the menu. When everything is granted it is
        // removed entirely (it is not useful in the normal state). Guard on
        // whether it is currently in the menu so repeated calls never duplicate
        // it or leave a stray separator.
        if let permItem = permissionStatusItem {
            let inMenu = menu.index(of: permItem) >= 0
            if !allGranted && !inMenu {
                menu.insertItem(permItem, at: 0)
                menu.insertItem(.separator(), at: 1)
            } else if allGranted && inMenu {
                let idx = menu.index(of: permItem)
                if idx + 1 < menu.numberOfItems,
                   menu.item(at: idx + 1)?.isSeparatorItem == true {
                    menu.removeItem(at: idx + 1)
                }
                menu.removeItem(permItem)
            }
        }

        refreshIcon()
    }

    /// Reflect the event-tap state on the toggle item and status icon (§10).
    func updateTapState(enabled: Bool, reason: String?) {
        tapEnabled = enabled
        tapStopReason = reason
        toggleItem?.state = enabled ? .on : .off
        refreshIcon()
    }

    // Icon precedence: permission problem > tap stopped > settings open > normal.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        if !permissionManager.allPermissionsGranted() {
            button.image = makeWarningIcon()
            button.toolTip = "ShakaPachi — 権限が不足しています"
        } else if !tapEnabled {
            button.image = makeStoppedIcon()
            button.toolTip = "ShakaPachi — 停止中" + (tapStopReason.map { " (\($0))" } ?? "")
        } else if settingsOpen {
            button.image = makeInfoIcon()
            button.toolTip = "ShakaPachi — 設定を開いています"
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

    /// Draws the 16×16 normal-state menu-bar icon: the ShakaPachi glyph as a
    /// template (white / adaptive). Warning and stopped states draw the SAME
    /// glyph tinted amber / red — state is shown by the glyph's colour, not by a
    /// separate badge.
    private func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            // Template: only alpha matters, so .black renders adaptively (white
            // on a dark menu bar). The front window is a solid "白掛け" fill.
            self.drawGlyph(in: bounds, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Private: icon helpers

    /// Draws the ShakaPachi glyph — two overlapping windows — in a single `color`:
    /// the back window as an outline and the front window as a SOLID fill (the
    /// "白掛け" front), so the whole glyph reads as one state colour
    /// (white = normal, amber = warning, red = stopped). Geometry mirrors the app
    /// icon (OnboardingWindow.makeAppIconTile): back lower-left, front upper-right.
    private func drawGlyph(in bounds: NSRect, color: NSColor) {
        let s = bounds.width / 16.0
        // Fill most of the canvas (menu-bar icons have no surrounding tile,
        // unlike the app icon, so the glyph itself must be large): ~1.25px margins
        // in the 16-unit design space, rendered into an 18px image.
        let w = 9.5 * s
        let r = 1.65 * s
        let line = 1.3 * s

        color.setStroke()
        color.setFill()

        // Back window frame (outline) — lower-left.
        let backRect = NSRect(x: bounds.minX + 1.25 * s, y: bounds.minY + 1.25 * s, width: w, height: w)
        let back = NSBezierPath(roundedRect: backRect, xRadius: r, yRadius: r)
        back.lineWidth = line
        back.stroke()

        // Front window — upper-right, solid fill occluding the back beneath it.
        let frontRect = NSRect(x: bounds.minX + 5.25 * s, y: bounds.minY + 5.25 * s, width: w, height: w)
        let front = NSBezierPath(roundedRect: frontRect, xRadius: r, yRadius: r)
        front.fill()
        front.lineWidth = line
        front.stroke()
    }

    /// Draws the 16×16 warning-state icon: the ShakaPachi glyph tinted amber.
    /// State is shown by the glyph colour (no separate badge). Non-template so
    /// the amber renders in colour rather than adapting to the menu bar.
    private func makeWarningIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            // Soft amber — paler than the raw product colour so it reads as a
            // gentle warning on the menu bar rather than a harsh block of colour.
            self.drawGlyph(in: bounds, color: NSColor(srgbRed: 0.95, green: 0.81, blue: 0.45, alpha: 1.0))
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Private: menu

    private func setupMenu() {
        // autoenablesItems = false so that explicit isEnabled assignments on menu items
        // are honored without being overridden by AppKit's automatic validation pass.
        // Required for Fix #3 (gray out toggle when permissions missing).
        menu.autoenablesItems = false

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

        // Permission status item — created but NOT added here. It is shown ONLY
        // when a permission is missing, pinned to the top of the menu by
        // updatePermissionWarning(); in the normal (granted) state it is absent.
        let permItem = NSMenuItem(
            title: "⚠ 権限の状態…",
            action: #selector(showPermissions),
            keyEquivalent: ""
        )
        permItem.target = self
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

    /// Draws the 16×16 stopped-state icon: the ShakaPachi glyph tinted red.
    /// State is shown by the glyph colour (no separate badge). Non-template.
    private func makeStoppedIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            // Soft coral — a muted, lighter red so the stopped state is clear
            // without being a harsh saturated red.
            self.drawGlyph(in: bounds, color: NSColor(srgbRed: 0.92, green: 0.53, blue: 0.51, alpha: 1.0))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws the 18×18 settings-open icon: the ShakaPachi glyph tinted blue,
    /// like an "info" indicator. Non-template so the blue renders in colour.
    private func makeInfoIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            // Soft blue — a paler "info" blue (lighter than systemBlue) for the
            // settings-open state, in keeping with the muted warning/stopped tints.
            self.drawGlyph(in: bounds, color: NSColor(srgbRed: 0.52, green: 0.68, blue: 0.92, alpha: 1.0))
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
