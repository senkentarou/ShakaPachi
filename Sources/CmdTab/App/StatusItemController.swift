import AppKit

/// Manages the menu bar status item for CmdTab.
// StatusItemController is created from applicationDidFinishLaunching
// (@MainActor), so the init and all methods run on the main thread.
// We mark the class @MainActor so Swift 6 can verify this.
@MainActor
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupButton()
        setupMenu()
    }

    // MARK: - Private

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = makeStatusIcon()
        button.image?.isTemplate = true
    }

    /// Draws a simple 16x16 template image representing two overlapping window frames.
    private func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setStroke()

        // Back window frame
        let back = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 11, height: 11), xRadius: 2, yRadius: 2)
        back.lineWidth = 1.5
        back.stroke()

        // Front window frame (offset to simulate overlap)
        let front = NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 11, height: 11), xRadius: 2, yRadius: 2)
        front.lineWidth = 1.5
        NSColor.white.setFill()
        front.fill()
        front.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func setupMenu() {
        // "About CmdTab" item
        let aboutItem = NSMenuItem(
            title: "CmdTab について",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // "Quit" item with Cmd+Q shortcut
        let quitItem = NSMenuItem(
            title: "終了",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
