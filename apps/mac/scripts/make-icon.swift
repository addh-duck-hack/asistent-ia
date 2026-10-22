// Genera el ícono de la app (1024x1024) con un degradado y un símbolo SF.
// Uso: swift scripts/make-icon.swift <salida.png>
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Fondo redondeado con el margen de los íconos de macOS (~10%).
let inset = size * 0.1
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.36, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.47, green: 0.22, blue: 0.86, alpha: 1),
])!.draw(in: path, angle: -60)

let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "waveform.badge.magnifyingglass", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
image.unlockFocus()

let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("ícono: \(out)")
