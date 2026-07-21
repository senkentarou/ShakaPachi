// OnboardingWindow.swift
// Permission onboarding: app-icon header, one rounded card per permission
// with live status, and a single action per card.
// Switching to .regular activation policy while open lets the window come
// to front (§11.3 pattern); reverts to .accessory on close.
// TCC grants happen in System Settings, outside this process, so the window
// polls permission status once per second while open instead of requiring
// the user to restart just to see the new state.

import AppKit

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let permissionManager: PermissionManager
    private let onStatusChange: (() -> Void)?
    private var pollTimer: Timer?

    private var accessibilityCard: PermissionCardView?
    private var screenRecordingCard: PermissionCardView?

    init(permissionManager: PermissionManager, onStatusChange: (() -> Void)? = nil) {
        self.permissionManager = permissionManager
        self.onStatusChange = onStatusChange
        super.init()
    }

    // MARK: - Public

    /// Returns true when the onboarding window is currently displayed.
    /// SettingsWindow uses this to decide whether to revert the activation policy.
    var isWindowOpen: Bool { window != nil }

    func show() {
        if let win = window {
            // Re-triggering must reliably surface the window: activating and
            // ordering front regardless is what makes it appear when the app is
            // not frontmost or the window sits on another Space (otherwise the
            // button looks like it did nothing).
            raiseToFront(win)
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
        // Keep the onboarding window findable: float above other windows and
        // follow the user onto whichever Space is active.
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.window = win

        raiseToFront(win)
        startPolling()
    }

    /// Bring the onboarding window to the absolute front on the active Space.
    private func raiseToFront(_ win: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        // Revert to accessory so we disappear from the app switcher.
        NSApp.setActivationPolicy(.accessory)
        window = nil
    }

    // MARK: - Live status polling

    private func startPolling() {
        refreshStatuses()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            // Timers scheduled on the main run loop fire on the main thread.
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.refreshStatuses()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refreshStatuses() {
        accessibilityCard?.setGranted(permissionManager.accessibilityStatus() == .granted)
        screenRecordingCard?.setGranted(permissionManager.screenRecordingStatus() == .granted)
        onStatusChange?()
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "ShakaPachi"
        win.isReleasedWhenClosed = false
        return win
    }

    // MARK: - Content view

    private static let contentWidth: CGFloat = 440

    private func makeContentView() -> NSView {
        let header = makeHeader()

        let axCard = PermissionCardView(
            name: "アクセシビリティ",
            benefit: "切替キーの捕捉と、選んだウィンドウの前面化に使います。",
            target: self,
            action: #selector(grantAccessibility)
        )
        accessibilityCard = axCard

        let srCard = PermissionCardView(
            name: "画面収録",
            benefit: "ウィンドウ名の取得だけに使います。画面の撮影・保存はしません。",
            target: self,
            action: #selector(grantScreenRecording)
        )
        screenRecordingCard = srCard

        let footer = makeFooter()

        let stack = NSStackView(views: [header, axCard, srCard, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(28, after: header)
        stack.setCustomSpacing(24, after: srCard)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // NSWindow manages its contentView's frame directly (autoresizing),
        // so the container must keep translatesAutoresizingMaskIntoConstraints
        // enabled; only the inner stack uses Auto Layout.
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            axCard.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            srCard.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            footer.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])

        return container
    }

    private func makeHeader() -> NSView {
        let iconView = NSImageView(image: Self.makeAppIconTile())
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])

        let title = NSTextField(labelWithString: "ShakaPachi")
        title.font = .boldSystemFont(ofSize: 26)

        let subtitle = NSTextField(labelWithString: "ウィンドウを切り替えるには 2 つの権限が必要です。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let header = NSStackView(views: [iconView, textStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        return header
    }

    private func makeFooter() -> NSView {
        let helper = NSTextField(wrappingLabelWithString:
            "「設定を開く」を押して ShakaPachi をオンにしてください。この画面は自動で更新されます。画面収録は再起動後に反映されます。")
        helper.font = .systemFont(ofSize: 11)
        helper.textColor = .secondaryLabelColor
        helper.preferredMaxLayoutWidth = 240
        helper.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let restartButton = NSButton(title: "再起動", target: self, action: #selector(relaunch))
        restartButton.bezelStyle = .rounded
        restartButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [helper, restartButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        // Right-align the buttons: .fill lets the low-hugging helper label
        // stretch, pushing the buttons to the trailing edge.
        footer.distribution = .fill
        return footer
    }

    /// Draws a 64x64 rounded app-icon tile with the overlapping-windows glyph.
    /// Used until the bundle ships a real AppIcon asset.
    private static func makeAppIconTile() -> NSImage {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()

        let tileColor = NSColor.controlAccentColor
        let tile = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            xRadius: 14, yRadius: 14
        )
        tileColor.setFill()
        tile.fill()

        NSColor.white.setStroke()

        let back = NSBezierPath(
            roundedRect: NSRect(x: 13, y: 13, width: 26, height: 26),
            xRadius: 5, yRadius: 5
        )
        back.lineWidth = 4
        back.stroke()

        let front = NSBezierPath(
            roundedRect: NSRect(x: 25, y: 25, width: 26, height: 26),
            xRadius: 5, yRadius: 5
        )
        front.lineWidth = 4
        tileColor.setFill()
        front.fill()
        front.stroke()

        image.unlockFocus()
        return image
    }

    // MARK: - Button actions

    @objc private func grantAccessibility() {
        // Register the app in the Accessibility list (system prompt), then
        // open the pane so the user only has to flip the toggle.
        permissionManager.requestAccessibility()
        permissionManager.openAccessibilitySettings()
    }

    @objc private func grantScreenRecording() {
        permissionManager.requestScreenRecording()
        permissionManager.openScreenRecordingSettings()
    }

    @objc private func relaunch() {
        permissionManager.relaunchApp()
    }
}

// MARK: - Permission card

/// One rounded card per permission: status icon, name + benefit copy, and a
/// single action button that becomes a disabled "許可済み" once granted.
@MainActor
private final class PermissionCardView: NSView {

    private let statusIconView = NSImageView()
    private let actionButton: NSButton
    private var granted = false

    init(name: String, benefit: String, target: AnyObject, action: Selector) {
        actionButton = NSButton(title: "設定を開く", target: target, action: action)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10

        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusIconView.widthAnchor.constraint(equalToConstant: 28),
            statusIconView.heightAnchor.constraint(equalToConstant: 28),
        ])

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .boldSystemFont(ofSize: 15)

        let benefitLabel = NSTextField(wrappingLabelWithString: benefit)
        benefitLabel.font = .systemFont(ofSize: 12)
        benefitLabel.textColor = .secondaryLabelColor
        benefitLabel.preferredMaxLayoutWidth = 240

        let textStack = NSStackView(views: [nameLabel, benefitLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        actionButton.bezelStyle = .rounded

        let row = NSStackView(views: [statusIconView, textStack, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        // .fill (not the default .gravityAreas, which packs everything to the
        // leading edge) so the low-hugging text stack absorbs leftover width
        // and the action button sits flush right.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        // Explicit inset constants instead of NSStackView.edgeInsets so the
        // card padding is unambiguous.
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])

        setGranted(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func setGranted(_ newValue: Bool) {
        // Called every poll tick; skip the UI churn when nothing changed
        // (except the first call, which must populate the initial state).
        if statusIconView.image != nil && granted == newValue { return }
        granted = newValue

        if newValue {
            statusIconView.image = NSImage(
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: "許可済み"
            )?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
            statusIconView.contentTintColor = .systemGreen
            actionButton.title = "許可済み"
            actionButton.isEnabled = false
        } else {
            statusIconView.image = NSImage(
                systemSymbolName: "circle.dashed",
                accessibilityDescription: "未許可"
            )?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
            statusIconView.contentTintColor = .tertiaryLabelColor
            actionButton.title = "設定を開く"
            actionButton.isEnabled = true
        }
    }

    // Card fill uses a dynamic color resolved in updateLayer so it adapts
    // when the system appearance changes (layers don't do this on their own).
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.06).cgColor
    }
}
