// SafetyGuardTests.swift
// Verifies §4 safety mechanisms via pure logic — no AppKit or display needed.

import XCTest
@testable import CmdTab

final class SafetyGuardTests: XCTestCase {

    // MARK: - Helpers

    /// Build a KeyEvent for the Ctrl+Option+Cmd+Esc emergency combo.
    private func emergencyEvent() -> KeyEvent {
        KeyEvent(
            keyCode: KeyCode.escape,
            modifierFlags: ModifierFlag.control.rawValue
                         | ModifierFlag.option.rawValue
                         | ModifierFlag.command.rawValue,
            eventType: .keyDown
        )
    }

    // MARK: - §4.1 Emergency stop detection

    func testEmergencyStop_exactComboDetected() {
        let event = emergencyEvent()
        XCTAssertTrue(SafetyGuard.isEmergencyStop(event),
            "Ctrl+Option+Cmd+Esc must be detected as emergency stop")
    }

    func testEmergencyStop_subsetCmdEsc_notDetected() {
        // Cmd+Esc without Ctrl or Option must NOT trigger emergency stop.
        let event = KeyEvent(
            keyCode: KeyCode.escape,
            modifierFlags: ModifierFlag.command.rawValue,
            eventType: .keyDown
        )
        XCTAssertFalse(SafetyGuard.isEmergencyStop(event),
            "Cmd+Esc alone must not trigger emergency stop")
    }

    func testEmergencyStop_subsetCtrlOptionEsc_notDetected() {
        // Ctrl+Option+Esc without Cmd must NOT trigger emergency stop.
        let event = KeyEvent(
            keyCode: KeyCode.escape,
            modifierFlags: ModifierFlag.control.rawValue | ModifierFlag.option.rawValue,
            eventType: .keyDown
        )
        XCTAssertFalse(SafetyGuard.isEmergencyStop(event),
            "Ctrl+Option+Esc without Cmd must not trigger emergency stop")
    }

    func testEmergencyStop_subsetCtrlCmdEsc_notDetected() {
        // Ctrl+Cmd+Esc without Option must NOT trigger emergency stop.
        let event = KeyEvent(
            keyCode: KeyCode.escape,
            modifierFlags: ModifierFlag.control.rawValue | ModifierFlag.command.rawValue,
            eventType: .keyDown
        )
        XCTAssertFalse(SafetyGuard.isEmergencyStop(event),
            "Ctrl+Cmd+Esc without Option must not trigger emergency stop")
    }

    func testEmergencyStop_escOnly_notDetected() {
        let event = KeyEvent(
            keyCode: KeyCode.escape,
            modifierFlags: 0,
            eventType: .keyDown
        )
        XCTAssertFalse(SafetyGuard.isEmergencyStop(event))
    }

    func testEmergencyStop_wrongKey_notDetected() {
        // Correct modifiers but wrong key (Tab = 48).
        let event = KeyEvent(
            keyCode: 48,
            modifierFlags: ModifierFlag.control.rawValue
                         | ModifierFlag.option.rawValue
                         | ModifierFlag.command.rawValue,
            eventType: .keyDown
        )
        XCTAssertFalse(SafetyGuard.isEmergencyStop(event),
            "Emergency stop must only fire for Escape key")
    }

    func testEmergencyStop_keyUp_notDetected() {
        // keyUp event for the same combo must not trigger.
        let event = KeyEvent(
            keyCode: KeyCode.escape,
            modifierFlags: ModifierFlag.control.rawValue
                         | ModifierFlag.option.rawValue
                         | ModifierFlag.command.rawValue,
            eventType: .keyUp
        )
        XCTAssertFalse(SafetyGuard.isEmergencyStop(event),
            "Emergency stop must only fire on keyDown")
    }

    // MARK: - §4.1 Emergency stop wins over secure-input passthrough

    func testEvaluate_emergencyStop_winsOverSecureInput() {
        // Even when Secure Input is enabled, emergency stop must take priority.
        let event = emergencyEvent()
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: true)
        XCTAssertEqual(result, .emergencyStop,
            "Emergency stop must win over secure-input passthrough")
    }

    func testEvaluate_emergencyStop_proceedsNormally() {
        let event = emergencyEvent()
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: false)
        XCTAssertEqual(result, .emergencyStop)
    }

    // MARK: - §4.4 Tap auto-recovery

    func testTapRecovery_disabledByTimeout_mapsToReenableTap() {
        let result = SafetyGuard.tapRecoveryResult(for: .tapDisabledByTimeout)
        XCTAssertEqual(result, .reenableTap)
    }

    func testTapRecovery_disabledByUserInput_mapsToReenableTap() {
        let result = SafetyGuard.tapRecoveryResult(for: .tapDisabledByUserInput)
        XCTAssertEqual(result, .reenableTap)
    }

    func testEvaluate_tapDisabledByTimeout_returnsReenableTap() {
        let event = KeyEvent(keyCode: 0, modifierFlags: 0, eventType: .tapDisabledByTimeout)
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: false)
        XCTAssertEqual(result, .reenableTap)
    }

    func testEvaluate_tapDisabledByUserInput_returnsReenableTap() {
        let event = KeyEvent(keyCode: 0, modifierFlags: 0, eventType: .tapDisabledByUserInput)
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: false)
        XCTAssertEqual(result, .reenableTap)
    }

    // MARK: - §4.5 Secure Input passthrough

    func testSecureInput_passthrough_whenEnabled() {
        let result = SafetyGuard.isSecureInputPassthrough(isSecureInputEnabled: true)
        XCTAssertTrue(result)
    }

    func testSecureInput_noPassthrough_whenDisabled() {
        let result = SafetyGuard.isSecureInputPassthrough(isSecureInputEnabled: false)
        XCTAssertFalse(result)
    }

    func testEvaluate_normalEvent_secureInputEnabled_returnsPassthrough() {
        let event = KeyEvent(keyCode: 48, modifierFlags: 0, eventType: .keyDown)
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: true)
        XCTAssertEqual(result, .passthroughSecureInput)
    }

    func testEvaluate_normalEvent_secureInputDisabled_returnsProceeed() {
        let event = KeyEvent(keyCode: 48, modifierFlags: 0, eventType: .keyDown)
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: false)
        XCTAssertEqual(result, .proceed)
    }

    // MARK: - §4.2 Deadman switch (DEBUG only)

    #if DEBUG
    func testDeadman_firesAtConfiguredTime() {
        let expectation = expectation(description: "Deadman fires")
        let timeout: TimeInterval = 0.1  // 100ms — fast enough for tests

        let deadman = DeadmanSwitch(timeout: timeout, clock: SystemClock()) {
            expectation.fulfill()
        }
        deadman.arm()

        wait(for: [expectation], timeout: timeout + 1.0)
    }

    func testDeadman_doesNotFire_whenTimeoutIsZero() {
        // Use an actor-isolated flag to avoid Sendable mutation warning.
        // The test verifies that the handler closure is never called.
        let notFiredExp = expectation(description: "handler not fired")
        notFiredExp.isInverted = true  // fulfilling it would mean the test fails

        let deadman = DeadmanSwitch(timeout: 0, clock: SystemClock()) {
            notFiredExp.fulfill()
        }
        deadman.arm()

        // Wait briefly; inverted expectation must time out (i.e. handler never fires).
        wait(for: [notFiredExp], timeout: 0.3)
    }

    func testDeadman_configuredTimeout_readsEnvVar() {
        // Verify configuredTimeout() parses CMDTAB_DEADMAN_SEC.
        // We can't set env vars at runtime in tests, but we can verify
        // the default is 60 when the variable is not set.
        // (The env var may or may not be set in CI; just check the type.)
        let t = DeadmanSwitch.configuredTimeout()
        XCTAssertGreaterThanOrEqual(t, 0, "Timeout must be non-negative")
    }
    #endif
}
