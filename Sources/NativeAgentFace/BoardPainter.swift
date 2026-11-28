import AppKit
import CoreGraphics
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `BoardPainter.swift` | `BoardPalette`: the Mac board's native appearance colours |

/// The board's quiet colours: a card is content, a pale fill of its colour in light and a deep one in dark, its words in the ink that
/// reads on it; lines (pen strokes, a section's edge, a card's own outline) are the colour itself.
enum BoardPalette {
    static let names = ["white", "yellow", "green", "blue", "purple", "peach", "ink"]

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }

    static func fill(_ name: String?) -> Color {
        switch name ?? "" {
        case "green": dynamic(light: 0xE4F2E5, dark: 0x2F4033)
        case "yellow": dynamic(light: 0xFBF2D0, dark: 0x4A4228)
        case "purple": dynamic(light: 0xEEE6F7, dark: 0x3D3550)
        case "blue": dynamic(light: 0xE2ECF8, dark: 0x2D3A4C)
        case "peach": dynamic(light: 0xFCE7DA, dark: 0x4C382E)
        case "ink": dynamic(light: 0x2E3034, dark: 0xE6E3DE)
        default: TodayPalette.cardFill
        }
    }

    /// The words on a card of this colour.
    static func words(_ name: String?, table: Bool = false) -> Color {
        name == "ink" ? dynamic(light: 0xF6F3EE, dark: 0x1C1D20) : table ? dynamic(light: 0x1C1D20, dark: 0xF6F3EE) : .primary
    }

    static func line(_ name: String?) -> Color {
        switch name ?? "ink" {
        case "green": dynamic(light: 0x3E8E4E, dark: 0x7CC48A)
        case "yellow": dynamic(light: 0xA9841C, dark: 0xE0C25A)
        case "purple": dynamic(light: 0x7A5BB5, dark: 0xB49BE6)
        case "blue": dynamic(light: 0x3F6FB0, dark: 0x8DB2E8)
        case "peach", "terracotta": dynamic(light: 0xC46A3C, dark: 0xEDA27E)
        case "white": dynamic(light: 0x9A9A9A, dark: 0xD0D0D0)
        case "ink": .primary
        default: .secondary
        }
    }
    static func paint(textScale: CGFloat) -> BoardPainter.Palette {
        .init(fill: fill, words: words, line: line, cardFill: TodayPalette.cardFill, cardStroke: TodayPalette.cardStroke,
              caption: .system(size: ShellType.captionSize * textScale))
    }
}
