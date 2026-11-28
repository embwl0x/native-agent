import Foundation
import AppKit
import SwiftUI
import NativeAgentShared
// Blueprint: | `MoodTint.swift` | Feed warmth drives local display damping; window visibility owns the animation timer |

@MainActor
@Observable
final class MoodTintWeather {
    static let shared = MoodTintWeather()
    static let cap: Double = 0.10
    static let hue = Color(red: 1.0, green: 0.84, blue: 0.66)
    static let timeConstantHours: Double = 4
    static let sampleSeconds: TimeInterval = 300
    private static let levelKey = "uiMoodTintLevel"
    private(set) var level: Double
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updatedAtUptime: TimeInterval
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var target: Double?
    @ObservationIgnored private var consumers: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.double(forKey: Self.levelKey)
        level = saved.isFinite ? min(1, max(0, saved)) : 0
        updatedAtUptime = Self.uptime()
    }

    static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func setConsumer(_ id: UUID, enabled: Bool) {
        let wasVisible = !consumers.isEmpty
        if enabled { consumers.insert(id) } else { consumers.remove(id) }
        if !wasVisible, !consumers.isEmpty { updatedAtUptime = Self.uptime() }
        updateTimer()
    }

    func receive(_ warmth: Double?) {
        advance()
        target = warmth.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        updatedAtUptime = Self.uptime()
        updateTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func advance(uptime now: TimeInterval = MoodTintWeather.uptime()) {
        guard !consumers.isEmpty, let target else { return }
        let elapsedHours = max(0, now - updatedAtUptime) / 3600
        let next = Self.damped(previous: level, reading: target, elapsedHours: elapsedHours)
        updatedAtUptime = now
        if next != level {
            level = next
            defaults.set(next, forKey: Self.levelKey)
        }
        updateTimer()
    }

    private func updateTimer() {
        guard !consumers.isEmpty, let target, level != target else { stop(); return }
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.sampleSeconds, repeats: true) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.advance() }
        }
        timer.tolerance = Self.sampleSeconds / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func damped(previous: Double, reading: Double, elapsedHours: Double) -> Double {
        let alpha = 1 - exp(-max(0, elapsedHours) / timeConstantHours)
        return min(1, max(0, previous + (reading - previous) * alpha))
    }
}

// MARK: - The seam the views use

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
    func moodTintProseGuard(columnWidth: CGFloat, visible: Bool) -> some View {
        background {
            if visible {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .named(MoodTintSpace.name))
                    let insets = geometry.safeAreaInsets
                    let width = min(columnWidth, frame.width)
                    Color.clear.preference(
                        key: MoodTintProseRectKey.self,
                        value: CGRect(
                            x: frame.midX - width / 2 - 24,
                            y: frame.minY + insets.top,
                            width: width + 48,
                            height: max(0, frame.height - insets.top - insets.bottom)
                        )
                    )
                }
            }
        }
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
    @FacePreference("uiMoodTint") private var enabled = true
    @Environment(AppModel.self) private var appModel
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
        preferenceContent(content)
    }

    private func preferenceContent(_ content: Content) -> some View {
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
            .faceObservation(.key(.mood))
            .onChange(of: appModel.face.slot(.mood).select("warmth", as: MoodFace.self) { face -> Double? in
                guard case .ready? = face?.state else { return nil }
                return face?.warmth
            }, initial: true) { _, warmth in MoodTintWeather.shared.receive(warmth) }
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
                    Task { @MainActor [weak self] in self?.refresh() }
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
