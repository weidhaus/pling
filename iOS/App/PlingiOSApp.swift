import SwiftData
import SwiftUI

@main
struct PlingiOSApp: App {
    @UIApplicationDelegateAdaptor private var delegate: PushAppDelegate
    let container: ModelContainer
    @State private var app: AppModel
    @State private var push: PushRegistrar

    init() {
        let container = try! ModelContainer(for: Server.self, Subscription.self, StoredMessage.self)
        self.container = container
        let model = AppModel(context: container.mainContext)
        let push = PushRegistrar(context: container.mainContext)
        _app = State(initialValue: model)
        _push = State(initialValue: push)
        PushAppDelegate.registrar = push
        model.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Color("AccentColor"))
                .environment(app)
                .environment(push)
                .modelContainer(container)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(PushRegistrar.self) private var push
    @Query private var servers: [Server]

    var body: some View {
        Group {
            if servers.isEmpty { NoServersView() } else { MainWindow() }
        }
        .task(id: servers.isEmpty) {
            push.scheduleSync()
            // Ask once there's something to be notified about.
            if !servers.isEmpty, app.notificationStatus == .notDetermined { await app.requestNotifications() }
        }
    }
}

struct NoServersView: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Pling", systemImage: "bell.badge")
        } description: {
            Text("Connect to an ntfy server to receive its messages here, with priorities, images and actions.")
        } actions: {
            Button("Add Server") { adding = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                ServerEditor(server: nil) { _ in
                    adding = false
                    app.isAddingTopic = true
                }
                .navigationTitle("Add Server")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                }
            }
        }
    }
}
