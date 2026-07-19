// HotkeyTap.swift
// CGEventTap lifecycle (§6.1) wired to the §4 safety mechanisms.
// Step 5 scope: capture Option+Tab, log, consume. No switcher UI yet.
//
// Callback absolute rules (§4.3): no blocking work, no unbounded loops,
// return within 1ms. Logging and UI updates are deferred to the main queue;
// only tapEnable() calls happen synchronously inside the callback.
//
// All methods must be called on the main thread. The tap's run-loop source
// is attached to the main run loop, so the callback also runs there.

import AppKit
import Carbon

final class HotkeyTap {

    enum State {
        case active
        case stopped(reason: String)
    }

    /// Notified on enable/disable so the status item can reflect tap state.
    /// Always called on the main queue.
    var onStateChange: ((State) -> Void)?

    /// Called on the main queue when Option+Tab keyDown is captured.
    /// The argument is the CFAbsoluteTime recorded at the very top of the
    /// tap callback — before any other work — so callers can measure N1.
    var onTrigger: ((CFAbsoluteTime) -> Void)?

    /// Called on the main queue when the Option modifier is released while
    /// the switcher panel is visible (dumb wiring until Step 9 state machine).
    var onModifierReleased: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isEnabled = false

    #if DEBUG
    private var deadman: DeadmanSwitch?
    #endif

    // MARK: - Lifecycle

    /// Creates (if needed) and enables the tap. Returns false when the tap
    /// cannot be created — typically missing accessibility permission.
    @discardableResult
    func enable() -> Bool {
        if eventTap == nil {
            let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                                  | (1 << CGEventType.keyUp.rawValue)
                                  | (1 << CGEventType.flagsChanged.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,   // ahead of the system App Switcher (§6.1)
                options: .defaultTap,          // must consume, listenOnly is not enough
                eventsOfInterest: mask,
                callback: hotkeyTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                NSLog("[CmdTab] Failed to create event tap — accessibility permission missing?")
                return false
            }
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        isEnabled = true
        armDeadman()
        NSLog("[CmdTab] Event tap enabled (trigger: Option+Tab, log-only)")
        onStateChange?(.active)
        return true
    }

    /// Disables the tap. The mach port is kept so enable() can re-arm cheaply.
    func disable(reason: String) {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        isEnabled = false
        disarmDeadman()
        NSLog("[CmdTab] Event tap disabled (%@)", reason)
        onStateChange?(.stopped(reason: reason))
    }

    // MARK: - Deadman switch (§4.2, DEBUG only)

    private func armDeadman() {
        #if DEBUG
        deadman?.disarm()
        let dm = DeadmanSwitch { [weak self] in
            // Fires on the deadman's private queue; hop to main for AppKit.
            DispatchQueue.main.async {
                guard let self, self.isEnabled else { return }
                self.disable(reason: "デッドマンスイッチ (自動停止)")
            }
        }
        dm.arm()
        deadman = dm
        NSLog("[CmdTab] Deadman switch armed (%.0fs)", DeadmanSwitch.configuredTimeout())
        #endif
    }

    private func disarmDeadman() {
        #if DEBUG
        deadman?.disarm()
        deadman = nil
        #endif
    }

    // MARK: - Event handling (called from the tap callback)

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // §4.3 / N1: record entry time before any other work.
        let t0 = CFAbsoluteTimeGetCurrent()

        let eventType: KeyEvent.EventType
        switch type {
        case .keyDown:                eventType = .keyDown
        case .keyUp:                  eventType = .keyUp
        case .flagsChanged:           eventType = .flagsChanged
        case .tapDisabledByTimeout:   eventType = .tapDisabledByTimeout
        case .tapDisabledByUserInput: eventType = .tapDisabledByUserInput
        default:                      eventType = .other
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let abstract = KeyEvent(
            keyCode: keyCode,
            modifierFlags: event.flags.rawValue,
            eventType: eventType
        )

        switch SafetyGuard.evaluate(
            event: abstract,
            isSecureInputEnabled: IsSecureEventInputEnabled()
        ) {
        case .emergencyStop:
            // §4.1: disable synchronously, never consume the combo itself.
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            isEnabled = false
            DispatchQueue.main.async { [weak self] in
                NSLog("[CmdTab] EMERGENCY STOP (Ctrl+Option+Cmd+Esc) — tap disabled")
                self?.disarmDeadman()
                self?.onStateChange?(.stopped(reason: "緊急停止"))
            }
            return Unmanaged.passUnretained(event)

        case .reenableTap:
            // §4.4 recovers from SYSTEM-initiated disables (timeout, input
            // safety). Intentional disables (emergency stop, deadman, menu)
            // also surface here as tapDisabledByUserInput — isEnabled is
            // already false then, and re-enabling would defeat the kill
            // switches, so recover only while we intend to be running.
            if isEnabled, let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                DispatchQueue.main.async {
                    NSLog("[CmdTab] Tap auto-recovered from tapDisabled event — frequent occurrences indicate a performance problem")
                }
            }
            return nil

        case .passthroughSecureInput:
            return Unmanaged.passUnretained(event)

        case .proceed:
            break
        }

        // Step 7: consume Option+Tab (both key phases) and fire onTrigger on
        // keyDown so AppDelegate can show the panel. Consuming keyUp prevents
        // an orphan keyUp from reaching the frontmost app (Step 5 behaviour
        // preserved). §4.3: no blocking work — hand off to main queue.
        if (eventType == .keyDown || eventType == .keyUp),
           keyCode == KeyCode.tab,
           event.flags.contains(.maskAlternate) {
            if eventType == .keyDown {
                let capturedT0 = t0
                DispatchQueue.main.async { [weak self] in
                    self?.onTrigger?(capturedT0)
                }
            }
            return nil
        }

        // Observe Option modifier release (flagsChanged with Option cleared).
        // Dumb wiring until Step 9 state machine: caller decides whether to hide.
        if eventType == .flagsChanged,
           !event.flags.contains(.maskAlternate) {
            DispatchQueue.main.async { [weak self] in
                self?.onModifierReleased?()
            }
        }

        return Unmanaged.passUnretained(event)
    }
}

// MARK: - C callback trampoline

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handleEvent(type: type, event: event)
}
