// UpdateWindow.swift
// Hosts the SwiftUI UpdateView in an NSWindow.
// Mirrors SettingsWindow.swift: NSObject + NSWindowDelegate, NSHostingController,
// WindowPresentationCoordinator for activation-policy management.

import AppKit
import SwiftUI

// MARK: - UpdateWindow

@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let viewModel = UpdateViewModel()

    // MARK: - Public

    func show() {
        if let win = window {
            win.raiseToFront()
            return
        }

        WindowPresentationCoordinator.shared.windowDidOpen()

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = NSLocalizedString("アップデート", comment: "Update window title")
        win.isReleasedWhenClosed = false
        win.center()
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.delegate = self

        let closeAction: () -> Void = { [weak self] in self?.close() }
        let hostingController = NSHostingController(
            rootView: UpdateView(viewModel: viewModel, onClose: closeAction))
        win.contentViewController = hostingController

        self.window = win
        win.raiseToFront()
    }

    func close() {
        window?.close()
    }

    /// Forward a new status into the view model so the SwiftUI view re-renders.
    /// AppDelegate calls this whenever UpdateManager.onStatusChange fires.
    func apply(_ status: UpdateManager.Status) {
        viewModel.status = status
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        WindowPresentationCoordinator.shared.windowDidClose()
        window = nil
    }
}

// MARK: - UpdateViewModel

final class UpdateViewModel: ObservableObject {
    @Published var status: UpdateManager.Status = .idle
}

// MARK: - UpdateView

struct UpdateView: View {

    @ObservedObject var viewModel: UpdateViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            appHeader
            Divider()
            contentView
        }
        .frame(width: 440, alignment: .center)
        .padding(24)
    }

    /// App identity header (icon + name) so the window is recognisable as
    /// ShakaPachi in every status, not an anonymous dialog.
    private var appHeader: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            Text(appName)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
        }
    }

    /// The app's display name, read from the bundle (falls back to the product name).
    private var appName: String {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "ShakaPachi"
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.status {
        case .idle, .checking:
            checkingView

        case .upToDate:
            upToDateView

        case .available(let release):
            availableView(release: release)

        case .downloading(let progress):
            downloadingView(progress: progress)

        case .verifying:
            verifyingView

        case .installing:
            installingView

        case .failed(let message):
            failedView(message: message)
        }
    }

    // MARK: - Status views

    private var checkingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.top, 8)
            Text(NSLocalizedString("アップデートを確認中…", comment: "Update status: checking"))
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var upToDateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text(
                String(
                    format: NSLocalizedString(
                        "最新です (%@)", comment: "Update status: up to date, showing current version"),
                    UpdateManager.shared.currentVersion.description)
            )
            .font(.headline)
            Button(NSLocalizedString("閉じる", comment: "Button: close")) {
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    private func availableView(release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Version transition heading
            Text(
                String(
                    format: NSLocalizedString(
                        "現在のバージョン %@ → 新しいバージョン %@",
                        comment: "Update available: current and new version"),
                    UpdateManager.shared.currentVersion.description,
                    release.version.description)
            )
            .font(.subheadline)
            .foregroundColor(.secondary)

            // Release name (if non-empty)
            if let name = release.name, !name.isEmpty {
                Text(name)
                    .font(.title3)
                    .fontWeight(.semibold)
            }

            // Release notes in a scrollable area
            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
            }

            // Action buttons
            VStack(spacing: 8) {
                Button(
                    NSLocalizedString(
                        "インストールして再起動",
                        comment: "Button: download and install update, then restart")
                ) {
                    UpdateManager.shared.downloadAndInstall()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                HStack(spacing: 12) {
                    Button(
                        NSLocalizedString(
                            "リリースノートを開く",
                            comment: "Button: open release page in browser")
                    ) {
                        UpdateManager.shared.openReleasePage()
                    }

                    Spacer()

                    Button(
                        NSLocalizedString(
                            "このバージョンをスキップ",
                            comment: "Button: skip this version")
                    ) {
                        UpdateManager.shared.skipAvailableVersion()
                        onClose()
                    }

                    Button(NSLocalizedString("後で", comment: "Button: remind later")) {
                        onClose()
                    }
                }
            }
        }
    }

    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text(
                String(
                    format: NSLocalizedString(
                        "ダウンロード中… %d%%",
                        comment: "Update status: downloading, with percent"),
                    Int(progress * 100))
            )
            .font(.body)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var verifyingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.top, 8)
            Text(NSLocalizedString("署名を検証中…", comment: "Update status: verifying signature"))
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var installingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.top, 8)
            Text(
                NSLocalizedString(
                    "インストール中… まもなく再起動します",
                    comment: "Update status: installing, restarting soon")
            )
            .font(.body)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button(NSLocalizedString("再試行", comment: "Button: retry update check")) {
                    UpdateManager.shared.checkForUpdates(userInitiated: true)
                }
                .keyboardShortcut(.defaultAction)

                Button(NSLocalizedString("閉じる", comment: "Button: close")) {
                    onClose()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }
}
