// SwitcherStateMachine.swift
// Pure deterministic state machine for window-switcher input (§6.2).
// No AppKit or CoreGraphics dependency — fully unit-testable.
//
// Transition diagram (§6.2):
//   IDLE + modifierDown         → MODIFIER_HELD          (not consumed)
//   MODIFIER_HELD + trigger     → ACTIVE(index, count)   (consumed)
//   MODIFIER_HELD + modifierUp  → IDLE                   (not consumed)
//   ACTIVE + trigger            → advance index           (consumed)
//   ACTIVE + trigger(shift)     → retreat index           (consumed)
//   ACTIVE + arrowForward/Back  → advance/retreat index   (consumed)
//   ACTIVE + escape             → cancel → IDLE           (consumed)
//   ACTIVE + sameAppJump        → jump via resolver       (consumed)
//   ACTIVE + otherKey           → no-op, NOT consumed     (§6.3)
//   ACTIVE + modifierUp         → confirmSelection → IDLE (not consumed)

import Foundation

// MARK: - Switcher input events (abstract, AppKit-free)

/// Abstract input events delivered to SwitcherStateMachine.
/// HotkeyTap translates concrete CGEvent/keycode data into these.
enum SwitcherInput: Equatable {
    /// The trigger modifier key (Option in dev default) went down.
    case modifierDown
    /// The trigger modifier key was released.
    case modifierUp
    /// The trigger key (Tab) was pressed; shift indicates Shift+Tab.
    case trigger(shift: Bool)
    /// Arrow right or arrow down — advance forward one step.
    case arrowForward
    /// Arrow left or arrow up — retreat one step.
    case arrowBackward
    /// Escape key: cancel and hide the panel.
    case escape
    /// Grave accent (`): jump to the next window of the same app.
    case sameAppJump
    /// Any other key — must NOT be consumed (§6.3).
    case otherKey
}

// MARK: - Switcher actions (caller executes these)

/// Actions that the caller (AppDelegate) must execute in response to
/// a state-machine transition. Equatable so tests can assert on them.
enum SwitcherAction: Equatable {
    /// No action required (and may mean the event was not consumed).
    case none
    /// Show the panel with the given initial selection index.
    case showPanel(initialIndex: Int)
    /// Move the highlight to a new index without rebuilding the list.
    case moveSelection(to: Int)
    /// Confirm the selection (Step 10: Activator raises the window).
    case confirmSelection(index: Int)
    /// Cancel: hide the panel without activating anything.
    case cancel
}

// MARK: - State machine states

private enum State: Equatable {
    case idle
    case modifierHeld
    case active(index: Int, count: Int)
}

// MARK: - SwitcherStateMachine

/// Deterministic state machine for the window switcher (§6.2).
///
/// Usage:
/// ```swift
/// let machine = SwitcherStateMachine()
/// let (action, consumed) = machine.handle(.trigger(shift: false), itemCount: items.count)
/// ```
///
/// `itemCount` is only used when transitioning MODIFIER_HELD → ACTIVE (the
/// "show" transition). Pass 0 for all other inputs — it is ignored.
///
/// `sameAppResolver` is injected at construction time and is called (with
/// the current index) when a `sameAppJump` input arrives in the ACTIVE state.
/// It returns the next index for the same app, or nil if there is none.
/// Keeping the resolver injectable makes the machine fully unit-testable.
final class SwitcherStateMachine {

    // MARK: - Init

    /// - Parameter sameAppResolver: Called with the current index; returns the
    ///   next same-app index or nil when no other window of the same app exists.
    init(sameAppResolver: ((Int) -> Int?)? = nil) {
        self.sameAppResolver = sameAppResolver
    }

    // MARK: - State

    private var state: State = .idle

    /// Resolver for `sameAppJump` input. Injected so tests can control it.
    var sameAppResolver: ((Int) -> Int?)?

    // MARK: - Public API

    /// Process one input event.
    ///
    /// - Parameters:
    ///   - input: The abstract switcher event.
    ///   - itemCount: Number of items available. Only meaningful on the
    ///     `trigger` input that causes MODIFIER_HELD → ACTIVE. Pass 0 otherwise.
    /// - Returns: The action the caller should execute, and whether the
    ///   underlying key event should be consumed (returned nil to the system).
    @discardableResult
    func handle(_ input: SwitcherInput, itemCount: Int = 0) -> (action: SwitcherAction, consumed: Bool) {
        switch state {

        // ── IDLE ──────────────────────────────────────────────────────────
        case .idle:
            switch input {
            case .modifierDown:
                state = .modifierHeld
                // The modifier key itself is never consumed (§6.2).
                return (.none, false)
            default:
                // All other inputs in IDLE are irrelevant; pass through.
                return (.none, false)
            }

        // ── MODIFIER_HELD ─────────────────────────────────────────────────
        case .modifierHeld:
            switch input {
            case .trigger(let shift):
                // Build the list and show the panel.
                // §6.2: initial index = 1 when count ≥ 2, else 0.
                let count = itemCount
                guard count > 0 else {
                    // No windows — stay in MODIFIER_HELD, consume the key.
                    return (.none, true)
                }
                let initialIndex = count >= 2 ? 1 : 0
                // Shift has no effect on the initial show transition, but
                // we honour it for future extensibility (same as forward).
                // The spec diagram shows trigger → index=1 with no shift branch here.
                _ = shift
                state = .active(index: initialIndex, count: count)
                return (.showPanel(initialIndex: initialIndex), true)

            case .modifierUp:
                state = .idle
                // Releasing the modifier is not consumed.
                return (.none, false)

            default:
                // Any other key in MODIFIER_HELD passes through.
                return (.none, false)
            }

        // ── ACTIVE ────────────────────────────────────────────────────────
        case .active(let index, let count):
            switch input {
            case .trigger(let shift):
                let newIndex: Int
                if shift {
                    // Shift+Tab: go backward (§6.2).
                    newIndex = (index - 1 + count) % count
                } else {
                    // Tab: go forward.
                    newIndex = (index + 1) % count
                }
                state = .active(index: newIndex, count: count)
                return (.moveSelection(to: newIndex), true)

            case .arrowForward:
                // → / ↓: advance (§6.2).
                let newIndex = (index + 1) % count
                state = .active(index: newIndex, count: count)
                return (.moveSelection(to: newIndex), true)

            case .arrowBackward:
                // ← / ↑: retreat (§6.2).
                let newIndex = (index - 1 + count) % count
                state = .active(index: newIndex, count: count)
                return (.moveSelection(to: newIndex), true)

            case .escape:
                state = .idle
                return (.cancel, true)

            case .sameAppJump:
                // Ask the resolver for the next same-app index.
                // If nil (no other window of the same app), stay put.
                // Either way the key is consumed (it's a defined transition).
                let newIndex = sameAppResolver?(index) ?? index
                state = .active(index: newIndex, count: count)
                return (.moveSelection(to: newIndex), true)

            case .otherKey:
                // §6.3: undefined keys are NOT consumed, action is none.
                return (.none, false)

            case .modifierUp:
                // Modifier release: confirm selection, hide panel, → IDLE.
                // Releasing the modifier is not consumed (§6.2).
                state = .idle
                return (.confirmSelection(index: index), false)

            case .modifierDown:
                // Modifier down while active is unexpected; ignore, pass through.
                return (.none, false)
            }
        }
    }

    /// Reset to idle (e.g. when the tap is disabled externally).
    func reset() {
        state = .idle
    }

    /// Read-only current state description for debugging.
    var isIdle: Bool { state == .idle }
    var isModifierHeld: Bool { state == .modifierHeld }
    var isActive: Bool {
        if case .active = state { return true }
        return false
    }
    /// The current selection index when active, or nil otherwise.
    var activeIndex: Int? {
        if case .active(let idx, _) = state { return idx }
        return nil
    }
}
