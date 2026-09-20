// MoodTint.swift
// "Mood in the tint" — User and Agent approved the mocks 2026-09-14
// (mockups/mood-tint/rest.png, warm.png, NOTE.md). This file is the whole
// feature: the scalar source, the damping, the cap, the accessibility
// collapse, and the one modifier the glass wears. Pull this file and the
// switch in `MoodTintPreference`, and the shell is exactly what it was.
//
// THE ONE AXIS. Dark mode ↔ a breath of warmth. `level` is a single 0…1
// scalar; 0 IS today's dark mode, unchanged and undescribed, and 1 is the cap.
// There is no cool end and no second axis.
//
// WHY CONTRAST CANNOT BUDGE. The warm hue is composited with `BlendMode.color`,
// which carries the source's hue and saturation and keeps the BACKDROP's
// luminosity. Relative luminance is preserved by construction, so every
// text/ground ratio in the window is unchanged. The cap governs how much
// colour arrives, never how much light.
//
// WHERE IT LANDS. One pass over the window, masked: white where the warmth is
// allowed — the rail, the room ground, the composer — and punched out, softly,
// over the transcript's reading column. Nothing under the prose. A settled
// card sits INSIDE that punch-out and has no fill of its own (its ground is
// the room showing through a hairline box), so it takes the warmth back with
// its own local pass — one tint, never two.

import AppKit
import CognitiveSubstrate
import SwiftUI

// MARK: - The switch

/// The revert seam. On for a fresh install (User: fresh installs turn every
/// feature on; users switch off what they want), off in one flip, and the same
/// key the agent reads and writes through `app_settings_list` /
/// `app_setting_set`.
enum MoodTintPreference {
    static let key = "uiMoodTint"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}

// MARK: - The weather

/// The scalar source, the low-pass and the drain. One number, damped in time.
/// The LEVEL is persisted so a relaunch resumes where the room was; the elapsed
/// baseline is not, so no shutdown gap and no clock change is ever integrated.
@MainActor
@Observable
final class MoodTintWeather {
    static let shared = MoodTintWeather()

    /// The cap. 0.10 of the warm hue at `BlendMode.color` measures ΔE00 ≈ 3 on
    /// the glass against the same pixel at rest — a breath, not a colour.
    /// Chroma on a near-neutral dark ground is read far more readily than a
    /// luminance nudge of the same size, which is why this can be so small and
    /// still be felt.
    static let cap: Double = 0.10

    /// The hue: the room's own lamp colour (`ShellLamp`), pulled down so it
    /// reads as the room warming rather than as a second light.
    static let hue = Color(red: 1.0, green: 0.84, blue: 0.66)

    /// Hours, not seconds. One warm turn moves the room by roughly 4% of the
    /// gap; reaching the cap from rest takes about 12 hours (3 time constants).
    /// Nothing can flicker, because nothing can move fast.
    static let timeConstantHours: Double = 4

    /// The clock the value moves on. Never faster: the damping is measured in
    /// hours, so a faster sample buys nothing and costs a wake.
    static let sampleSeconds: TimeInterval = 60

    private static let levelKey = "uiMoodTintLevel"

    /// The damped value the glass wears, 0…1. Multiplied by `cap` at the glass.
    private(set) var level: Double

    private let defaults: UserDefaults
    /// The baseline for the live delta, on the MONOTONIC clock. Only the LEVEL
    /// survives a launch; the elapsed time does not. Integrating wall-clock
    /// time across a shutdown means the first post-launch tick applies hours
    /// (or, on a clock jump, anything at all) in one step and the tint snaps.
    /// The room resumes where it was and moves only while the app is running.
    private var updatedAtUptime: TimeInterval
    private var timer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.level = min(1, max(0, defaults.double(forKey: Self.levelKey)))
        self.updatedAtUptime = Self.uptime()
    }

    /// Monotonic, and unaffected by the wall clock being set. It also does not
    /// advance while the machine is asleep, which is what we want: a closed lid
    /// is not weather.
    static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Idempotent. The shell starts this when the window appears; a second
    /// window does not start a second clock.
    func begin() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.sampleSeconds, repeats: true) { _ in
            Task { @MainActor in await MoodTintWeather.shared.tick() }
        }
        timer.tolerance = Self.sampleSeconds / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One step of the filter, toward whatever the reading is. The drain is the
    /// same filter running toward 0 — no separate path, no snap back, no decay
    /// curve of its own. Rest is not a state the tint is put into; it is where
    /// the filter goes when nothing holds it up.
    func tick(uptime now: TimeInterval = MoodTintWeather.uptime()) async {
        let reading = await Self.reading()
        let elapsedHours = max(0, now - updatedAtUptime) / 3600
        level = Self.damped(previous: level, reading: reading, elapsedHours: elapsedHours)
        updatedAtUptime = now
        defaults.set(level, forKey: Self.levelKey)
    }

    /// The one-pole low-pass, and the whole of the damping:
    /// `w(now) = w(prev) + (reading − w(prev)) · (1 − e^(−Δt / τ))`.
    static func damped(previous: Double, reading: Double, elapsedHours: Double) -> Double {
        let alpha = 1 - exp(-max(0, elapsedHours) / timeConstantHours)
        return min(1, max(0, previous + (reading - previous) * alpha))
    }

    /// ONE scalar from whatever agent is running, read the way `inner_state`'s
    /// tool reads it: the same pure projection off the live cognition runtime,
    /// no new store, no second owner, no agent named anywhere in the path.
    ///
    /// `inner_state` exposes warmth in exactly one place — the warmth stamped
    /// on each felt moment — so the scalar is those moments' mean. With
    /// cognition off the reading is `available: false` and the answer is 0:
    /// absence reads as absence, and the room drains to plain dark mode.
    private static func reading() async -> Double {
        let reading = await NativeCognitionRuntime.shared.innerStateReading(
            windowHours: CognitiveInnerStateReading.defaultWindowHours,
            detail: .compact
        )
        guard reading.available, !reading.feltNodes.isEmpty else { return 0 }
        let sum = reading.feltNodes.reduce(0.0) { $0 + $1.warmth }
        return min(1, max(0, sum / Double(reading.feltNodes.count)))
    }
}

// MARK: - The seam the views use

extension EnvironmentValues {
    /// Explicit override, used by the headless renderer to put the glass at a
    /// known scalar. Never persisted, never set by the app.
    @Entry var moodTintLevelOverride: Double? = nil

    /// TRUE ONLY INSIDE A PUNCHED-OUT PROSE REGION. The local card pass exists
    /// for exactly one situation: a clear-filled card sitting in the band the
    /// window pass was masked out of, which would otherwise be the one surface
    /// in the room that never warms. Anywhere else the window pass already
    /// reached the card, and a second pass is a second tint — visible as a
    /// doubled wash, and worse at the card's edges where the 26pt feathered
    /// knockout and the card's own hard-edged shape overlap. `moodTintSurface`
    /// is therefore inert unless a `moodTintProseGuard` above it says the
    /// warmth was taken away here.
    @Entry var moodTintProseGuarded: Bool = false
}

enum MoodTintSpace {
    static let name = "moodTint.window"
}

/// The reading column's viewport, in the window's mood-tint space. One rect for
/// the whole transcript — not one per row, which would put a preference write
/// on every visible message on every scrolled frame.
struct MoodTintProseRectKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// The window pass. One masked composite over the whole shell.
    func moodTintWindow() -> some View { modifier(MoodTintWindowPass()) }

    /// Publishes the band the warmth is kept OUT of: the reading column, across
    /// the transcript's visible region. `columnWidth` and `leadingInset` are the
    /// shell's own reading-column metrics, taken from the call site so this file
    /// owns no layout.
    func moodTintProseGuard(columnWidth: CGFloat, leadingInset: CGFloat) -> some View {
        background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named(MoodTintSpace.name))
                let insets = geometry.safeAreaInsets
                Color.clear.preference(
                    key: MoodTintProseRectKey.self,
                    value: CGRect(
                        // A little wider than the words themselves: the prose
                        // and its immediate background, per the mock.
                        x: frame.minX + leadingInset - 24,
                        y: frame.minY + insets.top,
                        width: columnWidth + 48,
                        height: max(0, frame.height - insets.top - insets.bottom)
                    )
                )
            }
        }
        .environment(\.moodTintProseGuarded, true)
    }

    /// The same guard for a viewport whose prose fills the block rather than a
    /// measured reading column — the Bots session transcript, which draws
    /// `MessageBubble` under the window pass like any other conversation and
    /// has just as much claim to an unwarmed prose ground.
    func moodTintProseGuard() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MoodTintProseRectKey.self,
                    value: geometry.frame(in: .named(MoodTintSpace.name)))
            }
        }
        .environment(\.moodTintProseGuarded, true)
    }

    /// A surface that sits inside the prose guard and still takes the warmth.
    /// The settled card is the only one: its fill is clear, so what warms is the
    /// room showing through it, and the window pass cannot reach it.
    func moodTintSurface(in shape: some Shape) -> some View {
        modifier(MoodTintSurfacePass(shape: AnyShape(shape)))
    }
}

// MARK: - The passes

/// Everything that decides whether there is any warmth at all, in one place and
/// as a pure function of what the environment says — so the collapse can be
/// exercised without a window.
@MainActor
enum MoodTintGate {
    /// 0 collapses the feature entirely: the flag off, the light appearance
    /// (the mocks are dark mode, and rest IS dark mode untouched), and both
    /// accessibility requests. Reduce Transparency and Increase Contrast are
    /// asks for a plainer, harder-edged room; a mood wash is the opposite, so
    /// it goes to nothing rather than to less.
    ///
    /// The collapse wins over everything, the renderer's override included: an
    /// override supplies the SCALAR, never permission to ignore an
    /// accessibility request.
    static func level(
        enabled: Bool,
        scheme: ColorScheme,
        reduceTransparency: Bool,
        contrast: ColorSchemeContrast,
        override: Double?,
        weather: Double
    ) -> Double {
        guard enabled, scheme == .dark, !reduceTransparency, contrast != .increased else { return 0 }
        return min(1, max(0, override ?? weather))
    }
}

private struct MoodTintWindowPass: ViewModifier {
    @AppStorage(MoodTintPreference.key) private var enabled = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.moodTintLevelOverride) private var levelOverride
    @State private var weather = MoodTintWeather.shared

    private var level: Double {
        MoodTintGate.level(enabled: enabled, scheme: scheme,
                           reduceTransparency: reduceTransparency, contrast: contrast,
                           override: levelOverride, weather: MoodTintWeather.shared.level)
    }

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(MoodTintSpace.name))
            .overlayPreferenceValue(MoodTintProseRectKey.self) { prose in
                if level > 0 {
                    // Mask first, then blend: the shape of the pass is decided
                    // before what it does to the light underneath it.
                    MoodTintWeather.hue
                        .opacity(MoodTintWeather.cap * level)
                        .mask { mask(prose: prose) }
                        .blendMode(.color)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }
            }
            .onAppear { weather.begin() }
    }

    /// White where the warmth is allowed, punched out over the prose. The
    /// punch-out is feathered by 26pt: a hard edge would be a drawn rectangle
    /// on glass, and a boundary in this shell is a material change, never a line.
    private func mask(prose: CGRect?) -> some View {
        Rectangle()
            .fill(.white)
            .overlay(alignment: .topLeading) {
                if let prose, prose.width > 0, prose.height > 0 {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.white)
                        .frame(width: prose.width, height: prose.height)
                        .blur(radius: 26)
                        .offset(x: prose.minX, y: prose.minY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .ignoresSafeArea()
    }
}

private struct MoodTintSurfacePass: ViewModifier {
    let shape: AnyShape
    @AppStorage(MoodTintPreference.key) private var enabled = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.moodTintLevelOverride) private var levelOverride
    @Environment(\.moodTintProseGuarded) private var inProseGuard

    private var level: Double {
        // One tint, never two: outside a punched-out prose region the window
        // pass already warmed this card, so the local pass is nothing at all.
        guard inProseGuard else { return 0 }
        return MoodTintGate.level(enabled: enabled, scheme: scheme,
                                  reduceTransparency: reduceTransparency, contrast: contrast,
                                  override: levelOverride, weather: MoodTintWeather.shared.level)
    }

    func body(content: Content) -> some View {
        content.overlay {
            if level > 0 {
                // No `compositingGroup()` here on purpose: the blend has to
                // reach the room behind the card, which is the whole point.
                shape
                    .fill(MoodTintWeather.hue)
                    .opacity(MoodTintWeather.cap * level)
                    .blendMode(.color)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - What the agent can read

@MainActor
enum MoodTintProjection {
    /// One read-only line for `app_page_read`, so the tint can be driven and
    /// checked headless. The switch itself is a settings row, not a line here.
    static func line(_ defaults: UserDefaults = .standard) -> String {
        guard MoodTintPreference.isEnabled(defaults) else {
            return "Warmth in the glass: off."
        }
        let level = MoodTintWeather.shared.level
        let percent = Int((level * 100).rounded())
        return "Warmth in the glass: \(percent)% of the cap "
            + "(\(String(format: "%.3f", level * MoodTintWeather.cap)) of the warm hue)."
    }
}
