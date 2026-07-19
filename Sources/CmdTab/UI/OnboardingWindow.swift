// OnboardingWindow.swift
// Shown at launch when a required permission is missing.
// Switching to .regular activation policy while open lets the window come
// to front (§11.3 pattern); reverts to .accessory on close.

import AppKit

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let permissionManager: PermissionManager

    init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
        super.init()
    }

    // MARK: - Public

    func show() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        // Bring app to front so the window is visible (§11.3).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let win = makeWindow()
        win.delegate = self
        let content = makeContentView()
        win.contentView = content
        // The content rect passed to NSWindow.init is a placeholder; size the
        // window from the Auto Layout fitting size so wrapped labels never clip.
        win.setContentSize(content.fittingSize)
        win.center()
        win.makeKeyAndOrderFront(nil)
        self.window = win

        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Revert to accessory so we disappear from the app switcher.
        NSApp.setActivationPolicy(.accessory)
        window = nil
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "CmdTab — 権限の設定"
        win.isReleasedWhenClosed = false
        return win
    }

    // MARK: - Content view

    private func makeContentView() -> NSView {
        // NSWindow manages its contentView's frame directly (autoresizing),
        // so the container must keep translatesAutoresizingMaskIntoConstraints
        // enabled; only the inner stack uses Auto Layout.
        let container = NSView()

        // Title label
        let titleLabel = makeLabel(
            text: "CmdTab を使うには 2 つの権限が必要です",
            fontSize: 15,
            bold: true
        )

        // Accessibility section
        let accessibilityStatus = permissionManager.accessibilityStatus()
        let axSection = makePermissionSection(
            icon: "⌨️",
            name: "アクセシビリティ",
            reason: "キーボードイベントを捕捉してウィンドウを切り替えるために必要です。",
            status: accessibilityStatus,
            openAction: #selector(openAccessibilitySettings),
            requestAction: #selector(requestAccessibility)
        )

        // Screen Recording section
        let screenStatus = permissionManager.screenRecordingStatus()
        let srSection = makePermissionSection(
            icon: "🖥",
            name: "画面収録",
            reason: "ウィンドウのタイトル名を取得するために必要です。この権限がないとウィンドウ名が表示されません。",
            status: screenStatus,
            openAction: #selector(openScreenRecordingSettings),
            requestAction: #selector(requestScreenRecording)
        )

        // Explanation for restart requirement
        let restartNote = makeLabel(
            text: "※ 画面収録の権限はアプリを再起動しないと反映されません。",
            fontSize: 11,
            bold: false
        )
        restartNote.textColor = .secondaryLabelColor

        // Action buttons row
        let restartButton = makeButton(title: "再起動", action: #selector(relaunch))
        let laterButton   = makeButton(title: "後で",   action: #selector(closeLater))

        let buttonRow = NSStackView(views: [laterButton, restartButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually

        // Main stack
        let stack = NSStackView(views: [
            titleLabel,
            axSection,
            srSection,
            restartNote,
            buttonRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    // MARK: - Permission section factory

    private func makePermissionSection(
        icon: String,
        name: String,
        reason: String,
        status: PermissionStatus,
        openAction: Selector,
        requestAction: Selector
    ) -> NSView {
        let granted = status == .granted

        let iconLabel = makeLabel(text: icon, fontSize: 20, bold: false)

        let nameLabel = makeLabel(text: name, fontSize: 13, bold: true)

        let statusText = granted ? "✅ 許可済み" : "⚠️ 未許可"
        let statusLabel = makeLabel(text: statusText, fontSize: 12, bold: false)
        statusLabel.textColor = granted ? .systemGreen : .systemOrange

        let reasonLabel = makeLabel(text: reason, fontSize: 12, bold: false)
        reasonLabel.textColor = .secondaryLabelColor
        reasonLabel.lineBreakMode = .byWordWrapping

        let openButton = makeButton(title: "システム設定を開く", action: openAction)
        openButton.isEnabled = !granted

        let headerRow = NSStackView(views: [iconLabel, nameLabel, statusLabel])
        headerRow.orientation = .horizontal
        headerRow.spacing = 6

        // Plain stack instead of NSBox: NSBox does not derive its height from
        // an Auto Layout contentView, which collapsed the section and overlapped
        // neighbors (and its default title "Title" leaked into the UI).
        let section = NSStackView(views: [headerRow, reasonLabel, openButton])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6

        return section
    }

    // MARK: - Helpers

    private func makeLabel(text: String, fontSize: CGFloat, bold: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold
            ? NSFont.boldSystemFont(ofSize: fontSize)
            : NSFont.systemFont(ofSize: fontSize)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 400
        return label
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        return btn
    }

    // MARK: - Button actions

    @objc private func openAccessibilitySettings() {
        permissionManager.openAccessibilitySettings()
    }

    @objc private func requestAccessibility() {
        permissionManager.requestAccessibility()
    }

    @objc private func openScreenRecordingSettings() {
        permissionManager.openScreenRecordingSettings()
    }

    @objc private func requestScreenRecording() {
        permissionManager.requestScreenRecording()
    }

    @objc private func relaunch() {
        permissionManager.relaunchApp()
    }

    @objc private func closeLater() {
        window?.close()
    }
}
