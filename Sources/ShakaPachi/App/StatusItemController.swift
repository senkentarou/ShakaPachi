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
    private var settingsMenuItem: NSMenuItem?

    // Tap state mirrored from HotkeyTap for icon/menu rendering.
    private var tapEnabled = false
    private var tapStopReason: String?

    // Whether the Settings window is open — drives the blue "info" icon state.
    private var settingsOpen = false

    // Retained observer token for the settingsWindowStateChanged subscription.
    private var settingsWindowObserver: (any NSObjectProtocol)?

    /// Called when the user toggles "Enable window switching" (「ウィンドウ切替を有効化」).
    /// Receives the desired new state.
    var onToggleTap: ((Bool) -> Void)?

    /// Called when the user chooses "Settings…" (「設定…」) from the menu.
    var onOpenSettings: (() -> Void)?

    /// Called when the user chooses "Close settings" (「設定を閉じる」) while the Settings window is open.
    var onCloseSettings: (() -> Void)?

    init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupButton()
        setupMenu()
        updatePermissionWarning()

        // Show a blue "info" icon while the Settings window is open.
        settingsWindowObserver = NotificationCenter.default.addObserver(
            forName: .settingsWindowStateChanged, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.settingsOpen = (note.userInfo?["open"] as? Bool) ?? false
                self?.refreshSettingsMenuItem()
                self?.refreshIcon()
            }
        }
    }

    deinit {
        if let token = settingsWindowObserver {
            NotificationCenter.default.removeObserver(token)
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

        // The "Permission status…" (「権限の状態…」) item is shown ONLY when a permission is missing,
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
                    menu.item(at: idx + 1)?.isSeparatorItem == true
                {
                    menu.removeItem(at: idx + 1)
                }
                menu.removeItem(permItem)
            }
        }

        refreshToggleItem()
        refreshIcon()
    }

    /// Reflect the event-tap state on the toggle item and status icon.
    func updateTapState(enabled: Bool, reason: String?) {
        tapEnabled = enabled
        tapStopReason = reason
        refreshToggleItem()
        refreshIcon()
    }

    // Icon precedence: permission problem > tap stopped > settings open > normal.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let state: TrayIconState
        let tooltip: String
        if !permissionManager.allPermissionsGranted() {
            state = .permission
            tooltip = NSLocalizedString("ShakaPachi — 権限が不足しています", comment: "Tooltip: missing permissions")
        } else if !tapEnabled {
            state = .restricted
            tooltip =
                NSLocalizedString("ShakaPachi — 停止中", comment: "Tooltip: tap is paused")
                + (tapStopReason.map { " (\($0))" } ?? "")
        } else if settingsOpen {
            state = .settings
            tooltip = NSLocalizedString("ShakaPachi — 設定を開いています", comment: "Tooltip: settings window is open")
        } else {
            state = .normal
            tooltip = "ShakaPachi"
        }
        button.image = TrayIconRenderer.menuBarImage(for: state)
        button.toolTip = tooltip
    }

    // MARK: - Private: button

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = TrayIconRenderer.menuBarImage(for: .normal)
    }

    // MARK: - Private: menu

    private func setupMenu() {
        // autoenablesItems = false so that explicit isEnabled assignments on menu items
        // are honored without being overridden by AppKit's automatic validation pass.
        // Required for Fix #3 (gray out toggle when permissions missing).
        menu.autoenablesItems = false

        // Tap enable/disable toggle — also the recovery path after an
        // emergency stop or deadman fire without relaunching the app.
        let toggle = NSMenuItem(
            title: NSLocalizedString("ウィンドウ切替を有効化", comment: "Menu item: enable window switching"),
            action: #selector(toggleTap),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        menu.addItem(.separator())

        // Settings… with Cmd+, shortcut
        let settingsItem = NSMenuItem(
            title: NSLocalizedString("設定…", comment: "Menu item: open settings"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)
        settingsMenuItem = settingsItem

        // Permission status item — created but NOT added here. It is shown ONLY
        // when a permission is missing, pinned to the top of the menu by
        // updatePermissionWarning(); in the normal (granted) state it is absent.
        let permItem = NSMenuItem(
            title: NSLocalizedString("⚠ 権限の状態…", comment: "Menu item: permission status warning"),
            action: #selector(showPermissions),
            keyEquivalent: ""
        )
        permItem.target = self
        permissionStatusItem = permItem

        menu.addItem(.separator())

        // "Quit" item with Cmd+Q shortcut
        let quitItem = NSMenuItem(
            title: NSLocalizedString("終了", comment: "Menu item: quit"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Reflect the Settings-window open state on the settings menu item: while
    /// open it reads "Close settings" (「設定を閉じる」), and selecting it closes the window.
    /// The verb title conveys the state, so no check mark is used — a check next to
    /// an action verb ("Close settings ✓") reads as if the action were already applied.
    private func refreshSettingsMenuItem() {
        settingsMenuItem?.title =
            settingsOpen
            ? NSLocalizedString("設定を閉じる", comment: "Menu item: close settings")
            : NSLocalizedString("設定…", comment: "Menu item: open settings")
        settingsMenuItem?.state = .off
    }

    /// Update the tap-toggle menu item title based on tap-enable state and permissions.
    /// The title names the action a click performs (mirroring refreshSettingsMenuItem):
    /// - If tap is enabled: "Disable window switching"
    /// - If tap is disabled and all permissions granted: "⚠ Enable window switching" (warning marker)
    /// - If permissions missing: "Enable window switching" (no marker; permissions item owns the warning)
    /// No check mark is used: the verb title already conveys state, so a check next to
    /// "Disable window switching" would misread as the disabled action being active.
    private func refreshToggleItem() {
        let allGranted = permissionManager.allPermissionsGranted()
        if tapEnabled {
            toggleItem?.title = NSLocalizedString(
                "ウィンドウ切替を一時的に無効化", comment: "Menu item: temporarily disable window switching")
        } else if allGranted {
            toggleItem?.title = NSLocalizedString(
                "⚠ ウィンドウ切替を有効化", comment: "Menu item: enable window switching (needs attention)")
        } else {
            toggleItem?.title = NSLocalizedString("ウィンドウ切替を有効化", comment: "Menu item: enable window switching")
        }
        toggleItem?.state = .off
    }

    // MARK: - Menu actions

    @objc private func toggleTap() {
        onToggleTap?(!tapEnabled)
    }

    @objc private func openSettings() {
        if settingsOpen {
            onCloseSettings?()
        } else {
            onOpenSettings?()
        }
    }

    @objc private func showPermissions() {
        // Delegate to AppDelegate via notification so the single construction
        // point (AppDelegate.showOnboarding) is used. This also ensures that
        // startTapIfPossible is called when permissions are granted via this path.
        NotificationCenter.default.post(name: .showOnboardingWindow, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
