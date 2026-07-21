// SettingsWindow.swift
// Settings window (§11.3): NSWindow + NSTabView with four tabs.
// SwiftUI is embedded via NSHostingView for the control-heavy tabs (§11.3
// explicitly permits this: "the settings screen has no speed requirements so embedding SwiftUI is fine").
//
// Activation policy: switches to .regular on show and back to .accessory on
// close — but ONLY if the onboarding window is not also open (§11.3 note).

import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the Settings window opens (`open: true`) or closes
    /// (`open: false`) so the menu-bar icon can show its blue "info" state.
    static let settingsWindowStateChanged =
        Notification.Name("com.masahirosenda.shakapachi.settingsWindowStateChanged")
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    // Weak reference to OnboardingWindow so we can check whether it is open
    // before reverting the activation policy. OnboardingWindow manages its own
    // show/close cycle; we only inspect its open state.
    private weak var onboardingWindow: OnboardingWindow?

    init(onboardingWindow: OnboardingWindow?) {
        self.onboardingWindow = onboardingWindow
        super.init()
    }

    // MARK: - Public

    func show() {
        NotificationCenter.default.post(
            name: .settingsWindowStateChanged, object: nil, userInfo: ["open": true])
        if let win = window {
            raiseToFront(win)
            return
        }

        // §11.3: bring app to front so the window is visible.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let win = makeWindow()
        win.delegate = self
        win.contentViewController = makeSettingsRootController()
        win.setContentSize(NSSize(width: 560, height: 660))
        win.center()
        // Keep the settings window findable: float above other windows and
        // follow the user onto whichever Space is active, so it can't get lost
        // behind other apps once opened.
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.window = win

        raiseToFront(win)
    }

    /// Bring the settings window to the absolute front on the active Space.
    private func raiseToFront(_ win: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    /// Close the Settings window programmatically (e.g. from the tray menu).
    /// Triggers windowWillClose, which posts the state-change notification and
    /// reverts the activation policy.
    func close() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(
            name: .settingsWindowStateChanged, object: nil, userInfo: ["open": false])
        // §11.3: revert to .accessory only when the onboarding window is also
        // NOT open. If both were open, reverting here would hide the onboarding
        // window from the screen because it would lose its .regular policy too.
        // OnboardingWindow handles its own revert in its windowWillClose.
        let onboardingIsOpen = onboardingWindow?.isWindowOpen ?? false
        if !onboardingIsOpen {
            NSApp.setActivationPolicy(.accessory)
        }
        window = nil
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = NSLocalizedString("ShakaPachi 設定", comment: "Settings window title")
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 460, height: 420)
        return win
    }

    /// Wraps the tab controller with a small top inset so the segmented tab
    /// control isn't flush against the title bar (user request).
    private func makeSettingsRootController() -> NSViewController {
        let tvc = makeTabViewController()
        let root = NSViewController()
        root.view = NSView()
        root.addChild(tvc)
        tvc.view.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(tvc.view)
        NSLayoutConstraint.activate([
            tvc.view.topAnchor.constraint(equalTo: root.view.topAnchor, constant: 12),
            tvc.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            tvc.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            tvc.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
        ])
        return root
    }

    private func makeTabViewController() -> NSTabViewController {
        let tvc = NSTabViewController()
        // Modern centered segmented control at the top (like System Settings),
        // instead of NSTabView's dated `.topTabsBezelBorder` which drew a bezel
        // box and looked cramped/broken flush against the title bar regardless of
        // inset. This style has no bezel and manages its own spacing.
        tvc.tabStyle = .segmentedControlOnTop

        // Give every tab the same min frame so switching tabs never resizes the
        // window (NSTabViewController otherwise fits each tab's own content).
        func addTab<V: View>(_ label: String, _ view: V) {
            let sized = view.frame(minWidth: 520, maxWidth: .infinity,
                                   minHeight: 360, maxHeight: .infinity)
            let item = NSTabViewItem(viewController: NSHostingController(rootView: sized))
            // NSTabViewItem.label is verbatim AppKit (no LocalizedStringKey), so
            // localize it explicitly. Keys live in Localizable.strings.
            item.label = NSLocalizedString(label, comment: "Settings tab label")
            tvc.addTabViewItem(item)
        }

        addTab("一般", GeneralSettingsView())
        addTab("外観", AppearanceSettingsView())
        addTab("状態", StatusSettingsView())
        addTab("統計", StatsSettingsView())
        addTab("クレジット", AboutSettingsView())
        return tvc
    }
}

// MARK: - OnboardingWindow open-state check
// OnboardingWindow exposes isWindowOpen via its own property (see OnboardingWindow.swift).


// MARK: - SwiftUI Settings Views

// ─── Observable bridge ────────────────────────────────────────────────────────
// NSHostingView hosts SwiftUI views. To make settings changes propagate live
// to the SwiftUI layer we use an ObservableObject that wraps Settings.shared
// and listens to .settingsDidChange. All SwiftUI views read from this object.

@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    // Re-published properties (SwiftUI reads these for bindings).
    @Published var triggerModifier: TriggerModifier
    @Published var triggerKey: TriggerKey
    @Published var showDelayMs: Int
    @Published var currentSpaceOnly: Bool
    @Published var sortMode: SortMode
    @Published var excludedBundleIDs: [String]
    @Published var theme: Theme
    @Published var launchAtLogin: Bool
    @Published var accentColor: AccentColor
    @Published var showWindowPreview: Bool

    private var observer: (any NSObjectProtocol)?

    init() {
        let s = Settings.shared
        triggerModifier   = s.triggerModifier
        triggerKey        = s.triggerKey
        showDelayMs       = s.showDelayMs
        currentSpaceOnly  = s.currentSpaceOnly
        sortMode          = s.sortMode
        excludedBundleIDs = s.excludedBundleIDs
        theme             = s.theme
        accentColor       = s.accentColor
        showWindowPreview = s.showWindowPreview
        // The real login-item state lives in SMAppService, not the cached bool;
        // read it so the toggle reflects reality (and heal a stale mirror).
        launchAtLogin    = LoginItemManager.isEnabled
        if s.launchAtLogin != launchAtLogin { s.launchAtLogin = launchAtLogin }

        // Reflect changes that originate elsewhere (e.g. from code) back into
        // the Published properties so the SwiftUI view stays consistent.
        observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let s = Settings.shared
        // Only assign when the value actually changed to avoid SwiftUI churn.
        if triggerModifier  != s.triggerModifier  { triggerModifier  = s.triggerModifier  }
        if triggerKey       != s.triggerKey       { triggerKey       = s.triggerKey       }
        if showDelayMs      != s.showDelayMs      { showDelayMs      = s.showDelayMs      }
        if currentSpaceOnly != s.currentSpaceOnly { currentSpaceOnly = s.currentSpaceOnly }
        if sortMode         != s.sortMode         { sortMode         = s.sortMode         }
        if excludedBundleIDs != s.excludedBundleIDs { excludedBundleIDs = s.excludedBundleIDs }
        if theme             != s.theme             { theme             = s.theme             }
        if accentColor       != s.accentColor       { accentColor       = s.accentColor       }
        if launchAtLogin     != s.launchAtLogin     { launchAtLogin     = s.launchAtLogin     }
        if showWindowPreview != s.showWindowPreview { showWindowPreview = s.showWindowPreview }
    }
}

// ─── General tab ──────────────────────────────────────────────────────────────

struct GeneralSettingsView: View {

    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                // Modifier-only picker: the trigger key is fixed to Tab.
                // On set, both modifier and key are written so any previously-
                // stored .grave value is normalized to .tab on first save.
                Picker("トリガー", selection: Binding(
                    get: { store.triggerModifier },
                    set: { modifier in
                        Settings.shared.triggerModifier = modifier
                        Settings.shared.triggerKey      = .tab
                    }
                )) {
                    ForEach(TriggerModifier.allCases, id: \.self) { modifier in
                        Text("\(modifier.displayName) + Tab").tag(modifier)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("トリガー")
            }

            Section {
                // .zOrder is intentionally excluded from the picker; the enum
                // case is kept for internal WindowStore use but is not exposed
                // as a user-selectable option.
                Picker("並び順", selection: Binding(
                    get: { store.sortMode },
                    set: { Settings.shared.sortMode = $0 }
                )) {
                    ForEach([SortMode.mru, .byApp], id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                // Show live window preview below the title line.
                // Actual capture is gated on screen-recording permission at show time;
                // turning this off avoids any CGWindowListCreateImage call entirely.
                Toggle("ウィンドウプレビューを表示", isOn: Binding(
                    get: { store.showWindowPreview },
                    set: { Settings.shared.showWindowPreview = $0 }
                ))
            } header: {
                Text("動作")
            }

            Section {
                // §11.4: launch-at-login via SMAppService. The system status is
                // the source of truth; the Settings bool mirrors it for the UI.
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { newValue in
                        do {
                            try LoginItemManager.setEnabled(newValue)
                            Settings.shared.launchAtLogin = LoginItemManager.isEnabled
                        } catch {
                            // Registration failed — revert the mirror to the real
                            // status so the toggle reflects reality, and surface it.
                            Settings.shared.launchAtLogin = LoginItemManager.isEnabled
                            NSLog("[ShakaPachi] Login item change failed: %@",
                                  error.localizedDescription)
                        }
                    }
                ))
            } header: {
                Text("システム")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 12)
        .padding([.leading, .trailing, .bottom])
        .onAppear {
            // .zOrder is no longer listed in the picker; normalize it to .mru
            // so the picker never shows an unlisted selection.
            if Settings.shared.sortMode == .zOrder {
                Settings.shared.sortMode = .mru
            }
        }
    }
}

// ─── Appearance tab ───────────────────────────────────────────────────────────

struct AppearanceSettingsView: View {

    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("テーマ", selection: Binding(
                    get: { store.theme },
                    set: { Settings.shared.theme = $0 }
                )) {
                    ForEach(Theme.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.menu)

                Picker("アクセントカラー", selection: Binding(
                    get: { store.accentColor },
                    set: { Settings.shared.accentColor = $0 }
                )) {
                    ForEach(AccentColor.allCases, id: \.self) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("外観")
            }

            Section {
                AppearancePreviewView(theme: store.theme, accent: store.accentColor)
            } header: {
                Text("プレビュー")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 12)
        .padding([.leading, .trailing, .bottom])
    }
}

// ─── Status tab ───────────────────────────────────────────────────────────────

struct StatusSettingsView: View {

    @State private var accessibilityGranted: Bool = false
    @State private var screenRecordingGranted: Bool = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    ForEach(TrayIconState.allCases, id: \.self) { state in
                        HStack(spacing: 12) {
                            Image(nsImage: TrayIconRenderer.previewImage(for: state, size: 32))
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.cardName)
                                    .font(.body)
                                Text(state.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } header: {
                    Text("アイコンの状態")
                }

                Section {
                    HStack {
                        Image(systemName: accessibilityGranted
                              ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundColor(accessibilityGranted ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("アクセシビリティ")
                                .font(.body)
                            Text("切替キーの捕捉とウィンドウの前面化に使います。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if accessibilityGranted {
                            Text("許可済み").foregroundColor(.secondary).font(.caption)
                        } else {
                            Button("設定を開く") {
                                if let url = URL(string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    HStack {
                        Image(systemName: screenRecordingGranted
                              ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundColor(screenRecordingGranted ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("画面収録")
                                .font(.body)
                            Text("ウィンドウ名の取得だけに使います。画面の撮影・保存はしません。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if screenRecordingGranted {
                            Text("許可済み").foregroundColor(.secondary).font(.caption)
                        } else {
                            Button("設定を開く") {
                                if let url = URL(string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("権限の状態")
                }
            }
            .formStyle(.grouped)
            .padding(.top, 12)
            .padding([.leading, .trailing, .bottom])

            // Plain onboarding button below the form, no section/card wrapper.
            // A wrapper section containing only a button provides no semantic
            // value — the button alone is sufficient.
            Button("オンボーディング画面を開く") {
                // Post a notification that AppDelegate can observe to open
                // the onboarding window. Using NotificationCenter avoids a
                // direct dependency from this SwiftUI view to AppDelegate.
                NotificationCenter.default.post(
                    name: .showOnboardingWindow, object: nil)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .onAppear { refreshPermissions() }
        .onReceive(timer) { _ in refreshPermissions() }
    }

    private func refreshPermissions() {
        accessibilityGranted   = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }
}

// ─── Stats tab ────────────────────────────────────────────────────────────────

struct StatsSettingsView: View {

    // Snapshot taken at appear time.
    @State private var statsEnabled: Bool = true
    @State private var todayCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var dailyCounts: [String: Int] = [:]
    @State private var firstUseDate: String? = nil
    @State private var currentStreak: Int = 0
    @State private var longest: Int = 0
    @State private var showResetConfirm: Bool = false

    // Locale-aware thousands separator (e.g. "1,234").
    private let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // ── Recording ──
                Section {
                    Toggle("統計を記録", isOn: $statsEnabled)
                        .onChange(of: statsEnabled) { newValue in
                            StatsStore.shared.setStatsEnabled(newValue)
                        }
                } header: {
                    Text("記録")
                }

                // ── Switch count ──
                Section {
                    HStack {
                        Text("今日")
                        Spacer()
                        Text(formatted(todayCount))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("累計")
                        Spacer()
                        Text(formatted(totalCount))
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("切替回数")
                }

                // ── Activity (streak strip + heatmap) ──
                Section {
                    // Streak count above the heatmap.
                    Text(String(format: NSLocalizedString("%lld 日連続", comment: "Consecutive-day streak"), currentStreak))
                        .font(.headline)
                        .padding(.bottom, 8)   // breathing room above the heatmap

                    ContributionHeatmap(
                        dailyCounts: dailyCounts,
                        firstUseDate: firstUseDate
                    )
                    .padding(.vertical, 4)
                } header: {
                    Text("アクティビティ")
                }
            }
            .formStyle(.grouped)
            .padding(.top, 12)
            .padding([.leading, .trailing])

            // Reset button outside the Form — standalone, left-aligned (matches
            // the permissions tab's "Open onboarding" (「オンボーディング画面を開く」) footer button).
            HStack {
                Button("統計をリセット") {
                    showResetConfirm = true
                }
                .foregroundColor(.red)
                .confirmationDialog(
                    "統計をリセットしますか？",
                    isPresented: $showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("リセット", role: .destructive) {
                        StatsStore.shared.reset()
                        reloadSnapshot()
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("切替回数・連続記録・日次履歴がすべてクリアされます。この操作は元に戻せません。")
                }
                Spacer()
            }
            .padding([.leading, .trailing, .bottom])
            .padding(.top, 8)
        }
        .onAppear { reloadSnapshot() }
    }

    private func reloadSnapshot() {
        statsEnabled = StatsStore.shared.isStatsEnabled
        todayCount   = StatsStore.shared.todayCount
        totalCount   = StatsStore.shared.totalCount
        dailyCounts  = StatsStore.shared.dailyCounts
        firstUseDate = StatsStore.shared.firstUseDate
        let activeDays = Set(dailyCounts.filter { $0.value > 0 }.keys)
        let todayStr   = StreakStats.stringFromDate(Date())
        currentStreak  = StreakStats.currentStreak(activeDays: activeDays, today: todayStr)
        longest        = StreakStats.longestStreak(activeDays: activeDays)
    }

    private func formatted(_ n: Int) -> String {
        String(format: NSLocalizedString("%@ 回", comment: "Switch count with unit"),
               (countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"))
    }
}

// ─── About tab ────────────────────────────────────────────────────────────────

struct AboutSettingsView: View {

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon (the bundled AppIcon), shown via SwiftUI Image for clean
            // scaling — falls back to the generic app icon if none is bundled.
            Image(nsImage: NSApp.applicationIconImage
                  ?? NSImage(named: NSImage.applicationIconName)
                  ?? NSImage())
                .resizable()
                .frame(width: 72, height: 72)

            Text("ShakaPachi")
                .font(.title)
                .fontWeight(.bold)

            Text(String(format: NSLocalizedString("バージョン %@", comment: "App version label"), version))
                .foregroundColor(.secondary)

            // Copyright + author credit. The notice is a canonical, non-localized
            // form (kept in English even in the Japanese UI, per macOS convention);
            // the GitHub link credits the author.
            Text(verbatim: "© 2026 Masahiro Senda. All rights reserved.")
                .font(.caption)
                .foregroundColor(.secondary)

            Link("github.com/senkentarou",
                 destination: URL(string: "https://github.com/senkentarou")!)
                .font(.caption)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}


// MARK: - Notification for onboarding open

extension Notification.Name {
    /// Posted by the permissions tab when the user wants to see the onboarding window.
    static let showOnboardingWindow = Notification.Name("com.masahirosenda.shakapachi.showOnboardingWindow")
}
