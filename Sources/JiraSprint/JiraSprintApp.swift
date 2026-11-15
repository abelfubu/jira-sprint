import AppKit
import SwiftUI

@main
struct JiraSprintApp: App {
    @StateObject private var store = SprintStore()

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["JIRA_SPRINT_SELF_TEST"] == "1"
            || CommandLine.arguments.contains("--self-test") {
            SelfTests.run()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("Jira Sprint") {
            ContentView(store: store)
                .background(WindowConfigurator())
                .ignoresSafeArea()
                .frame(minWidth: 300, idealWidth: 480, minHeight: 320, idealHeight: 760)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: dimension("JIRA_SPRINT_WIDTH", fallback: 480),
                     height: dimension("JIRA_SPRINT_HEIGHT", fallback: 760))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Refresh") { store.performShortcut(.refresh) }
                    .keyboardShortcut(store.shortcuts.keyboardShortcut(for: .refresh, preferred: "cmd-r"))
                Button("Open Selected Story") { store.performShortcut(.openSelected) }
                    .keyboardShortcut(store.shortcuts.keyboardShortcut(for: .openSelected, preferred: "cmd-enter"))
                Button("Open Config") { store.performShortcut(.openConfig) }
                    .keyboardShortcut(store.shortcuts.keyboardShortcut(for: .openConfig, preferred: "cmd-shift-o"))
                Button("Close") { store.performShortcut(.closeWindow) }
                    .keyboardShortcut(store.shortcuts.keyboardShortcut(for: .closeWindow, preferred: "cmd-w"))
            }
        }
    }

    private func dimension(_ name: String, fallback: CGFloat) -> CGFloat {
        guard let value = ProcessInfo.processInfo.environment[name], let number = Double(value), number > 0 else {
            return fallback
        }
        return CGFloat(number)
    }
}
