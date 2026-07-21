import AppKit

// NSApplicationDelegate callbacks are called on the main thread by the
// framework. We annotate each method with @MainActor explicitly so Swift 6
// strict concurrency can verify this without requiring the class-level
// annotation (which would make the init @MainActor and break top-level code).
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItemController: StatusItemController?
    private var permissionManager: PermissionManager?
    private var onboardingWindow: OnboardingWindow?
    private var hotkeyTap: HotkeyTap?

    // §6.2: state machine owns the switcher logic; wired in startTapIfPossible().
    private var switcherMachine: SwitcherStateMachine?

    // §7.2: panel created once at startup, retained forever.
    private var switcherPanel: SwitcherPanel?

    // Real window data source (§5) and pre-scaled icon cache (§8).
    private var windowStore: WindowStore?
    private var iconCache: IconCache?

    // §Step10: Activator created once at launch in applicationDidFinishLaunching
    // and retained for the lifetime of the app. Optional only to avoid calling
    // the @MainActor init from a non-isolated stored-property context (Swift 6).
    private var activator: Activator?

    // Canonical snapshot of WindowInfo taken at panel-show time (source of truth).
    // Deliverable 2: replace the icon-only lastSwitcherItems snapshot with the
    // full WindowInfo snapshot so confirmSelection can call Activator.activate(_:)
    // with the exact window, and nextSameAppIndex uses the SAME list (no re-enum).
    private var lastWindowInfos: [WindowInfo] = []
    // Derived from lastWindowInfos at show time; kept for the panel API.
    private var lastSwitcherItems: [SwitcherItem] = []

    // §Step12: Settings window controller — retained here because NSWindow.delegate
    // is weak; a local would dealloc and leave activation policy stuck at .regular.
    private var settingsWindow: SettingsWindow?

    // Settings change observer token (NotificationCenter).
    private var settingsObserver: (any NSObjectProtocol)?

    // Key for the first-run login-item flag: written once after the initial
    // SMAppService registration so a subsequent user toggle to OFF is not
    // overridden on relaunch.
    private static let didInitializeLoginItemKey = "didInitializeLoginItem"

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu-bar accessory: no Dock icon, no activation on launch.
        NSApp.setActivationPolicy(.accessory)

        // §Step10: create Activator on main actor (must be done here, not at
        // stored-property init time, because of @MainActor isolation).
        self.activator = Activator()

        // §7.2: create the panel once here; never destroy it.
        let panel = SwitcherPanel()
        self.switcherPanel = panel

        // Apply the saved theme immediately at launch.
        applyTheme(Settings.shared.theme)

        // Real data source + icon cache, created once and retained (§5, §8).
        let settings = Settings.shared
        self.windowStore = WindowStore(excludedBundleIDs: Set(settings.excludedBundleIDs))
        self.iconCache = IconCache()

        #if DEBUG
        // N5 timing measurement: run enumerate() 10 times and log min/median/max.
        // This requires the app to be launched as a signed .app bundle so that
        // screen recording TCC permission is active and kCGWindowName is populated.
        measureWindowStoreN5()
        #endif

        let pm = PermissionManager()
        self.permissionManager = pm

        let sc = StatusItemController(permissionManager: pm)
        self.statusItemController = sc

        // Menu toggle drives the tap lifecycle (also the recovery path after
        // an emergency stop or deadman fire).
        sc.onToggleTap = { [weak self] enable in
            guard let tap = self?.hotkeyTap else { return }
            if enable {
                tap.enable()
            } else {
                tap.disable(reason: NSLocalizedString("メニューから無効化", comment: "Tap disabled from menu"))
            }
        }

        // §12 Settings menu item: open the settings window with Cmd+,
        sc.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        // Close the Settings window from the menu when it is open (tray toggle).
        sc.onCloseSettings = { [weak self] in
            self?.settingsWindow?.close()
        }

        // §12 Live settings: observe all settings changes and apply immediately.
        // The observer closure is @Sendable, so it captures a Sendable weak box
        // rather than `self` (a non-Sendable @MainActor NSObject) directly. The
        // .main queue guarantees the body runs on the main thread.
        let selfBox = WeakDelegateBox(self)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                selfBox.value?.applySettingsChanges()
            }
        }

        // Observer for the onboarding window trigger from the permissions tab.
        NotificationCenter.default.addObserver(
            forName: .showOnboardingWindow, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                selfBox.value?.showOnboarding()
            }
        }

        // Check permissions and show onboarding if any are missing.
        if !pm.allPermissionsGranted() {
            let ow = OnboardingWindow(permissionManager: pm) { [weak self] in
                self?.statusItemController?.updatePermissionWarning()
                // Start the tap the moment both permissions turn granted.
                self?.startTapIfPossible()
            }
            self.onboardingWindow = ow
            ow.show()
            NSLog("[ShakaPachi] Permissions missing — showing onboarding. " +
                  "Accessibility: %@  ScreenRecording: %@",
                  pm.accessibilityStatus() == .granted ? "granted" : "denied",
                  pm.screenRecordingStatus() == .granted ? "granted" : "denied")
        } else {
            NSLog("[ShakaPachi] All permissions granted — normal startup.")
            startTapIfPossible()
        }

        // First-run login-at-launch registration: register with SMAppService once
        // so the default is ON. The flag prevents re-enabling after the user
        // turns it OFF manually. A failure is logged but never crashes the app.
        let loginItemKey = AppDelegate.didInitializeLoginItemKey
        if !UserDefaults.standard.bool(forKey: loginItemKey) {
            do {
                try LoginItemManager.setEnabled(true)
                NSLog("[ShakaPachi] First-run: login item registered.")
            } catch {
                NSLog("[ShakaPachi] First-run: login item registration failed: %@",
                      error.localizedDescription)
            }
            // Mark as initialized regardless of success so we don't retry every
            // launch (a failure likely means sandbox/location restrictions that
            // won't resolve on retry).
            UserDefaults.standard.set(true, forKey: loginItemKey)
            Settings.shared.launchAtLogin = LoginItemManager.isEnabled
        }

        #if DEBUG
        // DEBUG self-check (§7 completion gate): simulate one trigger to get an
        // N1 proxy without synthesising CGEvents. Do this after the tap is set
        // up so the code path is realistic, but use a synthetic t0 = now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let panel = self.switcherPanel else { return }
            let items = self.currentSwitcherItems()
            guard !items.isEmpty else {
                NSLog("[ShakaPachi] N1 self-check skipped: 0 windows")
                return
            }
            let syntheticT0 = CFAbsoluteTimeGetCurrent()
            panel.show(items: items, selectedIndex: self.initialSelection(count: items.count))
            panel.displayIfNeeded()
            let n1 = (CFAbsoluteTimeGetCurrent() - syntheticT0) * 1000.0
            NSLog("[ShakaPachi] N1: %.2fms (callback→display, %d windows) [DEBUG self-check]",
                  n1, items.count)
            if n1 > 50.0 {
                NSLog("[ShakaPachi] N1 GATE FAIL: %.2fms exceeds 50ms budget", n1)
            } else {
                NSLog("[ShakaPachi] N1 GATE PASS: %.2fms within 50ms budget", n1)
            }
            // Hide after 0.5s so the developer can see the panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.switcherPanel?.hide()
            }
        }
        #endif
    }

    @MainActor
    private func startTapIfPossible() {
        guard hotkeyTap == nil,
              permissionManager?.allPermissionsGranted() == true else { return }
        let tap = HotkeyTap()

        // Initialize the tap with the current settings values.
        let settings = Settings.shared
        tap.triggerModifierMask = settings.triggerModifier.eventFlagMask
        tap.triggerKeyCode      = settings.triggerKey.keyCode

        tap.onStateChange = { [weak self] state in
            switch state {
            case .active:
                self?.statusItemController?.updateTapState(enabled: true, reason: nil)
            case .stopped(let reason):
                self?.statusItemController?.updateTapState(enabled: false, reason: reason)
            }
        }

        // §6.2 / Step 9: route all switcher inputs through the state machine.
        // The machine is pure logic; we execute its returned action here.
        // §4.3: the callback runs on the main run loop, and onSwitcherInput
        // is called synchronously within the tap callback (no async hop needed
        // for the consume decision). Panel/UI work is cheap enough to do inline
        // because it only posts display requests — no blocking I/O.
        let machine = SwitcherStateMachine(sameAppResolver: { [weak self] currentIndex in
            // Resolve the next window index that belongs to the same app as
            // the currently selected window. This requires the WindowStore's
            // last-enumerated list, which AppDelegate caches during showPanel.
            self?.nextSameAppIndex(from: currentIndex)
        })
        self.switcherMachine = machine

        tap.onSwitcherInput = { [weak self] input, t0 in
            guard let self, let panel = self.switcherPanel else { return false }

            // Supply the current item count only when showing the panel
            // (MODIFIER_HELD + trigger transition). For all other inputs
            // the machine ignores itemCount, so 0 is a safe sentinel.
            // Read showDelayMs at trigger time so showPanel can use it.
            let showDelay: Int
            let itemCount: Int
            if case .trigger = input, !panel.isVisible {
                // "Show" transition: enumerate once and snapshot BOTH the full
                // WindowInfo list and the derived SwitcherItems.  The snapshot
                // is the source of truth for confirmSelection and sameAppResolver
                // throughout this switcher session, so they see a stable list
                // even if windows open/close between show and confirm (§15).
                // Read Settings values (fast stored properties — §4.3 safe).
                showDelay = Settings.shared.showDelayMs
                let infos = self.windowStore?.enumerate(
                    currentSpaceOnly: Settings.shared.currentSpaceOnly,
                    sortMode: Settings.shared.sortMode
                ) ?? []
                let icons = self.iconCache
                self.lastWindowInfos = infos
                self.lastSwitcherItems = infos.map { info in
                    SwitcherItem(
                        icon: icons?.icon(for: info.pid, bundleID: info.bundleID),
                        title: info.title
                    )
                }
                itemCount = infos.count
            } else {
                showDelay = 0  // Not a show transition; delay not used.
                itemCount = panel.itemCount
            }

            let (action, consumed) = machine.handle(input, itemCount: itemCount)

            switch action {
            case .none:
                break

            case .showPanel(let initialIndex):
                // §15 edge case: 0 windows — the machine already returned
                // .none in that case (itemCount == 0 guard inside machine),
                // but be defensive here too.
                let items = self.lastSwitcherItems
                guard !items.isEmpty else { break }
                // §11.2 showDelayMs: delay the actual show by the configured
                // number of milliseconds. Default 0 means no delay, so there
                // is no behavior change for users who haven't set this. The N1
                // measurement still reflects wall time from the tap entry (t0),
                // so a non-zero delay is visible in the log.
                let delayMs = showDelay
                if delayMs <= 0 {
                    panel.show(items: items, selectedIndex: initialIndex)
                    panel.displayIfNeeded()
                    let n1 = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                    NSLog("[ShakaPachi] N1: %.2fms (callback→display, %d windows)", n1, items.count)
                } else {
                    let capturedItems = items
                    let capturedIndex = initialIndex
                    let capturedT0 = t0
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                        guard let self, let panel = self.switcherPanel else { return }
                        panel.show(items: capturedItems, selectedIndex: capturedIndex)
                        panel.displayIfNeeded()
                        let n1 = (CFAbsoluteTimeGetCurrent() - capturedT0) * 1000.0
                        NSLog("[ShakaPachi] N1: %.2fms (callback→display incl %dms delay, %d windows)",
                              n1, delayMs, capturedItems.count)
                    }
                }

            case .moveSelection(let newIndex):
                let t2start = CFAbsoluteTimeGetCurrent()
                panel.updateSelection(to: newIndex)
                panel.displayIfNeeded()
                let n2 = (CFAbsoluteTimeGetCurrent() - t2start) * 1000.0
                NSLog("[ShakaPachi] N2 redraw: %.2fms", n2)

            case .confirmSelection(let index):
                // §15 edge case: guard against out-of-range index (window may
                // have closed during the switcher session between show and confirm).
                let infos = self.lastWindowInfos
                if infos.indices.contains(index) {
                    NSLog("[ShakaPachi] Confirm window index %d (pid %d, title: %@)",
                          index, infos[index].pid, infos[index].title)
                    self.activator?.activate(infos[index])
                    // §5.5: record this activation so the next enumerate() puts
                    // this window at index 0 and the previously-active window
                    // (the one we just came from) stays at index 1.  This makes
                    // "press once, release" reliably return to the previous window.
                    self.windowStore?.recordActivation(infos[index].windowID)
                    // Count confirmed switches only (not cancel or out-of-range).
                    StatsStore.shared.recordSwitch()
                    // When the Settings/onboarding window is open, ShakaPachi is a
                    // .regular foreground app and would otherwise stay in front of
                    // the window we just raised, so the selected window would not
                    // actually come forward. Yield active status so the target wins.
                    // In normal use ShakaPachi is .accessory and never active, so
                    // isActive is false and this is a no-op.
                    if NSApp.isActive {
                        NSApp.deactivate()
                    }
                } else {
                    // Out-of-range: log and do nothing more than hide; app
                    // activate already ran inside Activator.activate for the
                    // in-range case, so there is nothing safe to raise here.
                    NSLog("[ShakaPachi] Confirm index %d out of range (count %d) — hide only",
                          index, infos.count)
                }
                panel.hide()

            case .cancel:
                panel.hide()
            }

            return consumed
        }

        hotkeyTap = tap
        tap.enable()
    }

    /// Enumerate the current windows (§5) and map them to switcher items,
    /// resolving each app icon through the pre-scaled cache (§8).
    @MainActor
    private func currentSwitcherItems() -> [SwitcherItem] {
        guard let windowStore, let iconCache else { return [] }
        let settings = Settings.shared
        return windowStore.enumerate(
            currentSpaceOnly: settings.currentSpaceOnly,
            sortMode: settings.sortMode
        ).map { info in
            SwitcherItem(
                icon: iconCache.icon(for: info.pid, bundleID: info.bundleID),
                title: info.title
            )
        }
    }

    /// Initial selection index (§6.2): the previous window (index 1) when there
    /// are two or more, otherwise the only window (index 0).
    private func initialSelection(count: Int) -> Int {
        count >= 2 ? 1 : 0
    }

    /// Return the next index that belongs to the same app as `currentIndex`
    /// in the last-shown snapshot, or nil if there is no other window of
    /// the same app. Used by the state machine's sameAppResolver closure.
    ///
    /// Uses `lastWindowInfos` (the snapshot taken at show time) rather than
    /// re-enumerating WindowStore. This fixes the fragile bug where the live
    /// window list can shift between the show transition and the grave-key press,
    /// causing index mismatches on the snapshot the panel is still displaying.
    @MainActor
    private func nextSameAppIndex(from currentIndex: Int) -> Int? {
        let windows = lastWindowInfos
        guard windows.indices.contains(currentIndex) else { return nil }
        let currentPID = windows[currentIndex].pid
        // Search forward (wrapping) for the next window with the same PID.
        let count = windows.count
        for offset in 1..<count {
            let candidate = (currentIndex + offset) % count
            if windows[candidate].pid == currentPID {
                return candidate
            }
        }
        return nil
    }

    // MARK: - §12 Settings live-wire

    /// Apply all settings that take effect immediately when they change.
    /// Called via NotificationCenter whenever any Settings value is set.
    @MainActor
    private func applySettingsChanges() {
        let settings = Settings.shared

        // -- triggerModifier / triggerKey → HotkeyTap --
        // Update the stored plain values; the tap reads them inside the callback
        // without calling into Settings/AppKit (§4.3 safe).
        if let tap = hotkeyTap {
            tap.triggerModifierMask = settings.triggerModifier.eventFlagMask
            tap.triggerKeyCode      = settings.triggerKey.keyCode
        }

        // -- excludedBundleIDs → WindowStore (live update, MRU preserved) --
        windowStore?.excludedBundleIDs = Set(settings.excludedBundleIDs)

        // -- theme → NSApp.appearance --
        applyTheme(settings.theme)

        // currentSpaceOnly and sortMode are read at enumerate() call time (no
        // stored state to update here). showDelayMs is read at show time.
    }

    /// Apply the given theme to NSApp.appearance so the entire UI (including
    /// the switcher panel and settings window) reacts immediately.
    @MainActor
    private func applyTheme(_ theme: Theme) {
        NSApp.appearance = theme.nsAppearance
    }

    // MARK: - §12 Settings window

    /// Open the settings window (§11.3). Creates it if it doesn't exist yet.
    @MainActor
    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(onboardingWindow: onboardingWindow)
        }
        settingsWindow?.show()
    }

    /// Show the onboarding/permissions window. Called from the permissions tab
    /// in SettingsWindow and from the permission status menu item.
    @MainActor
    private func showOnboarding() {
        guard let pm = permissionManager else { return }
        if onboardingWindow == nil {
            let ow = OnboardingWindow(permissionManager: pm) { [weak self] in
                self?.statusItemController?.updatePermissionWarning()
                self?.startTapIfPossible()
            }
            onboardingWindow = ow
        }
        onboardingWindow?.show()
    }

    // MARK: - Prevent spurious quit

    // Prevent AppKit from quitting the process when all windows close.
    // As a menu-bar accessory the app has no main window, so this callback
    // would otherwise trigger immediately and exit the process.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // §4.6: tear the tap down so modifier keys are not left in a stuck
        // state after the process exits.
        hotkeyTap?.disable(reason: "app terminating")
    }

    /// Sendable weak wrapper so @Sendable NotificationCenter closures can hold a
    /// reference to the (non-Sendable, @MainActor) delegate without a capture
    /// warning. Access is always re-isolated to the main actor before use.
    private final class WeakDelegateBox: @unchecked Sendable {
        weak var value: AppDelegate?
        init(_ value: AppDelegate?) { self.value = value }
    }

    #if DEBUG
    // Measure WindowStore.enumerate() 10 times and log each result plus
    // min/median/max so the N5 gate (≤5ms) can be verified from the system log.
    @MainActor
    private func measureWindowStoreN5() {
        let store = WindowStore()
        let runs = 10
        var durations: [Double] = []
        var windowCount = 0
        for i in 1...runs {
            let start = Date()
            let windows = store.enumerate()
            let elapsed = Date().timeIntervalSince(start) * 1000.0
            durations.append(elapsed)
            windowCount = windows.count
            NSLog("[ShakaPachi] N5 run %d: %.2fms  windows=%d", i, elapsed, windows.count)
        }
        let sorted = durations.sorted()
        let minMs = sorted.first ?? 0
        let maxMs = sorted.last ?? 0
        let medianMs: Double = {
            let mid = sorted.count / 2
            if sorted.count % 2 == 0 {
                return (sorted[mid - 1] + sorted[mid]) / 2.0
            }
            return sorted[mid]
        }()
        NSLog("[ShakaPachi] N5 summary: min=%.2fms median=%.2fms max=%.2fms windows=%d",
              minMs, medianMs, maxMs, windowCount)
        if medianMs > 5.0 {
            NSLog("[ShakaPachi] N5 GATE FAIL: median %.2fms exceeds 5ms budget", medianMs)
        } else {
            NSLog("[ShakaPachi] N5 GATE PASS: median %.2fms within 5ms budget", medianMs)
        }
    }
    #endif
}
