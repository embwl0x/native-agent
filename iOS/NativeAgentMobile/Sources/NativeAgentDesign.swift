// NativeAgentDesign.swift — Design tokens (fonts, motion) + small reusable primitives.
//
// Companion to NativeAgentTheme.swift.  Tokens here have no color identity baked in,
// so they're safe to use anywhere; per-persona color comes from NativeAgentPalette.

import SwiftUI
import UIKit

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
    static let bouncy = Animation.spring(response: 0.45, dampingFraction: 0.65)
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
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(pulse ? 1 : 0.5)
                .opacity(pulse ? 0 : 0.6)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.7), radius: 3)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
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

// MARK: - AppEmptyState — animated replacement for ContentUnavailableView

struct AppEmptyState: View {
    let title: String
    let systemImage: String
    var description: String? = nil
    var tint: Color = NativeAgentPalette.agentAccent
    var action: (title: String, systemImage: String, handler: () -> Void)? = nil

    @State private var drift = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [tint.opacity(0.55), .clear],
                        center: .center, startRadius: 4, endRadius: 90
                    ))
                    .frame(width: 180, height: 180)
                    .blur(radius: 20)
                    .scaleEffect(pulse ? 1.08 : 0.92)
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [tint, Color(hex: 0x38BDF8), Color(hex: 0x0E7490), tint],
                            center: .center
                        ),
                        lineWidth: 2
                    )
                    .frame(width: 96, height: 96)
                    .rotationEffect(.degrees(drift ? 360 : 0))
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 82, height: 82)
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(LinearGradient(
                        colors: [
                            colorScheme == .dark ? .white : Color(hex: 0x0E7490),
                            tint.opacity(0.85),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .symbolRenderingMode(.hierarchical)
                    .shadow(color: tint.opacity(0.55), radius: 10, y: 2)
            }
            VStack(spacing: 6) {
                Text(title).font(AppFont.title)
                if let description {
                    Text(description)
                        .font(AppFont.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            }
            if let action {
                Button(action: action.handler) {
                    Label(action.title, systemImage: action.systemImage)
                        .font(AppFont.section)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                drift = true
            }
            withAnimation(AppMotion.pulse) {
                pulse = true
            }
        }
    }
}

// MARK: - StatCard — small data-point card with optional sheen

struct StatCard: View {
    let label: String
    let value: String
    var systemImage: String? = nil
    var tint: Color = NativeAgentPalette.agentAccent

    @State private var sheenPhase: CGFloat = -1
    @State private var sheenDelay: Double = Double.random(in: 2...8)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(AppFont.label)
                        .foregroundStyle(tint)
                }
                Text(label.uppercased())
                    .font(AppFont.tag)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(AppFont.title)
                .foregroundStyle(.primary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(RadialGradient(
                        colors: [tint.opacity(0.16), .clear],
                        center: .topLeading, startRadius: 5, endRadius: 180
                    ))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 0.6)
        }
        .overlay(alignment: .topLeading) {
            // Subtle once-in-a-while sheen sweep
            GeometryReader { geo in
                LinearGradient(stops: [
                    .init(color: .white.opacity(0),   location: 0),
                    .init(color: .white.opacity(0.18), location: 0.5),
                    .init(color: .white.opacity(0),   location: 1),
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: geo.size.width * 1.6)
                .offset(x: geo.size.width * sheenPhase)
                .blendMode(.plusLighter)
                .mask(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + sheenDelay) {
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                    sheenPhase = 1.4
                }
            }
        }
    }
}
