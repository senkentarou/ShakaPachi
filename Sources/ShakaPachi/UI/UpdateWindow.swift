// UpdateWindow.swift
// Hosts the SwiftUI UpdateView in an NSWindow.
// Mirrors SettingsWindow.swift: NSObject + NSWindowDelegate, NSHostingController,
// WindowPresentationCoordinator for activation-policy management.

import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the Update window opens (`open: true`) or closes (`open: false`)
    /// so the menu-bar icon can show its blue "info" state, mirroring
    /// settingsWindowStateChanged.
    static let updateWindowStateChanged =
        Notification.Name("com.masahirosenda.shakapachi.updateWindowStateChanged")
}

// MARK: - UpdateWindow

@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let viewModel = UpdateViewModel()

    // Fixed window size: sized for the richest state (update available with
    // release notes). Simpler states center their content within the same frame
    // so the window never resizes as the status changes.
    private static let windowSize = NSSize(width: 460, height: 520)

    // MARK: - Public

    func show() {
        NotificationCenter.default.post(
            name: .updateWindowStateChanged, object: nil, userInfo: ["open": true])
        if let win = window {
            win.raiseToFront()
            return
        }

        WindowPresentationCoordinator.shared.windowDidOpen()

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
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
        win.setContentSize(Self.windowSize)

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
        NotificationCenter.default.post(
            name: .updateWindowStateChanged, object: nil, userInfo: ["open": false])
        WindowPresentationCoordinator.shared.windowDidClose()
        window = nil
    }
}

// MARK: - UpdateViewModel

final class UpdateViewModel: ObservableObject {
    @Published var status: UpdateManager.Status = .idle
}

// MARK: - UpdateView

/// A macOS-native update dialog. Every status shares one frame: an identity
/// header (app icon + name + a one-line status subtitle) on top, then a body
/// that fills the rest with the state-specific content and a bottom action bar.
struct UpdateView: View {

    @ObservedObject var viewModel: UpdateViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 460, height: 520)
    }

    // MARK: - Header

    /// App identity + one-line status, shown in every state so the window is
    /// always recognisable and never anonymous.
    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(appName)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(statusSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var statusSubtitle: String {
        switch viewModel.status {
        case .idle, .checking:
            return NSLocalizedString("アップデートを確認しています…", comment: "Update header subtitle: checking")
        case .upToDate:
            return NSLocalizedString("お使いのバージョンは最新です", comment: "Update header subtitle: up to date")
        case .available:
            return NSLocalizedString("新しいバージョンがあります", comment: "Update header subtitle: update available")
        case .downloading:
            return NSLocalizedString("ダウンロードしています…", comment: "Update header subtitle: downloading")
        case .verifying:
            return NSLocalizedString("署名を検証しています…", comment: "Update header subtitle: verifying")
        case .installing:
            return NSLocalizedString("インストールしています…", comment: "Update header subtitle: installing")
        case .failed:
            return NSLocalizedString("エラーが発生しました", comment: "Update header subtitle: error")
        }
    }

    // MARK: - Body content

    @ViewBuilder
    private var content: some View {
        switch viewModel.status {
        case .idle, .checking:
            centeredStatus(caption: nil, closable: true)
        case .upToDate:
            upToDateContent
        case .available(let release):
            availableContent(release: release)
        case .downloading(let progress):
            downloadingContent(progress: progress)
        case .verifying:
            centeredStatus(caption: nil, closable: false)
        case .installing:
            centeredStatus(
                caption: NSLocalizedString(
                    "まもなくアプリが再起動します", comment: "Installing caption: app will restart"),
                closable: false)
        case .failed(let message):
            failedContent(message: message)
        }
    }

    /// Update available: version transition, release notes in a subtle inset, and
    /// a bottom action bar (skip on the left as a subtle link; Later + the primary
    /// Install button on the right, following macOS convention).
    private func availableContent(release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Compact version transition.
            HStack(spacing: 8) {
                Text(UpdateManager.shared.currentVersion.description)
                    .foregroundColor(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(release.version.description)
                    .fontWeight(.semibold)
            }
            .font(.callout)

            // Release-notes section caption with a subtle "open on GitHub" link.
            HStack {
                Text(NSLocalizedString("リリースノート", comment: "Section caption: release notes"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Button(NSLocalizedString("GitHub で開く", comment: "Link: open release page on GitHub")) {
                    UpdateManager.shared.openReleasePage()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            // Release notes (markdown-rendered) in a subtle inset that grows to fill.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(noteBlocks(releaseNotesText(release))) { block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            // Bottom action bar: Later + the primary Install button (macOS convention).
            HStack(spacing: 10) {
                Spacer()
                Button(NSLocalizedString("後で", comment: "Button: remind later")) {
                    onClose()
                }
                Button(
                    NSLocalizedString(
                        "インストールして再起動", comment: "Button: install and relaunch")
                ) {
                    UpdateManager.shared.downloadAndInstall()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    /// Up to date: a reassuring checkmark, the current version, and a close button.
    private var upToDateContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.green)
            Text(
                String(
                    format: NSLocalizedString(
                        "バージョン %@ をお使いです", comment: "Up to date: current version"),
                    UpdateManager.shared.currentVersion.description)
            )
            .font(.callout)
            .foregroundColor(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button(NSLocalizedString("閉じる", comment: "Button: close")) { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    /// Downloading: a linear progress bar plus a percentage caption.
    private func downloadingContent(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text(
                String(
                    format: NSLocalizedString("%d%% 完了", comment: "Download progress percent"),
                    Int(progress * 100))
            )
            .font(.caption)
            .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    /// Shared centered spinner for the transient checking / verifying / installing
    /// states. `caption` is optional extra text; `closable` adds a close button.
    private func centeredStatus(caption: String?, closable: Bool) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if closable {
                HStack {
                    Spacer()
                    Button(NSLocalizedString("閉じる", comment: "Button: close")) { onClose() }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    /// Failure: an icon, the error message, and retry / close actions.
    private func failedContent(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button(NSLocalizedString("閉じる", comment: "Button: close")) { onClose() }
                Button(NSLocalizedString("再試行", comment: "Button: retry update check")) {
                    UpdateManager.shared.checkForUpdates(userInitiated: true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    // MARK: - Helpers

    /// The app's display name, read from the bundle (falls back to the product name).
    private var appName: String {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "ShakaPachi"
    }

    /// Release notes with a redundant leading "ShakaPachi vX.Y.Z" title (and any
    /// following dash/separator) stripped — the header and version row already
    /// convey the app name and version, so repeating them in the notes is noise.
    private func releaseNotesText(_ release: ReleaseInfo) -> String {
        let trimmed = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return NSLocalizedString(
                "（リリースノートはありません）", comment: "Placeholder when a release has no notes")
        }
        let prefix = "\(appName) v\(release.version.description)"
        guard trimmed.hasPrefix(prefix) else { return trimmed }
        let separators = CharacterSet(charactersIn: " -—–ー・:：\t")
        let remainder = trimmed.dropFirst(prefix.count).drop { ch in
            ch.unicodeScalars.allSatisfy { separators.contains($0) }
        }
        let result = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? trimmed : result
    }

    // MARK: - Release-notes markdown

    /// One rendered line of the release notes. We render markdown ourselves
    /// (line by line) rather than pull in a dependency: Foundation's
    /// AttributedString handles the inline syntax (**bold**, links, `code`),
    /// and we recognise `#` headings and `-`/`*` bullets as block elements.
    private struct NoteBlock: Identifiable {
        enum Kind { case heading, bullet, paragraph, blank }
        let id: Int
        let kind: Kind
        let text: AttributedString
    }

    private func noteBlocks(_ notes: String) -> [NoteBlock] {
        notes.components(separatedBy: "\n").enumerated().map { index, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                return NoteBlock(id: index, kind: .blank, text: AttributedString())
            }
            if let hashes = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                return NoteBlock(
                    id: index, kind: .heading,
                    text: inlineMarkdown(String(line[hashes.upperBound...])))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                return NoteBlock(
                    id: index, kind: .bullet, text: inlineMarkdown(String(line.dropFirst(2))))
            }
            return NoteBlock(id: index, kind: .paragraph, text: inlineMarkdown(line))
        }
    }

    /// Parse a single line's inline markdown (bold/italic/links/code), preserving
    /// whitespace and never interpreting block syntax (we handle that ourselves).
    private func inlineMarkdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(string)
    }

    @ViewBuilder
    private func blockView(_ block: NoteBlock) -> some View {
        switch block.kind {
        case .heading:
            Text(block.text)
                .font(.callout)
                .fontWeight(.bold)
                .padding(.top, 6)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundColor(.secondary)
                Text(block.text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph:
            Text(block.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .blank:
            Color.clear.frame(height: 2)
        }
    }
}
