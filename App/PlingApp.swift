import SwiftData
import SwiftUI

@main
struct PlingApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    let container: ModelContainer
    @State private var app: AppModel

    init() {
        // Not sandboxed, so give the store its own folder instead of the shared default.store.
        let dir = URL.applicationSupportDirectory.appending(path: "Pling")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let container = try! ModelContainer(for: Server.self, Subscription.self, StoredMessage.self,
                                            configurations: ModelConfiguration(url: dir.appending(path: "Pling.store")))
        self.container = container
        let model = AppModel(context: container.mainContext)
        _app = State(initialValue: model)
        AppDelegate.model = model
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .tint(Color("AccentColor"))
                .environment(app)
                .modelContainer(container)
        } label: {
            MenuBarLabel()
                .environment(app)
                .modelContainer(container)
        }
        .menuBarExtraStyle(.window)

        Window("Pling", id: "main") {
            MainWindow()
                .tint(Color("AccentColor"))
                .environment(app)
                .modelContainer(container)
        }
        .defaultSize(width: 980, height: 660)
        .defaultLaunchBehavior(.suppressed)
        .commands { PlingCommands(app: app) }

        Window("Welcome to Pling", id: "onboarding") {
            OnboardingView()
                .tint(Color("AccentColor"))
                .environment(app)
                .modelContainer(container)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .tint(Color("AccentColor"))
                .environment(app)
                .modelContainer(container)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?

    /// Opening Pling again (Finder, Spotlight, Dock) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Self.model?.showMainWindow()
        return true
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Query(filter: #Predicate<StoredMessage> { !$0.isRead }) private var unread: [StoredMessage]
    @AppStorage(Prefs.doNotDisturb) private var doNotDisturb = false

    var body: some View {
        Group {
            if doNotDisturb { Image(systemName: "moon.fill") } else { Image(unread.isEmpty ? "MenuBarRead" : "MenuBarUnread") }
        }
            .accessibilityLabel(unread.isEmpty ? "Pling" : "Pling, \(unread.count) unread")
            .task {
                app.openWindow = openWindow
                if !Prefs.defaults.bool(forKey: Prefs.onboarded) {
                    // Existing installs with servers skip the setup but still land in it once to grant permissions.
                    openWindow(id: "onboarding")
                }
            }
    }
}

struct PlingCommands: Commands {
    let app: AppModel
    @AppStorage(Prefs.doNotDisturb) private var doNotDisturb = false

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { app.updater.checkForUpdates(nil) }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Message…") { app.compose() }
                .keyboardShortcut("n")
            Button("Add Topic…") { app.isAddingTopic = true; app.showMainWindow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Messages") {
            Button("Mark All as Read") { app.markAllRead(app.messages(for: app.selection ?? .all)) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Toggle("Do Not Disturb", isOn: $doNotDisturb)
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
