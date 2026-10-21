import SwiftData
import SwiftUI

/// One message in full. Opening it marks it as read.
struct MessageDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var messages: [StoredMessage]
    @Query private var subscriptions: [Subscription]

    init(key: String) {
        _messages = Query(filter: #Predicate<StoredMessage> { $0.key == key })
    }

    var body: some View {
        if let message = messages.first {
            let subscription = subscriptions.first { $0.id == message.subscriptionID }
            ScrollView {
                MessageRow(message: message, subscription: subscription, fullText: true)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(subscription?.title ?? message.topic)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem {
                    Menu("More", systemImage: "ellipsis") {
                        MessageMenu(message: message) { dismiss(); app.delete(message) }
                    }
                }
                ToolbarSpacer(placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { app.compose(to: subscription) }
                }
            }
            .onAppear { if !message.isRead { app.acknowledge(message) } }
        } else {
            ContentUnavailableView("Message Deleted", systemImage: "trash")
        }
    }
}
