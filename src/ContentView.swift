import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $store.queryText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15))
                .disableAutocorrection(true)
                .focused($searchFocused)
                .padding(8)
                .onSubmit {
                    store.openSelected()
                }
            Divider()
            ResultsTableView(store: store)
            Divider()
            HStack {
                Text(statusLeft)
                Spacer()
                if store.status.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                if store.lastSearchMs > 0 {
                    Text("\(store.lastSearchMs) ms")
                        .foregroundStyle(.secondary)
                }
                Text(store.status.message)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onAppear {
            searchFocused = true
            store.start()
        }
        .onChange(of: store.queryText) { _, _ in
            store.scheduleSearch()
        }
        .onChange(of: store.showHidden) { _, _ in
            store.runSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumosFocusSearch)) { _ in
            searchFocused = true
        }
        .onExitCommand {
            store.queryText = ""
        }
        .sheet(isPresented: $store.showHelp) {
            HelpView()
        }
        .sheet(isPresented: $store.showFolders) {
            IndexedFoldersView()
                .environmentObject(store)
        }
        .alert("Lumos", isPresented: errorPresented) {
            Button("OK", role: .cancel) {
                store.lastError = nil
            }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { isPresented in
                if !isPresented {
                    store.lastError = nil
                }
            }
        )
    }

    private var statusLeft: String {
        let objects = formatCount(store.status.objectCount)
        if store.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(objects) objects"
        }
        return "\(formatCount(store.resultCount)) results  |  \(objects) objects"
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search syntax")
                .font(.headline)
            syntaxRow("report", "Name contains report")
            syntaxRow("foo|bar", "Name contains foo or bar")
            syntaxRow("*.pdf", "Wildcard")
            syntaxRow("ext:png;jpg", "Extension")
            syntaxRow("path:Documents", "Path contains Documents")
            syntaxRow("folder:", "Folders only")
            syntaxRow("size:>10mb", "Larger than 10 MB")
            syntaxRow("dm:today", "Modified today")
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func syntaxRow(_ query: String, _ meaning: String) -> some View {
        HStack {
            Text(query)
                .font(.system(.body, design: .monospaced))
                .frame(width: 150, alignment: .leading)
            Text(meaning)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct IndexedFoldersView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Indexed folders")
                .font(.headline)
            Text("Lumos indexes these folders once, then follows changes, including changes made while it was closed. Network folders are re-checked every 10 minutes.")
                .foregroundStyle(.secondary)
            List {
                ForEach(store.indexRoots, id: \.path) { url in
                    HStack {
                        Text(url.path)
                            .lineLimit(1)
                        Spacer()
                        Button("Remove") {
                            store.removeRoot(url)
                        }
                    }
                }
            }
            .frame(minHeight: 160)
            HStack {
                Button("Add Folder…") {
                    store.addFolders()
                }
                Button("Reindex") {
                    store.reindex()
                }
                Button("Clear and Reindex") {
                    store.clearAndReindex()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 340)
    }
}
