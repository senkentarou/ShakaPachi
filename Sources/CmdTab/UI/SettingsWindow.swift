// SettingsWindow.swift
// Settings window (§11.3): NSWindow + NSTabView with four tabs.
// SwiftUI is embedded via NSHostingView for the control-heavy tabs (§11.3
// explicitly permits this: "設定画面には速度要件がないため SwiftUI を埋め込んでもよい").
//
// Activation policy: switches to .regular on show and back to .accessory on
// close — but ONLY if the onboarding window is not also open (§11.3 note).

import AppKit
import SwiftUI

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
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // §11.3: bring app to front so the window is visible.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let win = makeWindow()
        win.delegate = self
        win.contentView = makeContentView()
        win.center()
        win.makeKeyAndOrderFront(nil)
        self.window = win

        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "CmdTab 設定"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 400, height: 300)
        return win
    }

    private func makeContentView() -> NSView {
        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false

        // Tab 1: 一般
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "一般"
        let generalHosting = NSHostingView(rootView: GeneralSettingsView())
        generalTab.view = generalHosting
        tabView.addTabViewItem(generalTab)

        // Tab 2: 外観
        let appearanceTab = NSTabViewItem(identifier: "appearance")
        appearanceTab.label = "外観"
        let appearanceHosting = NSHostingView(rootView: AppearanceSettingsView())
        appearanceTab.view = appearanceHosting
        tabView.addTabViewItem(appearanceTab)

        // Tab 3: 除外
        let exclusionTab = NSTabViewItem(identifier: "exclusion")
        exclusionTab.label = "除外"
        let exclusionHosting = NSHostingView(rootView: ExclusionSettingsView())
        exclusionTab.view = exclusionHosting
        tabView.addTabViewItem(exclusionTab)

        // Tab 4: 権限
        let permissionsTab = NSTabViewItem(identifier: "permissions")
        permissionsTab.label = "権限"
        let permissionsHosting = NSHostingView(rootView: PermissionsSettingsView())
        permissionsTab.view = permissionsHosting
        tabView.addTabViewItem(permissionsTab)

        let container = NSView()
        container.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: container.topAnchor),
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
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

    private var observer: (any NSObjectProtocol)?

    init() {
        let s = Settings.shared
        triggerModifier  = s.triggerModifier
        triggerKey       = s.triggerKey
        showDelayMs      = s.showDelayMs
        currentSpaceOnly = s.currentSpaceOnly
        sortMode         = s.sortMode
        excludedBundleIDs = s.excludedBundleIDs
        theme            = s.theme
        launchAtLogin    = s.launchAtLogin

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
        if theme            != s.theme            { theme            = s.theme            }
        if launchAtLogin    != s.launchAtLogin    { launchAtLogin    = s.launchAtLogin    }
    }
}

// ─── 一般 tab ─────────────────────────────────────────────────────────────────

struct GeneralSettingsView: View {

    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("トリガー修飾キー", selection: Binding(
                    get: { store.triggerModifier },
                    set: { Settings.shared.triggerModifier = $0 }
                )) {
                    ForEach(TriggerModifier.allCases, id: \.self) { mod in
                        Text(mod.displayName).tag(mod)
                    }
                }
                .pickerStyle(.menu)

                Picker("トリガーキー", selection: Binding(
                    get: { store.triggerKey },
                    set: { Settings.shared.triggerKey = $0 }
                )) {
                    ForEach(TriggerKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("トリガー")
            }

            Section {
                Toggle("現在のスペースのみ", isOn: Binding(
                    get: { store.currentSpaceOnly },
                    set: { Settings.shared.currentSpaceOnly = $0 }
                ))

                Picker("並び順", selection: Binding(
                    get: { store.sortMode },
                    set: { Settings.shared.sortMode = $0 }
                )) {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("表示遅延 (ms)")
                    Spacer()
                    TextField("", value: Binding(
                        get: { store.showDelayMs },
                        set: { Settings.shared.showDelayMs = $0 }
                    ), format: .number)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("動作")
            }

            Section {
                // launchAtLogin is model-only until Step 13 (SMAppService).
                // Show it disabled with a note so users can see it's coming.
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { _ in /* Step 13: SMAppService.mainApp.register() */ }
                ))
                .disabled(true)
                Text("ログイン時起動は次のアップデートで有効になります。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("システム")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// ─── 外観 tab ─────────────────────────────────────────────────────────────────

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
            } header: {
                Text("外観")
            }

            // maxRows and panelWidth are omitted from the UI because the
            // horizontal auto-sizing tile layout (Step 7) derives its dimensions
            // from the tile count automatically. These settings are advisory in
            // v1. A note is shown so users understand the omission.
            Section {
                Text("パネルの幅と最大行数は水平タイルレイアウトでは自動調整されます。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("レイアウト (v1: 自動調整)")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// ─── 除外 tab ─────────────────────────────────────────────────────────────────

struct ExclusionSettingsView: View {

    @ObservedObject private var store = SettingsStore.shared
    @State private var newBundleID: String = ""
    @State private var selectedBundleID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("除外アプリ")
                .font(.headline)
                .padding(.top, 16)
                .padding(.horizontal)

            Text("リストに追加されたアプリのウィンドウは切替対象から除外されます。")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            List(selection: $selectedBundleID) {
                ForEach(store.excludedBundleIDs, id: \.self) { bundleID in
                    Text(bundleID)
                        .font(.system(.body, design: .monospaced))
                        .tag(bundleID)
                }
            }
            .frame(minHeight: 160)
            .border(Color(NSColor.separatorColor))
            .padding(.horizontal)

            HStack(spacing: 8) {
                // Quick picker: running apps
                Picker("実行中のアプリ", selection: $newBundleID) {
                    Text("選択…").tag("")
                    ForEach(runningAppBundleIDs(), id: \.self) { bid in
                        Text(bid).tag(bid)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                TextField("または Bundle ID を入力", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)

                Button("追加") {
                    let trimmed = newBundleID.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty,
                          !store.excludedBundleIDs.contains(trimmed) else { return }
                    var ids = Settings.shared.excludedBundleIDs
                    ids.append(trimmed)
                    Settings.shared.excludedBundleIDs = ids
                    newBundleID = ""
                }
                .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)

            HStack {
                Button("削除") {
                    guard let sel = selectedBundleID else { return }
                    var ids = Settings.shared.excludedBundleIDs
                    ids.removeAll { $0 == sel }
                    Settings.shared.excludedBundleIDs = ids
                    selectedBundleID = nil
                }
                .disabled(selectedBundleID == nil)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
    }

    /// Returns bundle IDs of currently running regular-activationPolicy apps,
    /// excluding CmdTab itself and those already in the exclusion list.
    private func runningAppBundleIDs() -> [String] {
        let excluded = Set(store.excludedBundleIDs)
        let selfID = Bundle.main.bundleIdentifier ?? ""
        return NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier }
            .filter { $0 != selfID && !excluded.contains($0) }
            .sorted()
    }
}

// ─── 権限 tab ─────────────────────────────────────────────────────────────────

struct PermissionsSettingsView: View {

    @State private var accessibilityGranted: Bool = false
    @State private var screenRecordingGranted: Bool = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
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

            Section {
                Button("オンボーディング画面を開く") {
                    // Post a notification that AppDelegate can observe to open
                    // the onboarding window. Using NotificationCenter avoids a
                    // direct dependency from this SwiftUI view to AppDelegate.
                    NotificationCenter.default.post(
                        name: .showOnboardingWindow, object: nil)
                }
            } header: {
                Text("サポート")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshPermissions() }
        .onReceive(timer) { _ in refreshPermissions() }
    }

    private func refreshPermissions() {
        accessibilityGranted   = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }
}

// MARK: - Notification for onboarding open

extension Notification.Name {
    /// Posted by the permissions tab when the user wants to see the onboarding window.
    static let showOnboardingWindow = Notification.Name("com.masahirosenda.cmdtab.showOnboardingWindow")
}
