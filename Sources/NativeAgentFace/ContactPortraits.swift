import Foundation
import AppKit
import SwiftUI
import NativeAgentShared
// Blueprint: | `ContactPortraits.swift` | Finished portrait bytes and local initial tints; Clawd and helper tile drawing |

struct SimpleAvatar: View {
    let contact: FaceContact
    var size: CGFloat = 30

    private var tint: Color {
        let hue = contact.id.utf8.reduce(0.0) { ($0 * 31 + Double($1)).truncatingRemainder(dividingBy: 360) } / 360
        return Color(hue: hue, saturation: 0.42, brightness: 0.52)
    }

    var body: some View {
        Group {
            if let bytes = contact.portrait {
                if let image = NSImage(data: bytes) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: "exclamationmark.triangle").help("The contact portrait could not be decoded.")
                }
            } else if contact.appBundleID == "com.anthropic.claudefordesktop" {
                ClawdMark(size: size)
            } else {
                tint.overlay {
                    Text(contact.label.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(NativeAgentShell.hairline, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

/// Snap the pixel drawing to device pixels to keep its edges crisp.
struct ClawdMark: View {
    var size: CGFloat
    @Environment(\.displayScale) private var displayScale
    private static let rows = [
        " ####### ",
        " # ### # ",
        "#########",
        " ####### ",
        " # # # # ",
    ]

    var body: some View {
        Canvas { context, canvas in
            let scale = max(displayScale, 1)
            let pixel = max(1, (canvas.width * 0.9 / 9 * scale).rounded(.down)) / scale
            let origin = CGPoint(x: ((canvas.width - pixel * 9) / 2 * scale).rounded() / scale,
                                 y: ((canvas.height - pixel * 5) / 2 * scale).rounded() / scale)
            for (y, row) in Self.rows.enumerated() {
                for (x, cell) in row.enumerated() where cell == "#" {
                    let rect = CGRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(y) * pixel,
                                      width: pixel, height: pixel)
                    context.fill(Path(rect), with: .color(Color(red: 0.851, green: 0.467, blue: 0.341)))
                }
            }
        }
        .frame(width: size, height: size)
        .background(Color(red: 0.12, green: 0.118, blue: 0.114))
    }
}

struct SimpleClockTile: View {
    var size: CGFloat = 30
    var symbol = "clock"
    var working = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(NativeAgentShell.softFill)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .frame(width: size, height: size)
            .overlay { if working { WorkingRim(cornerRadius: size * 0.27) } }
            .accessibilityHidden(true)
    }
}
