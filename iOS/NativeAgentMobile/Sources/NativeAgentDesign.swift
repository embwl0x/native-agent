// NativeAgentDesign.swift — Design tokens and reusable presentation primitives.

import SwiftUI
import UIKit
// Blueprint: | `NativeAgentDesign.swift` | `View`: `appShimmer` |

/// The app's animated ground stays outside the extension's shared glass tokens.
struct MobileRoomBackground: View {
    var body: some View { AliveRoom() }
}

enum NativeAgentPalette {
    static let agentAccent = Color(hex: 0x06B6D4)
}

// MARK: - Appearance

enum NativeAgentAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "NativeAgentMobile.appearance"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolved(_ rawValue: String) -> NativeAgentAppearance {
        NativeAgentAppearance(rawValue: rawValue) ?? .system
    }
}

// MARK: - Typography tokens

enum AppFont {
    static let display = Font.system(.largeTitle, design: .rounded, weight: .heavy)
    static let title   = Font.system(.title2,     design: .rounded, weight: .heavy)
    static let section = Font.system(.headline,   design: .rounded, weight: .bold)
    static let body    = Font.system(.body,       design: .rounded)
    static let label   = Font.system(.caption,    design: .rounded, weight: .semibold)
    static let tag     = Font.system(.caption2,   design: .rounded, weight: .bold)
    static let mono    = Font.system(.caption,    design: .monospaced)
}

// MARK: - Motion tokens

enum AppMotion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let gentle = Animation.spring(response: 0.55, dampingFraction: 0.88)
    static let drift  = Animation.easeInOut(duration: 8).repeatForever(autoreverses: true)
    static let pulse  = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    // chat-smoothness phase 6: subtle entrance for newly-inserted chat bubbles.
    // Triggered ONLY by withAnimation at the append seam (ChatStore.send) —
    // never by a list-level .animation key (gpt-5.5 r1 blocker: an id-list key
    // also animates wholesale replaces like the snapshot merge).
    static let entrance = Animation.easeOut(duration: 0.22)

    /// Reduce-motion-aware entrance for MODEL-layer mutation sites
    /// (withAnimation in ChatStore has no SwiftUI Environment) — reads the
    /// system setting directly.
    @MainActor static var entranceSystem: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : entrance
    }

    /// chat-smoothness phase 6: reduce-motion gate. Returns nil (the change is
    /// applied instantly with no movement) when the system Reduce Motion
    /// accessibility setting is on; otherwise the given animation.
    static func respecting(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - PulsingDot — live indicator

struct PulsingDot: View {
    var color: Color = NativeAgentPalette.agentAccent
    var size: CGFloat = 8
    var isActive = true
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if isActive && scenePhase == .active && !reduceMotion {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(pulse ? 1 : 0.5)
                    .opacity(pulse ? 0 : 0.6)
                    .onAppear {
                        pulse = false
                        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
                    }
            } else {
                Circle().fill(color.opacity(0.35))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(0.5).opacity(0.6)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.7), radius: 3)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Shimmer — loading-state diagonal sweep

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.overlay {
                GeometryReader { geo in
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0),   location: 0),
                        .init(color: .white.opacity(0.35), location: 0.5),
                        .init(color: .white.opacity(0),   location: 1),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: geo.size.width * 1.6)
                    .offset(x: geo.size.width * phase)
                    .blendMode(.plusLighter)
                    .onAppear {
                        withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                            phase = 1.4
                        }
                    }
                }
                .mask(content)
            }
        }
    }
}

extension View {
    func appShimmer() -> some View { modifier(Shimmer()) }
}
