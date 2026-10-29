import AppKit
import SwiftUI
import Foundation
import NativeAgentShared
import EngineRuntime
import SwarmRuns
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import StandingBots
import ProviderRouting
import AppToolRuntime
// Blueprint: | `ContactPortraits.swift` | Contact app icons, initial tints, Clawd drawing and helper/crew clock tiles |

/// The contact's app icon in a circle, or its initial on a tint of its own.
struct SimpleAvatar: View {
    @Environment(AppModel.self) private var appModel
    let contact: SimpleContact
    var size: CGFloat = 30

    /// Eight evenly spaced muted hues each contrast at least 5.09:1 with white initials.
    nonisolated private static let tints: [UInt32] = [0x925A56, 0x886439, 0x6A713C, 0x42795D, 0x2B7880, 0x496F96, 0x6F6393, 0x895A79]
    nonisolated static var slotCount: Int { tints.count }

    @State private var loadedIcon: NSImage?

    private var tint: Color {
        let index = appModel.engine.contactThreads.contacts.filter { $0.appBundleID == nil }
            .sorted { $0.id < $1.id }.firstIndex { $0.id == contact.id } ?? 0
        return Color(hex: UInt(Self.tints[index * 3 % Self.slotCount]))
    }

    var body: some View {
        Group {
            if contact.clawd {
                ClawdMark(size: size)
            } else if let icon = loadedIcon {
                // The icon's squircle fills the circle; its transparent margin falls outside.
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().scaleEffect(1.24)
            } else {
                tint.overlay {
                    Text(contact.initial)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(NativeAgentShell.hairline, lineWidth: 0.5) }
        // A small window on the desktop app's corner: this contact is the app itself.
        .overlay(alignment: .bottomTrailing) {
            if contact.link == .desktopApp {
                Image(systemName: "macwindow")
                    .font(.system(size: size * 0.24, weight: .semibold))
                    .foregroundStyle(NativeAgentShell.text)
                    .frame(width: size * 0.44, height: size * 0.44)
                    .background(Circle().fill(NativeAgentShell.room))
                    .overlay { Circle().strokeBorder(NativeAgentShell.hairline, lineWidth: 0.5) }
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        .accessibilityHidden(true)
        .task(id: contact) {
            guard let bundleID = contact.appBundleID else { loadedIcon = nil; return }
            let icon = await Task.detached(priority: .utility) {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            }.value
            if !Task.isCancelled { loadedIcon = icon }
        }
    }
}

/// Clawd's 9×5 pixel drawing snaps to device pixels on a dark disc.
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

/// Helpers and crews use quiet symbol tiles with a working rim.
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
