// Renders App/Assets.xcassets/AppIcon.appiconset/icon-1024.png. Run: swift scripts/make-icon.swift
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset = 100.0, rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSShadow().then { $0.shadowColor = .black.withAlphaComponent(0.28); $0.shadowBlurRadius = 24; $0.shadowOffset = NSSize(width: 0, height: -10); $0.set() }
    NSGradient(colors: [NSColor(srgbRed: 0.47, green: 0.45, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.29, green: 0.25, blue: 0.78, alpha: 1)])!
        .draw(in: shape, angle: -90)
    NSShadow().set()
    // Soft top highlight
    NSGradient(colors: [.white.withAlphaComponent(0.22), .white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: 180, yRadius: 180), angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "bell.and.waves.left.and.right.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 10, width: s.width, height: s.height))
    return true
}
extension NSShadow { func then(_ f: (NSShadow) -> Void) -> NSShadow { f(self); return self } }

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"))
