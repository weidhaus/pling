import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentView: View {
    @Environment(AppModel.self) private var app
    let message: StoredMessage
    var maxHeight: CGFloat = 240

    @State private var image: NSImage?
    @State private var failed = false
    @State private var previewURL: URL?
    @State private var saving = false

    var body: some View {
        if let attachment = message.attachment {
            if attachment.isExpired {
                chip(symbol: "clock.badge.xmark", title: attachment.name, detail: "Expired")
            } else if attachment.isImage, !failed {
                imageView
            } else {
                fileView
            }
        }
    }

    private var imageView: some View {
        Group {
            if let image {
                Button { preview() } label: {
                    let size = fitted(image.size)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
                }
                .buttonStyle(.plain)
                .help("Quick Look \(message.attachmentName ?? "")")
                .accessibilityLabel("Image \(message.attachmentName ?? ""). Opens Quick Look.")
                .quickLookPreview($previewURL)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: maxHeight * 1.2, height: maxHeight * 0.6)
                    .overlay { ProgressView().controlSize(.small) }
                    .accessibilityLabel("Loading image")
            }
        }
        .task(id: message.key) { await load() }
    }

    private func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxHeight, height: maxHeight) }
        let scale = min(maxHeight / size.height, maxHeight * 1.6 / size.width, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var fileView: some View {
        let detail = message.attachmentSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return HStack(spacing: 8) {
            chip(symbol: failed ? "exclamationmark.triangle" : "doc", title: message.attachmentName ?? "Attachment",
                 detail: failed ? "Couldn’t load" : detail)
            Button(saving ? "Saving…" : "Save to Downloads") { Task { await save() } }
                .controlSize(.small)
                .disabled(saving)
        }
    }

    private func chip(symbol: String, title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).lineLimit(1).truncationMode(.middle)
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 7))
    }

    private func load() async {
        do {
            let data = try await app.attachmentData(message)
            guard let img = NSImage(data: data) else { failed = true; return }
            image = img
        } catch {
            failed = true
        }
    }

    /// Quick Look needs a file; write the original bytes (not the decoded image) to a temp folder.
    private func preview() {
        Task {
            guard let data = try? await app.attachmentData(message) else { return }
            let dir = FileManager.default.temporaryDirectory.appending(path: message.ntfyID)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: message.attachmentName ?? "image")
            if (try? data.write(to: url)) != nil { previewURL = url }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let data = try await app.attachmentData(message)
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var url = downloads.appending(path: message.attachmentName ?? "attachment")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                let base = (message.attachmentName as NSString?)?.deletingPathExtension ?? "attachment"
                let ext = (message.attachmentName as NSString?)?.pathExtension ?? ""
                url = downloads.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            failed = true
        }
    }
}
