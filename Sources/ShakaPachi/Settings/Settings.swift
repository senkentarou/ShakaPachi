// Settings.swift
// Type-safe UserDefaults wrapper for all ShakaPachi preferences (§11.1, §11.2).
//
// Design notes:
// - All keys stored as raw String/Int values so UserDefaults can persist them.
// - Enums are String-rawValue and CaseIterable so SwiftUI pickers can iterate.
// - Changes are broadcast via NotificationCenter (.settingsDidChange) so any
//   observer can react live without coupling to this class directly.
// - Tests should inject a separate UserDefaults suite via Settings(defaults:)
//   to avoid polluting the real domain.
// - Settings.shared uses UserDefaults.standard (the real app domain).

import AppKit
import CoreGraphics

// MARK: - Notification

extension Notification.Name {
    /// Posted on the main queue whenever any Settings value is set.
    static let settingsDidChange = Notification.Name("com.masahirosenda.shakapachi.settingsDidChange")
}

// MARK: - Enums

/// The modifier key used as the switcher trigger.
public enum TriggerModifier: String, CaseIterable, Sendable {
    case command
    case option
    case control

    /// The CGEventFlags mask value corresponding to this modifier.
    /// Matches the ModifierFlag values defined in SafetyGuard.swift.
    public var eventFlagMask: UInt64 {
        switch self {
        case .control: return 0x0000000000040000  // ModifierFlag.control
        case .option:  return 0x0000000000080000  // ModifierFlag.option
        case .command: return 0x0000000000100000  // ModifierFlag.command
        }
    }

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .command: return "Command (⌘)"
        case .option:  return "Option (⌥)"
        case .control: return "Control (^)"
        }
    }
}

/// The key (in combination with the modifier) that triggers the switcher.
public enum TriggerKey: String, CaseIterable, Sendable {
    case tab
    case grave

    /// The CGKeyCode for this key.
    public var keyCode: UInt16 {
        switch self {
        case .tab:   return 48
        case .grave: return 50
        }
    }

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .tab:   return "Tab"
        case .grave: return "Grave (`)"
        }
    }
}

/// Sort order for the window list.
public enum SortMode: String, CaseIterable, Sendable {
    /// Most-recently-used order (the §5.5 MRU array).
    case mru
    /// Raw CGWindowList z-order — no MRU sort applied.
    case zOrder
    /// Windows grouped by app (stable sort by bundleID/appName),
    /// keeping MRU or z-order within each group.
    case byApp

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .mru:    return "最近使った順 (MRU)"
        case .zOrder: return "Z オーダー"
        case .byApp:  return "アプリ別"
        }
    }
}

/// Visual theme for the switcher panel.
public enum Theme: String, CaseIterable, Sendable {
    case light
    case dark
    case system

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .light:  return "ライト"
        case .dark:   return "ダーク"
        case .system: return "システム"
        }
    }

    /// The NSAppearance to apply, or nil for system (inherit).
    public var nsAppearance: NSAppearance? {
        switch self {
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

/// Accent color for the switcher panel highlight and background tint.
public enum AccentColor: String, CaseIterable, Sendable {
    case system
    case blue
    case graphite
    case teal
    case sand
    case plum

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .system:   return "システム"
        case .blue:     return "ブルー"
        case .graphite: return "グラファイト"
        case .teal:     return "ティール"
        case .sand:     return "サンド"
        case .plum:     return "プラム"
        }
    }

    /// The NSColor for this accent. Muted / desaturated — this is a work app.
    public var nsColor: NSColor {
        switch self {
        case .system:
            // Follows the macOS accent color preference.
            return NSColor.controlAccentColor
        case .blue:
            // Desaturated steel blue — readable on both light and dark panels.
            return NSColor(srgbRed: 0.30, green: 0.50, blue: 0.75, alpha: 1.0)
        case .graphite:
            // Neutral grey with a slight warm cast.
            return NSColor(srgbRed: 0.50, green: 0.52, blue: 0.55, alpha: 1.0)
        case .teal:
            // Muted teal, low saturation so it doesn't dominate.
            return NSColor(srgbRed: 0.22, green: 0.55, blue: 0.55, alpha: 1.0)
        case .sand:
            // Warm sandy beige — professional and neutral.
            return NSColor(srgbRed: 0.72, green: 0.62, blue: 0.45, alpha: 1.0)
        case .plum:
            // Muted plum — subtle and sophisticated.
            return NSColor(srgbRed: 0.50, green: 0.35, blue: 0.58, alpha: 1.0)
        }
    }
}

// MARK: - @propertyWrapper

/// A property wrapper that reads/writes a String-raw-valued enum to UserDefaults.
/// Falls back to `defaultValue` when the stored string is missing or unrecognized.
@propertyWrapper
struct DefaultsEnum<T: RawRepresentable> where T.RawValue == String {
    let key: String
    let defaultValue: T
    nonisolated(unsafe) let defaults: UserDefaults

    var wrappedValue: T {
        get {
            guard let raw = defaults.string(forKey: key),
                  let value = T(rawValue: raw) else { return defaultValue }
            return value
        }
        // nonmutating: the setter writes to `defaults` (a reference type), never
        // to this struct's own storage, so it needs no exclusive (mutating) access
        // to the wrapper. This matters because .settingsDidChange is delivered
        // synchronously and an observer (SettingsStore.refresh) reads the SAME
        // property while this setter is still on the stack; a mutating set would
        // overlap a write with that read and trip Swift's exclusive-access check
        // (SIGABRT). Writing to defaults is logically non-mutating, so this is
        // also the semantically correct annotation.
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }
}

/// A property wrapper for Int settings.
// nonisolated(unsafe) suppresses the Sendable warning on `defaults` because
// Settings is @MainActor-isolated and these wrappers are only accessed from the
// main actor. UserDefaults itself is thread-safe for simple reads/writes.
@propertyWrapper
struct DefaultsInt {
    let key: String
    let defaultValue: Int
    nonisolated(unsafe) let defaults: UserDefaults

    var wrappedValue: Int {
        get {
            defaults.object(forKey: key) != nil
                ? defaults.integer(forKey: key)
                : defaultValue
        }
        // nonmutating: writes to `defaults`, not self — avoids exclusive-access
        // reentrancy under synchronous .settingsDidChange delivery (see DefaultsEnum).
        nonmutating set {
            defaults.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }
}

/// A property wrapper for Bool settings.
@propertyWrapper
struct DefaultsBool {
    let key: String
    let defaultValue: Bool
    nonisolated(unsafe) let defaults: UserDefaults

    var wrappedValue: Bool {
        get {
            defaults.object(forKey: key) != nil
                ? defaults.bool(forKey: key)
                : defaultValue
        }
        // nonmutating: writes to `defaults`, not self — avoids exclusive-access
        // reentrancy under synchronous .settingsDidChange delivery (see DefaultsEnum).
        nonmutating set {
            defaults.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }
}

/// A property wrapper for [String] settings (stored as plist array).
@propertyWrapper
struct DefaultsStringArray {
    let key: String
    let defaultValue: [String]
    nonisolated(unsafe) let defaults: UserDefaults

    var wrappedValue: [String] {
        get {
            (defaults.array(forKey: key) as? [String]) ?? defaultValue
        }
        // nonmutating: writes to `defaults`, not self — avoids exclusive-access
        // reentrancy under synchronous .settingsDidChange delivery (see DefaultsEnum).
        nonmutating set {
            defaults.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }
}

// MARK: - Settings

/// All ShakaPachi user preferences.
///
/// Use `Settings.shared` in production code.
/// Inject a custom `UserDefaults(suiteName:)` in unit tests so they don't
/// pollute UserDefaults.standard.
@MainActor
final class Settings {

    // MARK: Shared instance

    static let shared = Settings()

    // MARK: Init

    /// Creates a Settings instance backed by the given UserDefaults.
    /// - Parameter defaults: The backing store. Pass `UserDefaults.standard`
    ///   in production; pass a test suite in unit tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _triggerModifier = DefaultsEnum(key: "triggerModifier", defaultValue: .command, defaults: defaults)
        _triggerKey      = DefaultsEnum(key: "triggerKey",      defaultValue: .tab,     defaults: defaults)
        _sortMode        = DefaultsEnum(key: "sortMode",        defaultValue: .mru,     defaults: defaults)
        _theme           = DefaultsEnum(key: "theme",           defaultValue: .system,  defaults: defaults)
        _maxRows         = DefaultsInt (key: "maxRows",         defaultValue: 20,       defaults: defaults)
        _showDelayMs     = DefaultsInt (key: "showDelayMs",     defaultValue: 0,        defaults: defaults)
        _panelWidth      = DefaultsInt (key: "panelWidth",      defaultValue: 480,      defaults: defaults)
        _currentSpaceOnly   = DefaultsBool(key: "currentSpaceOnly",   defaultValue: true,  defaults: defaults)
        _launchAtLogin      = DefaultsBool(key: "launchAtLogin",      defaultValue: true,  defaults: defaults)
        _excludedBundleIDs  = DefaultsStringArray(key: "excludedBundleIDs", defaultValue: [], defaults: defaults)
        _accentColor        = DefaultsEnum(key: "accentColor",        defaultValue: .system, defaults: defaults)
    }

    // MARK: Backing store

    private let defaults: UserDefaults

    // MARK: §11.2 Settings

    // -- Input --

    /// The modifier key that must be held to trigger the switcher.
    /// Default: .command — the shipping default (§13-2 chose Cmd+Tab as the
    /// primary trigger, and Step 5b verified the standard App Switcher can be
    /// suppressed). During early development this was .option (§4.7); it is
    /// switched now that the app is stable. Users can change it in Settings.
    private var _triggerModifier: DefaultsEnum<TriggerModifier>
    var triggerModifier: TriggerModifier {
        get { _triggerModifier.wrappedValue }
        set { _triggerModifier.wrappedValue = newValue }
    }

    /// The key that, combined with triggerModifier, opens the switcher.
    private var _triggerKey: DefaultsEnum<TriggerKey>
    var triggerKey: TriggerKey {
        get { _triggerKey.wrappedValue }
        set { _triggerKey.wrappedValue = newValue }
    }

    // -- Layout (advisory in v1 — see note below) --

    /// Maximum number of rows to display.
    ///
    /// NOTE: The Step 7 implementation chose a HORIZONTAL tile layout that
    /// auto-sizes its width to the tile count and shrinks tiles to fit.
    /// This property is retained for model completeness but is NOT wired to
    /// the panel in v1 — the horizontal auto-sizing layout makes it advisory.
    private var _maxRows: DefaultsInt
    var maxRows: Int {
        get { _maxRows.wrappedValue }
        set { _maxRows.wrappedValue = newValue }
    }

    // -- Display --

    /// Delay in milliseconds between trigger and panel appearance.
    /// 0 = immediate (default). Changing this takes effect on the next trigger.
    private var _showDelayMs: DefaultsInt
    var showDelayMs: Int {
        get { _showDelayMs.wrappedValue }
        set { _showDelayMs.wrappedValue = newValue }
    }

    /// When true, only windows on the current Space are enumerated.
    private var _currentSpaceOnly: DefaultsBool
    var currentSpaceOnly: Bool {
        get { _currentSpaceOnly.wrappedValue }
        set { _currentSpaceOnly.wrappedValue = newValue }
    }

    // -- Sorting --

    /// How the window list is sorted.
    private var _sortMode: DefaultsEnum<SortMode>
    var sortMode: SortMode {
        get { _sortMode.wrappedValue }
        set { _sortMode.wrappedValue = newValue }
    }

    // -- Exclusion --

    /// Bundle IDs excluded from the window list.
    private var _excludedBundleIDs: DefaultsStringArray
    var excludedBundleIDs: [String] {
        get { _excludedBundleIDs.wrappedValue }
        set { _excludedBundleIDs.wrappedValue = newValue }
    }

    // -- Appearance --

    /// Visual theme for the switcher panel.
    private var _theme: DefaultsEnum<Theme>
    var theme: Theme {
        get { _theme.wrappedValue }
        set { _theme.wrappedValue = newValue }
    }

    // -- System integration --

    /// Whether to register the app as a Login Item.
    /// Model only — actual SMAppService registration is Step 13.
    private var _launchAtLogin: DefaultsBool
    var launchAtLogin: Bool {
        get { _launchAtLogin.wrappedValue }
        set { _launchAtLogin.wrappedValue = newValue }
    }

    // -- Accent color --

    /// Accent color applied to the switcher panel highlight and background tint.
    private var _accentColor: DefaultsEnum<AccentColor>
    var accentColor: AccentColor {
        get { _accentColor.wrappedValue }
        set { _accentColor.wrappedValue = newValue }
    }

    // -- Panel width (advisory in v1 — see note below) --

    /// Panel width in points.
    ///
    /// NOTE: The Step 7 implementation chose a HORIZONTAL tile layout that
    /// derives its width from the tile count (auto-sizing). This property is
    /// retained for model completeness but is NOT wired to the panel in v1 —
    /// the horizontal auto-sizing layout makes it advisory.
    private var _panelWidth: DefaultsInt
    var panelWidth: Int {
        get { _panelWidth.wrappedValue }
        set { _panelWidth.wrappedValue = newValue }
    }
}
