import AppKit
import SwiftUI

struct ResultsTableView: NSViewRepresentable {
    @ObservedObject var store: AppStore

    func makeCoordinator() -> Coordinator {
        return Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.didDoubleClick(_:))
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .small
        table.style = .inset
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(makeColumn(id: .name, title: "Name", width: 240, minWidth: 140))
        table.addTableColumn(makeColumn(id: .path, title: "Path", width: 420, minWidth: 180))
        table.addTableColumn(makeColumn(id: .size, title: "Size", width: 90, minWidth: 70))
        table.addTableColumn(makeColumn(id: .modified, title: "Date Modified", width: 160, minWidth: 130))
        table.onReturn = {
            context.coordinator.openClickedOrSelected(table)
        }
        table.onCopy = {
            context.coordinator.store.copyPaths()
        }
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        context.coordinator.tableView = table
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.store = store
        guard let table = scrollView.documentView as? FileTableView else {
            return
        }
        if context.coordinator.displayedToken != store.resultToken {
            context.coordinator.displayedToken = store.resultToken
            context.coordinator.reload(table)
        }
        context.coordinator.syncSortDescriptors(table)
    }

    private func makeColumn(
        id: NSUserInterfaceItemIdentifier,
        title: String,
        width: CGFloat,
        minWidth: CGFloat
    ) -> NSTableColumn {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
        return column
    }
}

final class FileTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onCopy: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.command) {
                (delegate as? Coordinator)?.revealClickedOrSelected(self)
            } else {
                onReturn?()
            }
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return selectedRowIndexes.count > 0
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// Virtual table over the store's result ids: rows are materialized only when
/// AppKit asks for visible cells.
final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
    var store: AppStore
    weak var tableView: FileTableView?
    var displayedToken: UInt64 = UInt64.max
    private var isApplyingSelection = false
    private var rowCache: [Int: FileRecord] = [:]
    /// Paths the user selected; the selection follows these files across
    /// refreshes because row numbers and entry ids both change.
    private var selectedPaths: [String] = []
    private var selectedAll = false

    init(store: AppStore) {
        self.store = store
    }

    func reload(_ table: NSTableView) {
        let anchor = store.resultIsRefresh ? scrollAnchor(table) : nil
        rowCache.removeAll(keepingCapacity: true)
        isApplyingSelection = true
        table.reloadData()
        if selectedAll && store.resultIsRefresh {
            table.selectAll(nil)
        } else {
            selectedAll = false
            table.selectRowIndexes(store.rows(forPaths: selectedPaths), byExtendingSelection: false)
        }
        if let anchor {
            restoreScrollAnchor(anchor, table: table)
        } else if !store.resultIsRefresh {
            table.scrollRowToVisible(0)
        }
        isApplyingSelection = false
        store.selectedRows = table.selectedRowIndexes
    }

    /// The first visible selected row (or the top visible row) and its offset
    /// from the top of the viewport, so live inserts above it don't move the
    /// rows under the pointer.
    private func scrollAnchor(_ table: NSTableView) -> ScrollAnchor? {
        let visible = table.visibleRect
        let range = table.rows(in: visible)
        if range.length <= 0 {
            return nil
        }
        let row = table.selectedRowIndexes.first(where: { NSLocationInRange($0, range) }) ?? range.location
        guard let record = rowCache[row] else {
            return nil
        }
        return ScrollAnchor(path: record.path, offset: table.rect(ofRow: row).minY - visible.minY)
    }

    private func restoreScrollAnchor(_ anchor: ScrollAnchor, table: NSTableView) {
        guard let row = store.rows(forPaths: [anchor.path]).first else {
            return
        }
        let target = NSPoint(x: table.visibleRect.minX, y: max(0, table.rect(ofRow: row).minY - anchor.offset))
        table.scroll(target)
    }

    private func captureSelection(_ table: NSTableView) {
        let rows = table.selectedRowIndexes
        store.selectedRows = rows
        selectedAll = rows.count > 1 && rows.count == table.numberOfRows
        if selectedAll || rows.count > maxTrackedSelection {
            selectedPaths = []
            return
        }
        selectedPaths = rows.compactMap { store.record(atRow: $0)?.path }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return store.resultCount
    }

    private func cachedRecord(_ row: Int) -> FileRecord? {
        if let hit = rowCache[row] {
            return hit
        }
        guard let record = store.record(atRow: row) else {
            return nil
        }
        if rowCache.count > 4096 {
            rowCache.removeAll(keepingCapacity: true)
        }
        rowCache[row] = record
        return record
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else {
            return nil
        }
        let record = cachedRecord(row)
        switch tableColumn.identifier {
        case .name:
            let cell = textCell(in: tableView, identifier: .name, align: .left)
            cell.stringValue = record?.name ?? ""
            cell.textColor = .labelColor
            return cell
        case .path:
            let cell = textCell(in: tableView, identifier: .path, align: .left)
            cell.stringValue = record?.parent ?? ""
            cell.textColor = .secondaryLabelColor
            return cell
        case .size:
            let cell = textCell(in: tableView, identifier: .size, align: .right)
            cell.stringValue = record.map { formatFileSize($0.size, isDirectory: $0.isDirectory) } ?? ""
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
            return cell
        case .modified:
            let cell = textCell(in: tableView, identifier: .modified, align: .left)
            cell.stringValue = record.map { formatModifiedDate($0.modified) } ?? ""
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
            return cell
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if isApplyingSelection {
            return
        }
        guard let tableView else {
            return
        }
        captureSelection(tableView)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else {
            return
        }
        let column: SortColumn
        switch key {
        case ColumnID.name:
            column = .name
        case ColumnID.path:
            column = .path
        case ColumnID.size:
            column = .size
        case ColumnID.modified:
            column = .modified
        default:
            return
        }
        if store.sortColumn == column && store.sortAscending == descriptor.ascending {
            return
        }
        store.sortColumn = column
        store.sortAscending = descriptor.ascending
        store.runSearch()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let record = recordForMenu() else {
            return
        }
        menu.addItem(menuItem(title: "Open", action: #selector(openFromMenu(_:)), record: record))
        menu.addItem(menuItem(title: "Reveal in Finder", action: #selector(revealFromMenu(_:)), record: record))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Copy Full Path", action: #selector(copyPathFromMenu(_:)), record: record))
        menu.addItem(menuItem(title: "Copy Name", action: #selector(copyNameFromMenu(_:)), record: record))
    }

    @objc func didDoubleClick(_ sender: NSTableView) {
        guard let record = cachedRecord(sender.clickedRow) else {
            return
        }
        if sender.clickedColumn >= 0 && sender.tableColumns[sender.clickedColumn].identifier == .path {
            store.revealRecord(record)
            return
        }
        store.openRecord(record)
    }

    func openClickedOrSelected(_ table: NSTableView) {
        if table.clickedRow >= 0, let record = cachedRecord(table.clickedRow) {
            store.openRecord(record)
            return
        }
        store.openSelected()
    }

    func revealClickedOrSelected(_ table: NSTableView) {
        if table.clickedRow >= 0, let record = cachedRecord(table.clickedRow) {
            store.revealRecord(record)
            return
        }
        store.revealSelected()
    }

    func syncSortDescriptors(_ table: NSTableView) {
        let key: String
        switch store.sortColumn {
        case .name:
            key = ColumnID.name
        case .path:
            key = ColumnID.path
        case .size:
            key = ColumnID.size
        case .modified:
            key = ColumnID.modified
        }
        let descriptor = NSSortDescriptor(key: key, ascending: store.sortAscending)
        if table.sortDescriptors != [descriptor] {
            table.sortDescriptors = [descriptor]
        }
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        if let record = sender.representedObject as? FileRecord {
            store.openRecord(record)
        }
    }

    @objc private func revealFromMenu(_ sender: NSMenuItem) {
        if let record = sender.representedObject as? FileRecord {
            store.revealRecord(record)
        }
    }

    @objc private func copyPathFromMenu(_ sender: NSMenuItem) {
        if let record = sender.representedObject as? FileRecord {
            store.copyToPasteboard([record.path])
        }
    }

    @objc private func copyNameFromMenu(_ sender: NSMenuItem) {
        if let record = sender.representedObject as? FileRecord {
            store.copyToPasteboard([record.name])
        }
    }

    private func recordForMenu() -> FileRecord? {
        guard let tableView else {
            return nil
        }
        if tableView.clickedRow >= 0 {
            return cachedRecord(tableView.clickedRow)
        }
        return store.selectedRecords().first
    }

    private func menuItem(title: String, action: Selector, record: FileRecord) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = record
        return item
    }

    private func textCell(in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier, align: NSTextAlignment) -> NSTextField {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
            reused.alignment = align
            return reused
        }
        let field = NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.drawsBackground = false
        field.isBordered = false
        field.alignment = align
        return field
    }
}

private let maxTrackedSelection = 10_000

private struct ScrollAnchor {
    let path: String
    let offset: CGFloat
}

private enum ColumnID {
    static let name = "name"
    static let path = "path"
    static let size = "size"
    static let modified = "modified"
}

private extension NSUserInterfaceItemIdentifier {
    static let name = NSUserInterfaceItemIdentifier(ColumnID.name)
    static let path = NSUserInterfaceItemIdentifier(ColumnID.path)
    static let size = NSUserInterfaceItemIdentifier(ColumnID.size)
    static let modified = NSUserInterfaceItemIdentifier(ColumnID.modified)
}
