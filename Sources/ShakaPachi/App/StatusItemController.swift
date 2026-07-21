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

    /// Called when the user toggles 「ウィンドウ切替を有効化」.
    /// Receives the desired new state.
    var onToggleTap: ((Bool) -> Void)?

    /// Called when the user chooses 「設定…」 from the menu.
    var onOpenSettings: (() -> Void)?

    /// Called when the user chooses 「設定を閉じる」 while the Settings window is open.
    var onCloseSettings: (() -> Void)?

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
                self?.refreshSettingsMenuItem()
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
        let state: TrayIconState
        let tooltip: String
        if !permissionManager.allPermissionsGranted() {
            state = .permission
            tooltip = "ShakaPachi — 権限が不足しています"
        } else if !tapEnabled {
            state = .restricted
            tooltip = "ShakaPachi — 停止中" + (tapStopReason.map { " (\($0))" } ?? "")
        } else if settingsOpen {
            state = .settings
            tooltip = "ShakaPachi — 設定を開いています"
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
        settingsMenuItem = settingsItem

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

    /// Reflect the Settings-window open state on the settings menu item: while
    /// open it reads 「設定を閉じる」 with a check, and selecting it closes the window.
    private func refreshSettingsMenuItem() {
        settingsMenuItem?.title = settingsOpen ? "設定を閉じる" : "設定…"
        settingsMenuItem?.state = settingsOpen ? .on : .off
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
