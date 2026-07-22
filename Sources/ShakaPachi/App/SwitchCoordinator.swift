import AppKit

// SwitchCoordinator.swift
// Orchestrates a single window-switch cycle from the hotkey trigger to the
// final window activation. This is the runtime "director" that sits between
// the low-level input tap and the higher-level pieces (state machine, panel,
// window store, activator).
//
// ── The switch cycle at a glance ──────────────────────────────────────────
//
//   modifierDown → [armed] → trigger → [panel: idx1] → trigger* → [move]
//                → modifierUp → confirm   (esc → cancel)
//
//   1. Trigger      The user holds the modifier and taps the trigger key.
//                   We enumerate the on-screen windows ONCE and take a
//                   snapshot, then show the panel with an initial selection.
//   2. Move         Further trigger / arrow / same-app-jump presses move the
//                   highlight left/right within that snapshot. No re-enumerate.
//   3. Confirm      Releasing the modifier confirms the highlighted window:
//                   activate it, record the activation (for MRU ordering),
//                   count the switch, and hide the panel.
//   3'. Cancel      Pressing Escape hides the panel without activating anything.
//
// ── Why we snapshot ────────────────────────────────────────────────────────
//
// The window list can change (windows open/close) between the moment the panel
// appears and the moment the user confirms. If we re-enumerated on every key
// press, indices could shift under the panel the user is still looking at.
// Instead we enumerate exactly once at show time and keep two derived lists as
// the single source of truth for the rest of the cycle:
//   - lastWindowInfos:   full WindowInfo, used by confirm (to activate the exact
//                        window) and by the same-app resolver.
//   - lastSwitcherItems: the display rows the panel renders.
// Both describe the SAME windows in the SAME order, so the highlighted index is
// always valid against both.
//
// ── Why the tap callback must return fast ──────────────────────────────────
//
// handleInput is invoked synchronously from inside the event-tap callback,
// which runs on the main run loop and must return within a very tight budget
// (no blocking work, no unbounded loops). Everything here is either a cheap
// pure state-machine call or a panel display request that only posts a redraw
// — no blocking I/O. The one exception, an optional user-configured show delay,
// is dispatched asynchronously so the callback still returns immediately. The
// boolean return value tells the tap whether to consume the key event (swallow
// it) or let it pass through to the front app.

@MainActor
final class SwitchCoordinator {

    // MARK: - Dependencies (injected, not owned)

    // These collaborators are created and owned by AppDelegate; the coordinator
    // only holds references to drive them during a switch cycle.
    private let windowStore: WindowStore
    private let iconCache: IconCache
    private let switcherPanel: SwitcherPanel
    private let activator: Activator
    private weak var permissionManager: PermissionManager?

    // MARK: - Cycle state

    // The state machine owns the pure switcher logic (idle → held → active).
    // It is created here so the coordinator can wire its sameAppResolver to
    // this instance's snapshot-based lookup.
    private let machine: SwitcherStateMachine

    // Canonical snapshot of WindowInfo taken at panel-show time (source of truth).
    // Confirm uses it to activate the exact window; the same-app resolver uses
    // the SAME list so both agree on indices (no re-enumeration mid-cycle).
    private var lastWindowInfos: [WindowInfo] = []
    // Derived from lastWindowInfos at show time; kept for the panel API.
    private var lastSwitcherItems: [SwitcherItem] = []

    // MARK: - Init

    /// - Parameters:
    ///   - windowStore: Real window data source (enumerate + MRU recording).
    ///   - iconCache: Pre-scaled app-icon cache for building switcher rows.
    ///   - switcherPanel: The persistent panel shown/hidden during a cycle.
    ///   - activator: Raises the confirmed window via the Accessibility API.
    ///   - permissionManager: Consulted to gate the live window preview on
    ///     screen-recording permission. Held weakly (owned by AppDelegate).
    init(
        windowStore: WindowStore,
        iconCache: IconCache,
        switcherPanel: SwitcherPanel,
        activator: Activator,
        permissionManager: PermissionManager?
    ) {
        self.windowStore = windowStore
        self.iconCache = iconCache
        self.switcherPanel = switcherPanel
        self.activator = activator
        self.permissionManager = permissionManager
        self.machine = SwitcherStateMachine()

        // The resolver needs the show-time snapshot, which lives on this
        // instance, so it is wired only after all stored properties (and thus
        // `self`) are fully initialized. [weak self] avoids a retain cycle
        // (the machine is owned by self).
        self.machine.sameAppResolver = { [weak self] currentIndex in
            self?.nextSameAppIndex(from: currentIndex)
        }
    }

    // MARK: - Hot path: one input event per switch cycle

    /// Handle one abstract switcher input and return whether the underlying key
    /// event should be consumed (true) or passed through to the front app (false).
    ///
    /// Called synchronously from the event-tap callback on the main run loop, so
    /// it must return quickly — see the file header for why. `t0` is the tap-entry
    /// timestamp, used to measure the callback→display latency (N1) on the first
    /// trigger of a cycle.
    func handleInput(_ input: SwitcherInput, t0: CFAbsoluteTime) -> Bool {
        let panel = switcherPanel

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
            // even if windows open/close between show and confirm.
            // Read Settings values (fast stored properties — hot-path safe).
            showDelay = Settings.shared.showDelayMs
            let infos =
                self.windowStore.enumerate(
                    currentSpaceOnly: Settings.shared.currentSpaceOnly,
                    sortMode: Settings.shared.sortMode
                )
            let icons = self.iconCache
            self.lastWindowInfos = infos
            self.lastSwitcherItems = infos.map { info in
                SwitcherItem(
                    icon: icons.icon(for: info.pid, bundleID: info.bundleID),
                    title: info.title,
                    windowID: info.windowID
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
            // Edge case: 0 windows — the machine already returned .none in that
            // case (itemCount == 0 guard inside the machine), but be defensive.
            let items = self.lastSwitcherItems
            guard !items.isEmpty else { break }
            // Gate the preview on the user's setting AND screen-recording
            // permission. Both are fast stored-property / system-call reads.
            let previewEnabled =
                Settings.shared.showWindowPreview
                && (self.permissionManager?.screenRecordingStatus() == .granted)
            // showDelayMs: delay the actual show by the configured number of
            // milliseconds. Default 0 means no delay, so there is no behavior
            // change for users who haven't set this. The N1 measurement still
            // reflects wall time from the tap entry (t0), so a non-zero delay
            // is visible in the log.
            let delayMs = showDelay
            if delayMs <= 0 {
                panel.show(
                    items: items, selectedIndex: initialIndex,
                    previewEnabled: previewEnabled)
                panel.displayIfNeeded()
                let n1 = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                NSLog("[ShakaPachi] N1: %.2fms (callback→display, %d windows)", n1, items.count)
            } else {
                let capturedItems = items
                let capturedIndex = initialIndex
                let capturedT0 = t0
                let capturedPreview = previewEnabled
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                    guard let self else { return }
                    let panel = self.switcherPanel
                    panel.show(
                        items: capturedItems, selectedIndex: capturedIndex,
                        previewEnabled: capturedPreview)
                    panel.displayIfNeeded()
                    let n1 = (CFAbsoluteTimeGetCurrent() - capturedT0) * 1000.0
                    NSLog(
                        "[ShakaPachi] N1: %.2fms (callback→display incl %dms delay, %d windows)",
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
            // Edge case: guard against out-of-range index (a window may have
            // closed during the switcher session between show and confirm).
            let infos = self.lastWindowInfos
            if infos.indices.contains(index) {
                NSLog(
                    "[ShakaPachi] Confirm window index %d (pid %d, title: %@)",
                    index, infos[index].pid, infos[index].title)
                self.activator.activate(infos[index])
                // Record this activation so the next enumerate() puts this
                // window at index 0 and the previously-active window (the one
                // we just came from) stays at index 1. This makes "press once,
                // release" reliably return to the previous window.
                self.windowStore.recordActivation(infos[index].windowID)
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
                NSLog(
                    "[ShakaPachi] Confirm index %d out of range (count %d) — hide only",
                    index, infos.count)
            }
            panel.hide()

        case .cancel:
            panel.hide()
        }

        return consumed
    }

    // MARK: - Helpers

    /// Return the next index that belongs to the same app as `currentIndex`
    /// in the last-shown snapshot, or nil if there is no other window of
    /// the same app. Used by the state machine's sameAppResolver closure.
    ///
    /// Uses `lastWindowInfos` (the snapshot taken at show time) rather than
    /// re-enumerating WindowStore. This fixes the fragile bug where the live
    /// window list can shift between the show transition and the grave-key press,
    /// causing index mismatches on the snapshot the panel is still displaying.
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
}
