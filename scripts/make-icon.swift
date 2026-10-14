// Disegna l'icona dell'app (1024×1024) e la salva come PNG.
// Uso: swift scripts/make-icon.swift <output.png>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Fondo: quadrato arrotondato con il margine della griglia icone di macOS.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
let background = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.96, green: 0.33, blue: 0.24, alpha: 1),
           ending: NSColor(calibratedRed: 0.78, green: 0.13, blue: 0.20, alpha: 1))?
    .draw(in: background, angle: -90)

// Cornetta bianca al centro.
let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2, width: s.width, height: s.height))
}

// Pallino di registrazione in alto a destra.
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 660, y: 660, width: 150, height: 150)).fill()
NSColor(calibratedRed: 0.78, green: 0.13, blue: 0.20, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 690, y: 690, width: 90, height: 90)).fill()

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
