import EventKit
import PlingCore
import SwiftUI

enum PriorityStyle {
    static func color(_ p: Int) -> Color? {
        switch p {
        case 5: .red
        case 4: .orange
        case 2: .teal
        case ...1: .gray
        default: nil
        }
    }

    static func symbol(_ p: Int) -> String? {
        switch p {
        case 5: "exclamationmark.3"
        case 4: "exclamationmark.2"
        case ...2: "arrow.down"
        default: nil
        }
    }

    static func name(_ p: Int) -> String {
        ["Min", "Low", "Default", "High", "Urgent"][min(max(p, 1), 5) - 1]
    }
}

/// Pling's signature: a slim bar on the leading edge that only appears when priority isn't default.
struct PrioritySpine: View {
    let priority: Int
    var body: some View {
        Capsule()
            .fill(PriorityStyle.color(priority) ?? .clear)
            .frame(width: 3)
            .opacity(priority >= 4 ? 1 : 0.5)
            .accessibilityHidden(true)
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var app
    let message: StoredMessage
    let subscription: Subscription?
    var showsTopic = true
    var compact = false

    @State private var expanded = false
    @State private var isHovering = false
    @State private var runningAction: String?
    @State private var error: String?

    private var split: (emoji: [String], plain: [String]) { Emoji.split(message.tags) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PrioritySpine(priority: message.priority)
            VStack(alignment: .leading, spacing: 5) {
                header
                if !message.title.isEmpty {
                    Text(titleText)
                        .font(compact ? .callout.weight(.semibold) : .headline)
                        .foregroundStyle(message.decryptFailed ? .secondary : .primary)
                }
                if !message.body.isEmpty { bodyText }
                if message.decryptFailed, let subscription {
                    Button(subscription.hasPassphrase ? "Change Passphrase…" : "Add Passphrase…", systemImage: "key.fill") {
                        app.editTopic(subscription)
                    }
                    .controlSize(compact ? .small : .regular)
                }
                if message.attachment != nil {
                    AttachmentView(message: message, maxHeight: compact ? 150 : 240)
                }
                if !split.plain.isEmpty { tagChips }
                if !message.actions.isEmpty || error != nil { actionBar }
            }
        }
        .padding(.vertical, compact ? 8 : 6)
        .padding(.horizontal, compact ? 12 : 0)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .contextMenu { MessageMenu(message: message) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: message.isRead ? "Mark as Unread" : "Mark as Read") { app.toggleRead(message) }
    }

    private var titleText: String {
        let lead = split.emoji.joined()
        return lead.isEmpty ? message.title : "\(lead) \(message.title)"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !message.isRead {
                Circle().fill(.tint).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            if showsTopic, let subscription {
                Text([subscription.emoji, subscription.title].compactMap(\.self).joined(separator: " "))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if message.isEncrypted {
                Image(systemName: message.decryptFailed ? "lock.trianglebadge.exclamationmark" : "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(message.decryptFailed ? "Couldn’t decrypt" : "End-to-end encrypted")
            }
            // Untitled messages put their emoji tags in the header so they aren't lost.
            if message.title.isEmpty, !split.emoji.isEmpty { Text(split.emoji.joined()).font(.caption) }
            Spacer(minLength: 4)
            if let symbol = PriorityStyle.symbol(message.priority), message.priority >= 4 {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PriorityStyle.color(message.priority) ?? .secondary)
                    .help("\(PriorityStyle.name(message.priority)) priority")
            }
            if isHovering {
                MessageQuickActions(message: message)
            } else {
                TimeLabel(date: message.time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 18)
    }

    private var bodyText: some View {
        let limit = compact ? 4 : 8
        return VStack(alignment: .leading, spacing: 2) {
            Text(Self.render(message))
                .font(compact ? .callout : .body)
                .foregroundStyle(message.decryptFailed ? .secondary : .primary)
                .lineLimit(expanded ? nil : limit)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !expanded, message.body.count > limit * 60 || message.body.filter(\.isNewline).count >= limit {
                Button("Show More") { expanded = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var tagChips: some View {
        HStack(spacing: 4) {
            ForEach(split.plain, id: \.self) { tag in
                Text(tag)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tags: \(split.plain.joined(separator: ", "))")
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(message.actions.filter { [.view, .http, .copy].contains($0.action) }) { action in
                    Button {
                        Task { await run(action) }
                    } label: {
                        HStack(spacing: 4) {
                            if runningAction == action.id { ProgressView().controlSize(.mini) }
                            Text(action.label)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .small : .regular)
                    .disabled(runningAction != nil)
                    .help(action.url?.absoluteString ?? action.label)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 2)
    }

    private func run(_ action: Action) async {
        runningAction = action.id
        error = nil
        do { try await app.perform(action, on: message) } catch { self.error = error.localizedDescription }
        runningAction = nil
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if !message.isRead { parts.append("Unread") }
        if message.priority != 3 { parts.append("\(PriorityStyle.name(message.priority)) priority") }
        if showsTopic, let subscription { parts.append(subscription.title) }
        if !message.title.isEmpty { parts.append(message.title) }
        return parts.joined(separator: ", ")
    }

    /// Markdown when the publisher asked for it, otherwise plain text with detected links.
    static func render(_ m: StoredMessage) -> AttributedString {
        if m.isMarkdown, let md = try? AttributedString(markdown: m.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return md
        }
        var text = AttributedString(m.body)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        for match in detector.matches(in: m.body, range: NSRange(m.body.startIndex..., in: m.body)) {
            if let url = match.url, let r = Range(match.range, in: m.body), let ar = Range(r, in: text) {
                text[ar].link = url
            }
        }
        return text
    }
}

/// Hover actions: read toggle and snooze. Same commands live in the context menu.
struct MessageQuickActions: View {
    @Environment(AppModel.self) private var app
    let message: StoredMessage

    var body: some View {
        HStack(spacing: 2) {
            Button(message.isRead ? "Mark as Unread" : "Mark as Read",
                   systemImage: message.isRead ? "circle" : "checkmark.circle") { app.toggleRead(message) }
            Menu("Remind Me", systemImage: "clock") {
                ForEach(AppModel.SnoozeOption.allCases) { option in
                    Button(option.label) { app.snooze(message, option) }
                }
            }
            .menuIndicator(.hidden)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .font(.caption)
        .fixedSize()
    }
}

struct MessageMenu: View {
    @Environment(AppModel.self) private var app
    let message: StoredMessage

    var body: some View {
        Button(message.isRead ? "Mark as Unread" : "Mark as Read") { app.toggleRead(message) }
        if message.nextAlertAt != nil, !message.acknowledged {
            Button("Acknowledge") { app.acknowledge(message) }
        }
        Menu("Remind Me") {
            ForEach(AppModel.SnoozeOption.allCases) { option in
                Button(option.label) { app.snooze(message, option) }
            }
        }
        let lists = app.reminderLists
        if lists.isEmpty {
            Button("Add to Reminders") { addToReminders(nil) }
        } else {
            Menu("Add to Reminders") {
                ForEach(lists, id: \.calendarIdentifier) { list in
                    Button(list.title) { addToReminders(list) }
                }
            }
        }
        Divider()
        if let url = message.click {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString([message.title, message.body].filter { !$0.isEmpty }.joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) { app.delete(message) }
    }
}

extension MessageMenu {
    func addToReminders(_ list: EKCalendar?) {
        Task { do { try await app.addToReminders(message, list: list) } catch { app.notifier.postFailure(error.localizedDescription) } }
    }
}

struct TimeLabel: View {
    let date: Date
    var body: some View {
        if date > .now.addingTimeInterval(-86_400) {
            Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
        } else {
            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
        }
    }
}
