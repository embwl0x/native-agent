// NativeAgentTheme.swift — Design-system identity layer for NativeAgent iOS.
//
// Two-file split (mirrors swiftui-design-system convention):
//   • NativeAgentTheme.swift  — branding identity + heavyweight components
//                         that depend on color (GlassCard, GradientText,
//                         AuroraBackground, NativeAgentPalette).
//   • NativeAgentDesign.swift — design tokens (fonts, motion) + lightweight
//                         primitives (AppEmptyState, PulsingDot, Shimmer).
//
// "Tenant" here is the active NativeAgent persona.
// by id so future personas drop in cleanly.

import SwiftUI

// MARK: - Color hex helper

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Palette (per-identity tinting hook)

enum NativeAgentPalette {
    /// Stable accent pair for a given persona id.  NativeAgent gets the
    /// indigo→violet gradient; new personas land here without touching views.
    static func colorPair(for id: String) -> [Color] {
        switch id.lowercased() {
        case "nativeagent":
            return [Color(hex: 0x06B6D4), Color(hex: 0x0E7490)]   // cyan-500 → deep cyan-700
        default:
            return [Color(hex: 0x0891B2), Color(hex: 0x0E7490)]   // generic cyan
        }
    }

    static func accent(for id: String) -> Color {
        colorPair(for: id).first ?? .accentColor
    }

    static func gradient(for id: String) -> LinearGradient {
        LinearGradient(
            colors: colorPair(for: id),
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Default — call when caller doesn't have a specific id yet.
    static var agentAccent: Color { accent(for: "nativeagent") }
    static var agentGradient: LinearGradient { gradient(for: "nativeagent") }
}

// MARK: - GlassCard — material surface with optional accent border + shadow

struct GlassCard<Content: View>: View {
    var tint: Color? = nil
    var cornerRadius: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        let accent = tint ?? NativeAgentPalette.agentAccent
        content()
            .padding(18)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(RadialGradient(
                            colors: [accent.opacity(0.18), .clear],
                            center: .topLeading, startRadius: 5, endRadius: 240
                        ))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(accent.opacity(0.22), lineWidth: 0.8)
            }
            .shadow(color: accent.opacity(0.15), radius: 12, y: 4)
    }
}

// MARK: - GradientText — for hero titles

struct GradientText: View {
    let text: String
    var colors: [Color] = NativeAgentPalette.colorPair(for: "nativeagent")
    var font: Font = AppFont.title

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(LinearGradient(
                colors: colors,
                startPoint: .leading, endPoint: .trailing
            ))
    }
}

// MARK: - AuroraBackground — drifting blobs behind detail views

/// Subtle animated gradient blobs.  Place behind a view's content with a
/// `.background` modifier; opacity stays low so foreground text reads cleanly.
struct AuroraBackground: View {
    var tint: Color = NativeAgentPalette.agentAccent
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [tint.opacity(0.45), .clear],
                    center: .center, startRadius: 4, endRadius: 280
                ))
                .frame(width: 480, height: 480)
                .blur(radius: 50)
                .offset(x: drift ? -120 : 120, y: drift ? -180 : -100)
            Circle()
                .fill(RadialGradient(
                    colors: [Color(hex: 0x38BDF8).opacity(0.35), .clear],
                    center: .center, startRadius: 4, endRadius: 240
                ))
                .frame(width: 360, height: 360)
                .blur(radius: 60)
                .offset(x: drift ? 140 : -100, y: drift ? 200 : 140)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) {
                drift.toggle()
            }
        }
    }
}
