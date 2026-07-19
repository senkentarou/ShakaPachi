// SwitcherListView.swift
// §7.3 NSTableView-based list of SwitcherItems for the switcher panel.
// Uses fixed row height (28pt) and reused NSTableCellViews.
// §7.5: selection changes redraw only the two affected rows (old + new).

import AppKit

// MARK: - SwitcherItem

/// Lightweight value type carrying display data for one row.
/// Step 7 uses dummy data; Step 8 wires this to real WindowInfo.
public struct SwitcherItem: Equatable {
    public let icon: NSImage?
    public let title: String

    public init(icon: NSImage?, title: String) {
        self.icon = icon
        self.title = title
    }
}

// MARK: - Layout constants shared with SwitcherPanel

/// Shared layout constants used by both the list view and the panel.
public enum SwitcherLayout {
    /// Fixed row height (§7.4).
    public static let rowHeight: CGFloat = 28
    /// Panel width (§7.4).
    public static let panelWidth: CGFloat = 480
    /// Maximum visible rows before scrolling kicks in (§7.4).
    public static let maxRows: Int = 20
    /// Vertical padding above and below the row area.
    public static let verticalPadding: CGFloat = 8

    /// Compute the total panel height for a given item count (§7.4).
    /// Pure function — unit-testable.
    public static func panelHeight(itemCount: Int) -> CGFloat {
        let visibleRows = min(itemCount, maxRows)
        return CGFloat(visibleRows) * rowHeight + verticalPadding * 2
    }

    /// Advance the selection index by +1 with wrap-around (§6.2).
    /// Pure function — unit-testable.
    public static func advanceIndex(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current + 1) % count
    }

    /// Return the two row indices that need redrawing when selection changes.
    /// Pure function — unit-testable.
    public static func rowsToRedraw(old: Int, new: Int) -> IndexSet {
        var set = IndexSet()
        set.insert(old)
        if new != old { set.insert(new) }
        return set
    }
}

// MARK: - Dummy data

/// Eight hardcoded items used in Step 7 (replaced by real data in Step 8).
public let dummySwitcherItems: [SwitcherItem] = {
    // Use SF Symbols available on macOS 13+ for the icons.
    func sfImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
    return [
        SwitcherItem(icon: sfImage("safari"),               title: "Safari — GitHub"),
        SwitcherItem(icon: sfImage("terminal"),             title: "ターミナル — ~/work/cmdtab"),
        SwitcherItem(icon: sfImage("envelope"),             title: "メール — 受信トレイ (3)"),
        SwitcherItem(icon: sfImage("music.note"),           title: "ミュージック — 再生中"),
        SwitcherItem(icon: sfImage("doc.text"),             title: "テキストエディット — 仕様書.txt"),
        SwitcherItem(icon: sfImage("folder"),               title: "Finder — ダウンロード"),
        SwitcherItem(icon: sfImage("calendar"),             title: "カレンダー — 今日"),
        SwitcherItem(icon: sfImage("gearshape"),            title: "システム設定 — 一般"),
    ]
}()

// MARK: - SwitcherListView

/// NSTableView wrapped in a scroll view for displaying switcher rows.
/// The outer scroll view is sized to exactly fit up to maxRows rows; the
/// table itself is transparent so the HUD blur behind shows through.
final class SwitcherListView: NSView {

    // MARK: Subviews

    private let scrollView: NSScrollView
    private let tableView: NSTableView

    // MARK: State

    private var items: [SwitcherItem] = []
    private(set) var selectedIndex: Int = 0

    // MARK: Cell reuse identifier

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("SwitcherCell")

    // MARK: Init

    override init(frame: NSRect) {
        // Build the table view first.
        let tv = NSTableView(frame: NSRect(x: 0, y: 0,
                                           width: SwitcherLayout.panelWidth,
                                           height: 0))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        column.width = SwitcherLayout.panelWidth
        tv.addTableColumn(column)
        tv.headerView = nil                    // headerless
        tv.rowHeight = SwitcherLayout.rowHeight
        tv.usesAutomaticRowHeights = false     // §7.3: fixed height mandatory
        tv.backgroundColor = .clear            // HUD blur shows through
        tv.selectionHighlightStyle = .regular  // selection highlight on the row
        tv.allowsMultipleSelection = false
        tv.allowsEmptySelection = false
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tv.focusRingType = .none

        // Wrap in a non-scrolling scroll view (scroll view handles overflow).
        let sv = NSScrollView(frame: frame)
        sv.documentView = tv
        sv.drawsBackground = false
        sv.backgroundColor = .clear
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.hasHorizontalScroller = false
        sv.borderType = .noBorder

        self.tableView = tv
        self.scrollView = sv

        super.init(frame: frame)

        addSubview(sv)
        tv.dataSource = self
        tv.delegate = self

        // Auto Layout: fill the entire SwitcherListView.
        sv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.topAnchor.constraint(equalTo: topAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: Public API

    /// Replace the full item list and select the given index.
    /// Reloads all data (called once per panel show; §7.5 optimisation is for
    /// subsequent selection moves, not the initial load).
    func setItems(_ items: [SwitcherItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = clamp(selectedIndex, count: items.count)
        tableView.reloadData()
        applySelectionToTableView()
        scrollToSelected()
    }

    /// Move the selection highlight without reloading the whole table (§7.5).
    func moveSelection(to newIndex: Int) {
        let old = selectedIndex
        let new = clamp(newIndex, count: items.count)
        guard new != old else { return }

        selectedIndex = new
        // Redraw only the two affected rows.
        let dirty = SwitcherLayout.rowsToRedraw(old: old, new: new)
        tableView.reloadData(forRowIndexes: dirty,
                             columnIndexes: IndexSet(integer: 0))
        applySelectionToTableView()
        scrollToSelected()
    }

    // MARK: Private helpers

    private func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(index, count - 1))
    }

    private func applySelectionToTableView() {
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex),
                                   byExtendingSelection: false)
    }

    private func scrollToSelected() {
        tableView.scrollRowToVisible(selectedIndex)
    }
}

// MARK: - NSTableViewDataSource

extension SwitcherListView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

// MARK: - NSTableViewDelegate

extension SwitcherListView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        // Reuse or create a cell view.
        var cell = tableView.makeView(
            withIdentifier: SwitcherListView.cellIdentifier,
            owner: self
        ) as? SwitcherCellView

        if cell == nil {
            cell = SwitcherCellView(
                identifier: SwitcherListView.cellIdentifier
            )
        }

        cell?.configure(with: item)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        SwitcherLayout.rowHeight
    }

    // Prevent user-initiated selection changes (selection is managed in code).
    func tableView(_ tableView: NSTableView,
                   shouldSelectRow row: Int) -> Bool { false }
}

// MARK: - SwitcherCellView

/// Minimal cell: 20×20 icon + title label.
/// Uses a flat Auto Layout setup (no nesting) to keep measurement overhead low.
final class SwitcherCellView: NSTableCellView {

    private let iconView: NSImageView
    private let titleField: NSTextField

    init(identifier: NSUserInterfaceItemIdentifier) {
        iconView = NSImageView(frame: .zero)
        titleField = NSTextField(labelWithString: "")

        super.init(frame: .zero)
        self.identifier = identifier

        // Icon: 20×20, centred vertically in the 28pt row.
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        // Title: single-line, middle truncation (§7.4).
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.cell?.lineBreakMode = .byTruncatingMiddle
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.drawsBackground = false
        titleField.isBordered = false
        titleField.font = NSFont.systemFont(ofSize: 13)
        titleField.textColor = .labelColor

        addSubview(iconView)
        addSubview(titleField)
        self.imageView = iconView
        self.textField = titleField

        let padding: CGFloat = 8
        let iconSize: CGFloat = 20
        let iconTitleGap: CGFloat = 8

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),

            titleField.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: iconTitleGap),
            titleField.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -padding),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(with item: SwitcherItem) {
        iconView.image = item.icon
        titleField.stringValue = item.title
    }
}
