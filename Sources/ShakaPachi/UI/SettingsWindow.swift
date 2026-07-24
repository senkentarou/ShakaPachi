// SettingsWindow.swift
// Settings window: NSWindow + NSTabView with five tabs.
// SwiftUI is embedded via NSHostingView for the control-heavy tabs — the
// settings screen has no speed requirements so embedding SwiftUI is fine.
//
// Activation policy: switches to .regular on show and back to .accessory on
// close — but ONLY if the onboarding window is not also open.

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

    override init() {
        super.init()
    }

    // MARK: - Public

    func show() {
        NotificationCenter.default.post(
            name: .settingsWindowStateChanged, object: nil, userInfo: ["open": true])
        if let win = window {
            win.raiseToFront()
            return
        }

        // Bring app to front so the window is visible.
        WindowPresentationCoordinator.shared.windowDidOpen()

        let win = makeWindow()
        win.delegate = self
        win.contentViewController = makeSettingsRootController()
        win.setContentSize(NSSize(width: 560, height: 600))
        win.center()
        // Keep the settings window findable: float above other windows and
        // follow the user onto whichever Space is active, so it can't get lost
        // behind other apps once opened.
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.window = win

        win.raiseToFront()
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
        // Revert to .accessory only when no other presentation-managed window
        // is open. WindowPresentationCoordinator tracks the count so this window
        // and OnboardingWindow share a single revert decision.
        WindowPresentationCoordinator.shared.windowDidClose()
        window = nil
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
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
            let sized = view.frame(
                minWidth: 520, maxWidth: .infinity,
                minHeight: 360, maxHeight: .infinity)
            let item = NSTabViewItem(viewController: NSHostingController(rootView: sized))
            // NSTabViewItem.label is verbatim AppKit (no LocalizedStringKey), so
            // localize it explicitly. Keys live in Localizable.strings.
            item.label = NSLocalizedString(label, comment: "Settings tab label")
            tvc.addTabViewItem(item)
        }

        addTab("動作", BehaviorSettingsView())
        addTab("外観", AppearanceSettingsView())
        addTab("状態", StatusSettingsView())
        addTab("統計", StatsSettingsView())
        addTab("クレジット", AboutSettingsView())
        return tvc
    }
}

// MARK: - SwiftUI Settings Views

// NSHostingView hosts these SwiftUI views. They bind directly to the shared
// `Settings` ObservableObject (there is no separate mirror store): reads go
// through `@ObservedObject`, and every write assigns `Settings.shared.xxx`,
// which persists the value, posts `.settingsDidChange`, and fires
// `objectWillChange` so the view re-renders. One store, one write path.

// ─── Behavior tab ─────────────────────────────────────────────────────────────

struct BehaviorSettingsView: View {

    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker(
                    "言語",
                    selection: Binding(
                        get: { settings.appLanguage },
                        set: { Settings.shared.appLanguage = $0 }
                    )
                ) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)

                if settings.appLanguage != Settings.launchLanguage {
                    HStack {
                        Text("言語の変更は再起動後に反映されます。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("再起動") {
                            NotificationCenter.default.post(name: .relaunchApp, object: nil)
                        }
                    }
                }
            }

            Section {
                // Launch-at-login via SMAppService. The system status is the
                // source of truth; the Settings bool mirrors it for the UI.
                // Read the live SMAppService status directly (not the cached
                // mirror) so the toggle always reflects reality; the mirror is
                // healed on appear (see .onAppear below) and after every write.
                Toggle(
                    "ログイン時に起動",
                    isOn: Binding(
                        get: { LoginItemManager.isEnabled },
                        set: { newValue in
                            do {
                                try LoginItemManager.setEnabled(newValue)
                                Settings.shared.launchAtLogin = LoginItemManager.isEnabled
                            } catch {
                                // Registration failed — revert the mirror to the real
                                // status so the toggle reflects reality, and surface it.
                                Settings.shared.launchAtLogin = LoginItemManager.isEnabled
                                NSLog(
                                    "[ShakaPachi] Login item change failed: %@",
                                    error.localizedDescription)
                            }
                        }
                    ))

                // Modifier-only picker: the trigger key is fixed to Tab.
                // On set, both modifier and key are written so any previously-
                // stored .grave value is normalized to .tab on first save.
                Picker(
                    "トリガー",
                    selection: Binding(
                        get: { settings.triggerModifier },
                        set: { modifier in
                            Settings.shared.triggerModifier = modifier
                            Settings.shared.triggerKey = .tab
                        }
                    )
                ) {
                    ForEach(TriggerModifier.allCases, id: \.self) { modifier in
                        Text("\(modifier.displayName) + Tab").tag(modifier)
                    }
                }
                .pickerStyle(.menu)

                // .zOrder is intentionally excluded from the picker; the enum
                // case is kept for internal WindowStore use but is not exposed
                // as a user-selectable option.
                Picker(
                    "並び順",
                    selection: Binding(
                        get: { settings.sortMode },
                        set: { Settings.shared.sortMode = $0 }
                    )
                ) {
                    ForEach([SortMode.mru, .byApp, .byAppMRU], id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
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
            // The real login-item state lives in SMAppService, not the cached
            // bool; heal a stale mirror so the persisted value matches reality.
            // (Previously done in SettingsStore.init, before this view existed.)
            let realLaunchAtLogin = LoginItemManager.isEnabled
            if Settings.shared.launchAtLogin != realLaunchAtLogin {
                Settings.shared.launchAtLogin = realLaunchAtLogin
            }
        }
    }
}

// ─── Appearance tab ───────────────────────────────────────────────────────────

struct AppearanceSettingsView: View {

    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker(
                    "テーマ",
                    selection: Binding(
                        get: { settings.theme },
                        set: { Settings.shared.theme = $0 }
                    )
                ) {
                    ForEach(Theme.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.menu)

                Picker(
                    "アクセントカラー",
                    selection: Binding(
                        get: { settings.accentColor },
                        set: { Settings.shared.accentColor = $0 }
                    )
                ) {
                    ForEach(AccentColor.allCases, id: \.self) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 12) {
                    Text("アイコンサイズ")
                        .frame(width: 140, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { Double(settings.switcherIconSize) },
                            set: { settings.switcherIconSize = Int($0.rounded()) }
                        ),
                        in: 60...96
                    )
                    Text("\(settings.switcherIconSize)px")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }

                // Show live window preview below the title line.
                // Actual capture is gated on screen-recording permission at show time;
                // turning this off avoids any CGWindowListCreateImage call entirely.
                Toggle(
                    "ウィンドウプレビューを表示",
                    isOn: Binding(
                        get: { settings.showWindowPreview },
                        set: { Settings.shared.showWindowPreview = $0 }
                    ))

                HStack(spacing: 12) {
                    Text("ウィンドウプレビュー")
                        .frame(width: 140, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { Double(settings.windowPreviewWidth) },
                            set: { settings.windowPreviewWidth = Int($0.rounded()) }
                        ),
                        in: 240...480
                    )
                    Text("\(settings.windowPreviewWidth)px")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
                .disabled(!settings.showWindowPreview)
            }

            Section {
                AppearancePreviewView(
                    theme: settings.theme,
                    accent: settings.accentColor,
                    iconSize: settings.switcherIconSize,
                    windowPreviewWidth: settings.windowPreviewWidth,
                    showWindowPreview: settings.showWindowPreview,
                    totalCount: StatsStore.shared.totalCount)
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
                        Image(
                            systemName: accessibilityGranted
                                ? "checkmark.circle.fill" : "circle.dashed"
                        )
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
                                NSWorkspace.shared.open(PermissionManager.accessibilityURL)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    HStack {
                        Image(
                            systemName: screenRecordingGranted
                                ? "checkmark.circle.fill" : "circle.dashed"
                        )
                        .foregroundColor(screenRecordingGranted ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("画面収録")
                                .font(.body)
                            Text("ウィンドウ名の取得と、プレビュー表示に使います。録画やファイルへの保存はしません。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if screenRecordingGranted {
                            Text("許可済み").foregroundColor(.secondary).font(.caption)
                        } else {
                            Button("設定を開く") {
                                NSWorkspace.shared.open(PermissionManager.screenRecordingURL)
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
        let pm = PermissionManager()
        accessibilityGranted = pm.accessibilityStatus() == .granted
        screenRecordingGranted = pm.screenRecordingStatus() == .granted
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

                if statsEnabled {
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

                    // ── Activity (heatmap) ──
                    Section {
                        ContributionHeatmap(
                            dailyCounts: dailyCounts,
                            firstUseDate: firstUseDate
                        )
                        .padding(.vertical, 4)
                    } header: {
                        Text("アクティビティ")
                    }
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
                    Text("切替回数・日次履歴がすべてクリアされます。この操作は元に戻せません。")
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
        todayCount = StatsStore.shared.todayCount
        totalCount = StatsStore.shared.totalCount
        dailyCounts = StatsStore.shared.dailyCounts
        firstUseDate = StatsStore.shared.firstUseDate
    }

    private func formatted(_ n: Int) -> String {
        String(
            format: NSLocalizedString("%@ 回", comment: "Switch count with unit"),
            (countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"))
    }
}

// ─── About tab ────────────────────────────────────────────────────────────────

struct AboutSettingsView: View {

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    /// The bundled app icon, read straight from AppIcon.icns instead of
    /// `NSApp.applicationIconImage`. The latter is served from macOS's
    /// IconServices cache, which keeps returning a stale icon after the bundled
    /// icns changes (until the system icon cache is cleared), so a rebuilt icon
    /// would not show here. Reading the file directly always reflects the
    /// shipped icon; falls back to the cached/generic icon if the resource is
    /// missing.
    private var appIcon: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSApp.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon read directly from the bundled icns (see `appIcon`),
            // shown via SwiftUI Image for clean scaling.
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 72, height: 72)

            Text("ShakaPachi")
                .font(.title)
                .fontWeight(.bold)

            Text(String(format: NSLocalizedString("バージョン %@", comment: "App version label"), version))
                .foregroundColor(.secondary)

            // Copyright, license, and author credit. The notice is a canonical, non-localized
            // form (kept in English even in the Japanese UI, per macOS convention);
            // the GitHub link credits the author.
            Text(verbatim: "© 2026 Masahiro Senda · Licensed under GPL-3.0")
                .font(.caption)
                .foregroundColor(.secondary)

            Link(
                "github.com/senkentarou/ShakaPachi",
                destination: URL(string: "https://github.com/senkentarou/ShakaPachi")!
            )
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
    /// Posted when the user requests an app relaunch (e.g. to apply a language change).
    static let relaunchApp = Notification.Name("com.masahirosenda.shakapachi.relaunchApp")
}
