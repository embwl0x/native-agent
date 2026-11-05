import AppToolRuntime
import NativeAgentCore
import NativeAgentShared

// Blueprint: | `MoodTint.swift` | Canonical mood sampling, capped damping and accessibility-aware glass |

import AppKit
import Cognition
import CognitiveSubstrate
import SwiftUI

// MARK: - The weather

/// Persist the level, not the elapsed baseline, so relaunch and clock changes cannot integrate shutdown time.
@MainActor
@Observable
final class MoodTintWeather {
    static let shared = MoodTintWeather()

    /// Cap warm colour at 0.10 (~ΔE00 3 on glass): near-neutral dark grounds make small chroma shifts readily visible.
    static let cap: Double = 0.10

    static let hue = Color(red: 1.0, green: 0.84, blue: 0.66)

    /// A four-hour time constant moves about 4% per warm turn and takes ~12 hours to reach the cap, preventing flicker.
    static let timeConstantHours: Double = 4

    /// At a four-hour time constant, five-minute display steps move at most 2% of the gap; cognition supplies the input.
    static let sampleSeconds: TimeInterval = 300

    private static let levelKey = "uiMoodTintLevel"

    private(set) var level: Double

    private let defaults: UserDefaults
    /// Use a monotonic live baseline so shutdown time and wall-clock jumps cannot snap the tint.
    private var updatedAtUptime: TimeInterval
    private var timer: Timer?
    private var observation: Task<Void, Never>?
    private var target = 0.0
    private let latest = LatestRead()
    private var consumers: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.level = min(1, max(0, defaults.double(forKey: Self.levelKey)))
        self.updatedAtUptime = Self.uptime()
    }

    /// The clock must ignore wall-clock changes and sleep so a closed lid does not advance the room's tint.
    static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func setConsumer(_ id: UUID, enabled: Bool) {
        if enabled { consumers.insert(id) } else { consumers.remove(id) }
        refreshVisibility()
    }

    func refreshVisibility() {
        guard !consumers.isEmpty else { stop(); return }
        guard timer == nil else { return }
        updatedAtUptime = Self.uptime()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.sampleSeconds, repeats: true) { _ in
            Task { @MainActor in MoodTintWeather.shared.advance() }
        }
        timer.tolerance = Self.sampleSeconds / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observation = Task {
            let changes = await NativeAgentEngine.live.cognitionView.changes()
            await tick()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await tick()
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        timer?.invalidate()
        timer = nil
    }

    /// Drain with the same filter toward zero so releasing warmth cannot snap or introduce a second decay path.
    func tick() async {
        guard let timer else { return }
        _ = await latest.read({ await Self.reading() }, publish: { reading in
        guard !Task.isCancelled, self.timer === timer else { return }
        advance()
        target = reading
        })
    }

    private func advance(uptime now: TimeInterval = MoodTintWeather.uptime()) {
        guard timer != nil else { return }
        let elapsedHours = max(0, now - updatedAtUptime) / 3600
        level = Self.damped(previous: level, reading: target, elapsedHours: elapsedHours)
        updatedAtUptime = now
        defaults.set(level, forKey: Self.levelKey)
    }

    /// Use one-pole damping: w(now) = w(prev) + (reading − w(prev)) × (1 − exp(−Δt / τ)).
    static func damped(previous: Double, reading: Double, elapsedHours: Double) -> Double {
        let alpha = 1 - exp(-max(0, elapsedHours) / timeConstantHours)
        return min(1, max(0, previous + (reading - previous) * alpha))
    }

    /// Average canonical felt-moment warmth without a second owner; unavailable cognition supplies zero so the room drains.
    private static func reading() async -> Double {
        await NativeAgentEngine.live.cognitionView.moodWarmth()
    }
}

// MARK: - The seam the views use

extension EnvironmentValues {
    /// Apply local tint only inside the prose guard; elsewhere the window pass already warms the card and a second pass would double it.
    @Entry var moodTintProseGuarded: Bool = false
}

enum MoodTintSpace {
    static let name = "moodTint.window"
}

/// Publish one viewport rect so scrolling cannot cause a preference write per visible message.
struct MoodTintProseRectKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

extension View {
    func moodTintWindow() -> some View { modifier(MoodTintWindowPass()) }

    /// Take reading-column metrics from the caller so the prose mask cannot become a second layout owner.
    func moodTintProseGuard(columnWidth: CGFloat, leadingInset: CGFloat) -> some View {
        background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named(MoodTintSpace.name))
                let insets = geometry.safeAreaInsets
                Color.clear.preference(
                    key: MoodTintProseRectKey.self,
                    value: CGRect(
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

    func moodTintSurface(in shape: some Shape) -> some View {
        modifier(MoodTintSurfacePass(shape: AnyShape(shape)))
    }
}

// MARK: - The passes

@MainActor
enum MoodTintGate {
    /// Disable warmth for light appearance, Reduce Transparency and Increase Contrast so appearance and accessibility requests remain plain.
    static func level(
        enabled: Bool,
        scheme: ColorScheme,
        reduceTransparency: Bool,
        contrast: ColorSchemeContrast,
        weather: Double
    ) -> Double {
        guard enabled, scheme == .dark, !reduceTransparency, contrast != .increased else { return 0 }
        return min(1, max(0, weather))
    }
}

private struct MoodTintWindowPass: ViewModifier {
    @AppStorage(MoodTintPreference.key) private var enabled = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var samples: Bool {
        enabled && scheme == .dark && !reduceTransparency && contrast != .increased
    }

    private var level: Double {
        MoodTintGate.level(enabled: enabled, scheme: scheme,
                           reduceTransparency: reduceTransparency, contrast: contrast,
                           weather: MoodTintWeather.shared.level)
    }

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(MoodTintSpace.name))
            .overlayPreferenceValue(MoodTintProseRectKey.self) { prose in
                if level > 0 {
                    // Mask before blending so the shape is fixed before it changes underlying light.
                    MoodTintWeather.hue
                        .opacity(MoodTintWeather.cap * level)
                        .mask { mask(prose: prose) }
                        .blendMode(.color)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }
            }
            .background { MoodTintSampling(enabled: samples).allowsHitTesting(false) }
    }

    /// Feather the prose knockout by 26pt to avoid drawing a hard rectangle on glass.
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

private struct MoodTintSampling: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> Sampler { Sampler() }
    func updateNSView(_ view: Sampler, context: Context) {
        view.enabled = enabled
        view.refresh()
    }
    static func dismantleNSView(_ view: Sampler, coordinator: ()) { view.detach() }

    final class Sampler: NSView {
        let id = UUID()
        var enabled = false
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
            refresh()
        }

        func refresh() {
            MoodTintWeather.shared.setConsumer(id,
                enabled: enabled && window?.isVisible == true && window?.occlusionState.contains(.visible) == true)
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            MoodTintWeather.shared.setConsumer(id, enabled: false)
        }
    }
}

private struct MoodTintSurfacePass: ViewModifier {
    let shape: AnyShape
    @AppStorage(MoodTintPreference.key) private var enabled = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.moodTintProseGuarded) private var inProseGuard

    private var level: Double {
        // Apply no local pass outside the prose guard because the window has already tinted that card.
        guard inProseGuard else { return 0 }
        return MoodTintGate.level(enabled: enabled, scheme: scheme,
                                  reduceTransparency: reduceTransparency, contrast: contrast,
                                  weather: MoodTintWeather.shared.level)
    }

    func body(content: Content) -> some View {
        content.overlay {
            if level > 0 {
                // Blend through to the room behind the card; compositingGroup would isolate it.
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
enum MoodTintReadout {
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
