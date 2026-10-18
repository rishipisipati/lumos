import AppKit
import Foundation
import SwiftUI

enum SearchDebounce: Int, CaseIterable, Identifiable {
    case off = 0
    case fast = 80
    case medium = 200
    case slow = 400
    case verySlow = 800

    var id: Int { rawValue }

    var menuTitle: String {
        switch self {
        case .off:
            return "Off (every keystroke)"
        case .fast:
            return "Fast (80 ms)"
        case .medium:
            return "Medium (200 ms)"
        case .slow:
            return "Slow (400 ms)"
        case .verySlow:
            return "Very Slow (800 ms)"
        }
    }

    var delay: TimeInterval {
        return TimeInterval(rawValue) / 1000.0
    }
}

private let maxItemsToOpen = 20
private let liveRefreshInterval: TimeInterval = 1.0

final class AppStore: ObservableObject {
    @Published var queryText: String = ""
    @Published var showHidden: Bool = false
    @Published var showHelp: Bool = false
    @Published var showFolders: Bool = false
    @Published var indexRoots: [URL] = []
    @Published var sortColumn: SortColumn = .name
    @Published var sortAscending: Bool = true
    @Published var lastSearchMs: Int = 0
    @Published var status = IndexStatus(
        phase: .starting,
        objectCount: 0,
        message: "Starting…",
        revision: 0,
        layout: 0,
        problem: nil
    )
    @Published var lastError: String?
    @Published private(set) var resultCount: Int = 0
    @Published private(set) var resultToken: UInt64 = 0
    @Published var debounce: SearchDebounce = .medium {
        didSet {
            UserDefaults.standard.set(debounce.rawValue, forKey: AppStore.debounceKey)
        }
    }
    @Published var globalShortcutEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(globalShortcutEnabled, forKey: AppStore.globalShortcutKey)
            applyGlobalShortcut()
        }
    }

    /// Rows currently selected in the table (owned by the table view).
    var selectedRows = IndexSet()
    /// True when the current results re-ran the previous query because the
    /// index changed, so the table keeps its scroll position.
    private(set) var resultIsRefresh = false

    private(set) var resultIds: [Int32] = []
    private var resultLayout: UInt64 = 0
    private var resultRevision: UInt64 = 0
    private var resultQuery: ResultQuery?
    private var indexer: IndexService?
    private var queryServer: QueryServer?
    private let searchQueue = DispatchQueue(label: "lumos.search", qos: .userInitiated)
    private let generationLock = NSLock()
    private var latestGeneration: UInt64 = 0
    private var searchInFlight = false
    private var lastSearchAt = Date.distantPast
    private var started = false
    private var debounceWork: DispatchWorkItem?
    private var statusTimer: Timer?
    private var shownProblem: String?
    private var terminateObserver: NSObjectProtocol?
    private var hotKey: GlobalHotKey?
    private static let debounceKey = "searchDebounceMs"
    private static let globalShortcutKey = "globalShortcutEnabled"

    init() {
        if let stored = UserDefaults.standard.object(forKey: AppStore.debounceKey) as? Int,
           let value = SearchDebounce(rawValue: stored) {
            debounce = value
        } else {
            debounce = .medium
        }
        if let stored = UserDefaults.standard.object(forKey: AppStore.globalShortcutKey) as? Bool {
            globalShortcutEnabled = stored
        }
    }

    private func applyGlobalShortcut() {
        if !started || !globalShortcutEnabled {
            hotKey = nil
            return
        }
        if hotKey != nil {
            return
        }
        do {
            hotKey = try GlobalHotKey { [weak self] in
                self?.toggleWindow()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Option-Space: hide Lumos when it is in front, otherwise bring it forward
    /// with the search field focused.
    func toggleWindow() {
        if NSApp.isActive && NSApp.keyWindow != nil {
            NSApp.hide(nil)
            return
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        focusSearch()
    }

    func start() {
        if started {
            return
        }
        started = true
        Privacy.clearVolatileUserDefaults()
        indexRoots = loadRoots()
        do {
            let folder = try lumosSupportFolder()
            try retireBackgroundIndexer(folder: folder)
            let service = IndexService(folder: folder, roots: indexRoots.map(\.path))
            try service.start()
            indexer = service
        } catch {
            started = false
            lastError = error.localizedDescription
            return
        }
        if let indexer {
            do {
                queryServer = try startQueryServer(indexer, owner: .app, onRequest: {}, shutdown: {})
            } catch {
                lastError = "Search works, but the lumos command-line tool cannot reach this window: \(error.localizedDescription)"
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.queryServer?.stop()
            self?.indexer?.stop()
        }
        applyGlobalShortcut()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
        pollStatus()
        runSearch()
    }

    func scheduleSearch() {
        debounceWork?.cancel()
        if debounce == .off {
            runSearch()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.runSearch()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce.delay, execute: work)
    }

    func runSearch() {
        guard let indexer else {
            return
        }
        generationLock.lock()
        latestGeneration += 1
        let generation = latestGeneration
        generationLock.unlock()
        let query = parseQuery(queryText)
        let showHidden = showHidden
        let column = sortColumn
        let ascending = sortAscending
        let key = ResultQuery(text: queryText, showHidden: showHidden, column: column, ascending: ascending)
        searchInFlight = true
        searchQueue.async { [weak self] in
            guard let self, self.isLatest(generation) else {
                return
            }
            let startedAt = DispatchTime.now()
            let found = indexer.store.readForSearch { data, layout, trigrams in
                (ids: searchIndex(data, query: query, showHidden: showHidden, sortColumn: column, ascending: ascending, trigrams: trigrams),
                 layout: layout,
                 revision: data.revision)
            }
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
            DispatchQueue.main.async {
                if !self.isLatest(generation) {
                    return
                }
                self.searchInFlight = false
                self.resultIsRefresh = self.resultQuery == key
                self.resultQuery = key
                self.resultIds = found.ids
                self.resultLayout = found.layout
                self.resultRevision = found.revision
                self.resultCount = found.ids.count
                self.resultToken &+= 1
                self.lastSearchMs = elapsed
                self.lastSearchAt = Date()
            }
        }
    }

    func setSort(column: SortColumn) {
        if sortColumn == column {
            sortAscending = !sortAscending
        } else {
            sortColumn = column
            sortAscending = true
        }
        runSearch()
    }

    func reindex() {
        indexer?.reindex()
    }

    func clearAndReindex() {
        indexer?.clearAndReindex()
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose folders to include in the Lumos index."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.begin { response in
            if response != .OK {
                return
            }
            var next = self.indexRoots
            for url in panel.urls where !next.contains(url) {
                next.append(url)
            }
            Privacy.clearVolatileUserDefaults()
            self.applyRoots(next)
        }
    }

    func removeRoot(_ url: URL) {
        applyRoots(indexRoots.filter { $0 != url })
    }

    /// Builds the record for a table row, or nil when the entry was deleted or
    /// renumbered since the search ran (a live refresh will follow).
    func record(atRow row: Int) -> FileRecord? {
        guard row >= 0, row < resultIds.count, let indexer else {
            return nil
        }
        let id = resultIds[row]
        let layout = resultLayout
        return indexer.store.readWithLayout { data, currentLayout in
            currentLayout == layout && data.isLive(id) ? data.record(id) : nil
        }
    }

    /// Rows of the current results whose entries live at `paths`. Used to keep
    /// the selection and scroll anchor on the same files across refreshes,
    /// since entry ids change when the index is compacted.
    func rows(forPaths paths: [String]) -> IndexSet {
        guard let indexer, !paths.isEmpty else {
            return IndexSet()
        }
        let layout = resultLayout
        let wanted: Set<Int32> = indexer.store.readWithLayout { data, currentLayout in
            if currentLayout != layout {
                return []
            }
            var ids = Set<Int32>()
            for path in paths {
                if case .found(let id) = data.lookup(path: path), data.isLive(id) {
                    ids.insert(id)
                }
            }
            return ids
        }
        var rows = IndexSet()
        if wanted.isEmpty {
            return rows
        }
        for (row, id) in resultIds.enumerated() where wanted.contains(id) {
            rows.insert(row)
        }
        return rows
    }

    func selectedRecords() -> [FileRecord] {
        return selectedRows.compactMap { record(atRow: $0) }
    }

    func openSelected() {
        let records = selectedRecords()
        if records.count > maxItemsToOpen {
            lastError = "Select \(maxItemsToOpen) or fewer items to open at once (\(formatCount(records.count)) selected)."
            return
        }
        for record in records {
            openRecord(record)
        }
    }

    func openRecord(_ record: FileRecord) {
        if !FileManager.default.fileExists(atPath: record.path) {
            lastError = "The file no longer exists: \(record.path)"
            return
        }
        let url = URL(fileURLWithPath: record.path, isDirectory: record.isDirectory)
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                DispatchQueue.main.async {
                    self.lastError = "Could not open \(record.name): \(error.localizedDescription)"
                }
            }
        }
    }

    func revealSelected() {
        let urls = selectedRecords().map { URL(fileURLWithPath: $0.path) }
        if urls.isEmpty {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealRecord(_ record: FileRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.path)])
    }

    func copyPaths() {
        copyToPasteboard(selectedRecords().map(\.path))
    }

    func copyNames() {
        copyToPasteboard(selectedRecords().map(\.name))
    }

    func copyToPasteboard(_ lines: [String]) {
        if lines.isEmpty {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func focusSearch() {
        NotificationCenter.default.post(name: .lumosFocusSearch, object: nil)
    }

    private func applyRoots(_ next: [URL]) {
        indexRoots = next
        UserDefaults.standard.set(next.map(\.path), forKey: indexRootsDefaultsKey)
        indexer?.updateRoots(next.map(\.path))
    }

    private func isLatest(_ generation: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == latestGeneration
    }

    private func pollStatus() {
        guard let indexer else {
            return
        }
        let next = indexer.status()
        if next != status {
            status = next
        }
        if let problem = next.problem, problem != shownProblem {
            shownProblem = problem
            lastError = problem
        }
        if searchInFlight {
            return
        }
        // Renumbered ids leave the visible rows unresolvable, so refresh at once.
        if next.layout != resultLayout {
            runSearch()
        } else if next.revision != resultRevision && Date().timeIntervalSince(lastSearchAt) >= liveRefreshInterval {
            runSearch()
        }
    }

    private func loadRoots() -> [URL] {
        return configuredIndexRoots(UserDefaults.standard).map { URL(fileURLWithPath: $0) }
    }
}

private struct ResultQuery: Equatable {
    let text: String
    let showHidden: Bool
    let column: SortColumn
    let ascending: Bool
}

extension Notification.Name {
    static let lumosFocusSearch = Notification.Name("lumosFocusSearch")
}
