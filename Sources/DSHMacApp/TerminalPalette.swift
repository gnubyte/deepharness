import AppKit
import DSHCore

// MARK: - Palette

enum TerminalPalette {
    /// The 16 ANSI colours, tuned to stay readable on both appearances.
    static let ansi: [NSColor] = [
        NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1),  // black
        NSColor(srgbRed: 0.80, green: 0.25, blue: 0.25, alpha: 1),  // red
        NSColor(srgbRed: 0.25, green: 0.66, blue: 0.35, alpha: 1),  // green
        NSColor(srgbRed: 0.78, green: 0.60, blue: 0.20, alpha: 1),  // yellow
        NSColor(srgbRed: 0.27, green: 0.50, blue: 0.85, alpha: 1),  // blue
        NSColor(srgbRed: 0.68, green: 0.36, blue: 0.75, alpha: 1),  // magenta
        NSColor(srgbRed: 0.20, green: 0.64, blue: 0.68, alpha: 1),  // cyan
        NSColor(srgbRed: 0.75, green: 0.75, blue: 0.77, alpha: 1),  // white
        NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1),  // bright black
        NSColor(srgbRed: 0.95, green: 0.40, blue: 0.38, alpha: 1),
        NSColor(srgbRed: 0.40, green: 0.83, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.78, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.65, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.84, green: 0.52, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.82, blue: 0.85, alpha: 1),
        NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1),
    ]

    /// Resolve one of the 256 indexed colours.
    static func indexed(_ index: UInt8) -> NSColor {
        switch Int(index) {
        case 0..<16:
            return ansi[Int(index)]
        case 16..<232:
            // 6×6×6 colour cube.
            let value = Int(index) - 16
            let steps: [CGFloat] = [0, 0.373, 0.529, 0.686, 0.843, 1.0]
            return NSColor(srgbRed: steps[(value / 36) % 6],
                           green: steps[(value / 6) % 6],
                           blue: steps[value % 6], alpha: 1)
        default:
            // 24-step greyscale ramp.
            let level = CGFloat(Int(index) - 232) / 23.0
            return NSColor(white: 0.03 + level * 0.94, alpha: 1)
        }
    }

    static func resolve(_ colour: TerminalColor, fallback: NSColor) -> NSColor {
        switch colour {
        case .standard: return fallback
        case .indexed(let index): return indexed(index)
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        }
    }
}
