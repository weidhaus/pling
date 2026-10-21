import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// The few AppKit/UIKit calls shared code needs.
enum Platform {
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    #if os(macOS)
    static let deviceName = "Mac"
    #else
    static var deviceName: String { UIDevice.current.model }
    #endif

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Sheets need their own navigation stack on iOS for a title and toolbar; macOS sheets have both already.
struct SheetStack<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(macOS)
        content
        #else
        NavigationStack { content }
        #endif
    }
}
