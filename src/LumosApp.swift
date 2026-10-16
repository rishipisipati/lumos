import AppKit
import SwiftUI

@main
struct LumosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup("Lumos") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 780, minHeight: 380)
        }
        .defaultSize(width: 980, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Folder to Index…") {
                    store.addFolders()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Indexed Folders…") {
                    store.showFolders = true
                }
                Button("Reindex") {
                    store.reindex()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Clear and Reindex") {
                    store.clearAndReindex()
                }
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Full Path") {
                    store.copyPaths()
                }
                Button("Copy Name") {
                    store.copyNames()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandMenu("Search") {
                Button("Focus Search") {
                    store.focusSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Open") {
                    store.openSelected()
                }
                Button("Reveal in Finder") {
                    store.revealSelected()
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
            CommandMenu("Delay") {
                ForEach(SearchDebounce.allCases) { option in
                    Toggle(option.menuTitle, isOn: Binding(
                        get: { store.debounce == option },
                        set: { isOn in
                            if isOn {
                                store.debounce = option
                            }
                        }
                    ))
                }
            }
            CommandMenu("View") {
                Toggle("Show Hidden Files", isOn: $store.showHidden)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Lumos Search Syntax") {
                    store.showHelp = true
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSDocumentController.shared.clearRecentDocuments(nil)
        Privacy.clearVolatileUserDefaults()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSDocumentController.shared.clearRecentDocuments(nil)
        Privacy.clearVolatileUserDefaults()
    }
}
