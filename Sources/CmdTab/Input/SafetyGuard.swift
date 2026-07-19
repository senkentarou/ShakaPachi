// SafetyGuard.swift
// Pure logic for §4 safety mechanisms — no AppKit dependency, fully testable.

import Foundation

// MARK: - Abstract key event (AppKit-free representation)

/// Abstracted key event passed to SafetyGuard.evaluate().
/// This mirrors CGEventType / CGKeyCode but carries no AppKit/CoreGraphics types
/// so unit tests can construct instances without a display connection.
public struct KeyEvent: Sendable {
    public enum EventType: Sendable {
        case keyDown
        case keyUp
        case flagsChanged
        case tapDisabledByTimeout
        case tapDisabledByUserInput
        case other
    }

    /// CGKeyCode value (e.g. 53 = Escape).
    public let keyCode: UInt16
    /// Modifier flags as a raw bitmask matching CGEventFlags.
    /// Use the SafetyGuard.Modifiers constants below.
    public let modifierFlags: UInt64
    public let eventType: EventType

    public init(keyCode: UInt16, modifierFlags: UInt64, eventType: EventType) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.eventType = eventType
    }
}

// MARK: - CGKeyCode constants (no CoreGraphics import needed)

public enum KeyCode {
    public static let escape: UInt16 = 53
    public static let tab: UInt16 = 48
    // Arrow keys (US ANSI layout, same across all keyboard types).
    public static let leftArrow: UInt16  = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16  = 125
    public static let upArrow: UInt16    = 126
    // Grave accent / backtick (`~) — used for same-app jump (§6.2).
    public static let grave: UInt16 = 50
}

// MARK: - CGEventFlags bit masks (subset used by SafetyGuard)

public enum ModifierFlag: UInt64 {
    /// kCGEventFlagMaskControl (0x40000)
    case control  = 0x0000000000040000
    /// kCGEventFlagMaskAlternate / Option (0x80000)
    case option   = 0x0000000000080000
    /// kCGEventFlagMaskCommand (0x100000)
    case command  = 0x0000000000100000
}

// MARK: - Tap event types (for §4.4 auto-recovery mapping)

public enum TapEvent: Sendable {
    case tapDisabledByTimeout
    case tapDisabledByUserInput
    case other
}

// MARK: - SafetyGuard evaluation result

/// The result returned by SafetyGuard.evaluate().
/// Order of precedence: emergencyStop > passthroughSecureInput > reenableTap > proceed.
public enum SafetyGuardResult: Equatable, Sendable {
    /// §4.1 — Ctrl+Option+Cmd+Esc detected. Caller must disable the tap.
    case emergencyStop
    /// §4.5 — Secure Input is active; pass the event through untouched.
    case passthroughSecureInput
    /// §4.4 — Tap was disabled by timeout or user input; caller must re-enable it.
    case reenableTap
    /// Normal event; proceed with further processing.
    case proceed
}

// MARK: - SafetyGuard

/// Stateless safety evaluator for CGEventTap callbacks.
///
/// Usage in the tap callback (Step 5):
/// ```swift
/// let result = SafetyGuard.evaluate(event: abstractEvent, isSecureInputEnabled: ...)
/// switch result {
/// case .emergencyStop:        disableTap(); closePanel(); logEmergencyStop()
/// case .passthroughSecureInput: return Unmanaged.passRetained(event) // pass through
/// case .reenableTap:          CGEvent.tapEnable(tap: tap, enable: true); return nil
/// case .proceed:              // continue normal processing
/// }
/// ```
public enum SafetyGuard {

    // MARK: §4.1 Emergency stop combo

    /// Returns true if the event is the Ctrl+Option+Cmd+Esc emergency stop combo.
    /// This check must run before any other logic (§4.1 mandate).
    public static func isEmergencyStop(_ event: KeyEvent) -> Bool {
        guard event.eventType == .keyDown, event.keyCode == KeyCode.escape else {
            return false
        }
        let required: UInt64 = ModifierFlag.control.rawValue
                             | ModifierFlag.option.rawValue
                             | ModifierFlag.command.rawValue
        // All three modifier bits must be set; no extra modifier check needed.
        return (event.modifierFlags & required) == required
    }

    // MARK: §4.4 Tap auto-recovery

    /// Maps a tap-disabled event type to a .reenableTap result.
    public static func tapRecoveryResult(for tapEvent: TapEvent) -> SafetyGuardResult {
        switch tapEvent {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return .reenableTap
        case .other:
            return .proceed
        }
    }

    // MARK: §4.5 Secure Input passthrough

    /// Returns true when Secure Input is active and events should not be consumed.
    public static func isSecureInputPassthrough(isSecureInputEnabled: Bool) -> Bool {
        return isSecureInputEnabled
    }

    // MARK: Primary evaluation (§4 precedence order)

    /// Evaluate a key event and return the action the caller must take.
    /// Precedence: emergencyStop > passthroughSecureInput > reenableTap > proceed.
    public static func evaluate(
        event: KeyEvent,
        isSecureInputEnabled: Bool
    ) -> SafetyGuardResult {
        // 1. Emergency stop is always checked first and wins over everything (§4.1).
        if isEmergencyStop(event) {
            return .emergencyStop
        }

        // 2. Tap-disabled events map to reenableTap before secure-input check (§4.4).
        switch event.eventType {
        case .tapDisabledByTimeout:
            return tapRecoveryResult(for: .tapDisabledByTimeout)
        case .tapDisabledByUserInput:
            return tapRecoveryResult(for: .tapDisabledByUserInput)
        default:
            break
        }

        // 3. Secure Input: pass everything through untouched (§4.5).
        if isSecureInputPassthrough(isSecureInputEnabled: isSecureInputEnabled) {
            return .passthroughSecureInput
        }

        return .proceed
    }
}

// MARK: - §4.2 Deadman switch (DEBUG only)

#if DEBUG

/// Injectable clock protocol so tests can control time without sleeping.
public protocol Clock: Sendable {
    /// Returns the current time as seconds since some epoch (monotonic).
    func now() -> TimeInterval
}

/// Production clock: uses CFAbsoluteTimeGetCurrent for a monotonic wall-clock.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> TimeInterval { CFAbsoluteTimeGetCurrent() }
}

/// Deadman switch that fires a handler after N seconds of inactivity.
///
/// The switch is configured via the `CMDTAB_DEADMAN_SEC` environment variable
/// (default 60 seconds; set to "0" to disable).
///
/// The handler is a closure; the actual tap-disable call is injected at
/// Step 5 so this type remains AppKit-free and unit-testable.
public final class DeadmanSwitch: @unchecked Sendable {

    /// Seconds until the deadman fires. Reads CMDTAB_DEADMAN_SEC; defaults to 60.
    public static func configuredTimeout() -> TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["CMDTAB_DEADMAN_SEC"],
           let secs = TimeInterval(raw) {
            return secs
        }
        return 60
    }

    private let timeoutSeconds: TimeInterval
    private let clock: any Clock
    private let handler: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.senkentarou.cmdtab.deadman")

    /// - Parameters:
    ///   - timeout: Seconds until the handler fires. Pass 0 to disable.
    ///   - clock: Injectable clock for testing.
    ///   - handler: Called when the deadman fires. Must be fast (no blocking).
    public init(
        timeout: TimeInterval = DeadmanSwitch.configuredTimeout(),
        clock: any Clock = SystemClock(),
        handler: @escaping @Sendable () -> Void
    ) {
        self.timeoutSeconds = timeout
        self.clock = clock
        self.handler = handler
    }

    /// Arm the deadman switch. No-op if timeout is 0.
    public func arm() {
        guard timeoutSeconds > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + timeoutSeconds)
        t.setEventHandler { [weak self] in
            self?.handler()
            self?.timer?.cancel()
            self?.timer = nil
        }
        t.resume()
        timer = t
    }

    /// Cancel the deadman switch (e.g. on clean shutdown).
    public func disarm() {
        timer?.cancel()
        timer = nil
    }

    deinit { disarm() }
}

#endif // DEBUG
