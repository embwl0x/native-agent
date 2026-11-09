import NativeAgentShared
import SwiftUI

// Blueprint: | `ThinkingGlow.swift` | `ThinkingGlow`: leaf-layer working shimmer and composer rim driven by turn state, fading when reply text begins |

// Read lifecycle signals only in this leaf so ticks cannot invalidate the composer or transcript.
// Let Core Animation drive overlay motion without app-side frames or layout proposals.
// Keep fade state local so its animation transaction cannot reach other views.

/// Put shimmer beneath glass and rim above it so neither competes with content.
struct ThinkingGlow: View {
    enum Kind { case shimmer, rim, workingRim }
    let kind: Kind
    let cornerRadius: CGFloat
    /// Bind detached composers to their own session instead of the main chat.
    var sessionId: String? = nil
    /// Keep working light on through tools and replies until settlement.
    var wholeTurn = false
    /// Missing models in snapshots or panels must leave the light absent.
    @Environment(AppModel.self) private var appModel: AppModel?

    var body: some View {
        ThinkingGlowLayer(
            kind: kind,
            cornerRadius: cornerRadius,
            thinking: appModel.map { model in
                let sessionId = sessionId ?? model.activeChatSessionId
                return wholeTurn ? model.turnPart("isWorking", for: sessionId) { $0?.isWorking == true }
                    : model.turnPart("isThinking", for: sessionId) { $0?.isThinking == true }
            } ?? false
        )
    }
}

private struct ThinkingGlowLayer: View {
    let kind: ThinkingGlow.Kind
    let cornerRadius: CGFloat
    let thinking: Bool

    @FacePreference(HazeColor.storageKey) private var hazeRaw = HazeColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Read fade state only here so its animation cannot invalidate parent views.
    @State private var shown = false
    /// Retain motion through fade-out so the light does not freeze while disappearing.
    @State private var running = false

    static let fade = 0.4
    static let rimPeriod = 2.6
    /// A full there-and-back takes twice this duration.
    static let shimmerSlide = 3.0

    var body: some View {
        FacePreferences(keys: [HazeColor.storageKey]) { preferenceContent }
    }

    @ViewBuilder private var preferenceContent: some View {
        Group {
            if running { effect }
        }
        .opacity(shown ? 1 : 0)
        .onChange(of: thinking, initial: true) { _, now in
            if now { running = true }
            withAnimation(.easeInOut(duration: Self.fade)) {
                shown = now
            } completion: {
                if !shown { running = false }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var effect: some View {
        let haze = HazeColor(stored: hazeRaw)
        if reduceMotion {
            // Reduce Motion keeps a brighter stationary rim so working state stays visible without travel.
            if kind == .rim {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(haze.edgeLight.opacity(0.42), lineWidth: 1.5)
            }
        } else {
            // Extend the layer past the host so glass edges cannot clip the glow.
            ThinkingLightLayer(kind: kind, cornerRadius: cornerRadius, haze: haze)
                .padding(kind == .rim ? -Self.rimBleed : 0)
        }
    }

    static let rimBleed: CGFloat = 12
}

/// Render-server animation shares wall-clock phase for composers while avatars keep independent revolutions.
private struct ThinkingLightLayer: NSViewRepresentable {
    let kind: ThinkingGlow.Kind
    let cornerRadius: CGFloat
    let haze: HazeColor

    func makeNSView(context: Context) -> LightView { LightView(kind: kind) }
    func updateNSView(_ view: LightView, context: Context) { view.apply(haze: haze, cornerRadius: cornerRadius) }

    final class LightView: NSView {
        private let kind: ThinkingGlow.Kind
        private var applied: (HazeColor, CGFloat)?
        private let content = CALayer()
        // Cast an offscreen layer's shadow back into view; CIFilter would pull rendering into the app.
        private let glow = CALayer()
        private let glowRing = CALayer()
        private let glowMask = CAShapeLayer()
        private let glowComet = CAGradientLayer()
        private let ring = CALayer()
        private let ringMask = CAShapeLayer()
        private let comet = CAGradientLayer()
        private let clip = CAShapeLayer()
        private let pools = [CAGradientLayer(), CAGradientLayer()]

        init(kind: ThinkingGlow.Kind) {
            self.kind = kind
            super.init(frame: .zero)
            wantsLayer = true
            content.masksToBounds = kind != .workingRim
            layer?.addSublayer(content)
            switch kind {
            case .rim, .workingRim:
                let avatar = kind == .workingRim
                glow.shadowOpacity = avatar ? 0.9 : 0.5
                glow.shadowRadius = avatar ? 4 : 6
                for (holder, mask, gradient) in rimLayers {
                    mask.fillColor = nil
                    mask.strokeColor = NSColor.black.cgColor
                    holder.mask = mask
                    // CA conic gradients run anticlockwise; reverse SwiftUI stops to preserve the comet direction.
                    gradient.type = .conic
                    gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
                    gradient.endPoint = avatar ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 1, y: 0.5)
                    gradient.locations = cometStops.map { NSNumber(value: $0.location) }
                    holder.addSublayer(gradient)
                }
                glowMask.lineWidth = 4
                ringMask.lineWidth = avatar ? 2.5 : 2
                glow.addSublayer(avatar ? ring : glowRing)
                content.addSublayer(glow)
                if !avatar { content.addSublayer(ring) }
            case .shimmer:
                content.mask = clip
                for pool in pools {
                    pool.type = .radial
                    pool.startPoint = CGPoint(x: 0.5, y: 0.5)
                    pool.endPoint = CGPoint(x: 1, y: 1)
                    content.addSublayer(pool)
                }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private var rimLayers: [(CALayer, CAShapeLayer, CAGradientLayer)] {
            kind == .workingRim ? [(ring, ringMask, comet)] : [(glowRing, glowMask, glowComet), (ring, ringMask, comet)]
        }

        private var cometStops: [(location: Double, alpha: Double)] {
            let avatar = kind == .workingRim
            let arc = (avatar ? 70.0 : 130.0) / 360.0, lead = 4.0 / 360.0
            let stops: [(location: Double, alpha: Double)] = [
                (0, 0), (0.5 - arc, 0), (0.5 - arc * 0.4, avatar ? 0.6 : 0.35), (0.5, 1), (0.5 + lead, 0), (1, 0),
            ]
            return avatar ? stops : stops.reversed().map { (1 - $0.location, $0.alpha) }
        }

        func apply(haze: HazeColor, cornerRadius: CGFloat) {
            if let applied, applied.0 == haze, applied.1 == cornerRadius { return }
            applied = (haze, cornerRadius)
            let light = NSColor(haze.edgeLight)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            switch kind {
            case .rim, .workingRim:
                for (_, _, gradient) in rimLayers {
                    gradient.colors = cometStops.map { light.withAlphaComponent($0.alpha).cgColor }
                }
                if kind == .workingRim { ring.backgroundColor = light.withAlphaComponent(0.22).cgColor }
                glow.shadowColor = light.cgColor
            case .shimmer:
                for pool in pools { pool.colors = [light.cgColor, light.withAlphaComponent(0).cgColor] }
            }
            CATransaction.commit()
            needsLayout = true
        }

        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }

        override func layout() {
            super.layout()
            guard let applied, bounds.width > 0, bounds.height > 0 else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let scale = window?.backingScaleFactor ?? 2
            for layer in [content, glow, glowRing, glowMask, glowComet, ring, ringMask, comet, clip] + pools {
                layer.contentsScale = scale
            }
            content.frame = bounds
            switch kind {
            case .rim, .workingRim: layoutRim(cornerRadius: applied.1)
            case .shimmer: layoutShimmer(cornerRadius: applied.1)
            }
            CATransaction.commit()
        }

        private func layoutRim(cornerRadius: CGFloat) {
            let avatar = kind == .workingRim
            let inset = avatar ? WorkingRim.bleed - 1 : ThinkingGlowLayer.rimBleed + 1
            let path = RoundedRectangle(cornerRadius: avatar ? cornerRadius + 1 : max(0, cornerRadius - 1), style: .continuous)
                .path(in: bounds.insetBy(dx: inset, dy: inset)).cgPath
            let away = avatar ? 0 : bounds.width + 64
            glow.frame = bounds.offsetBy(dx: -away, dy: 0)
            glow.shadowOffset = CGSize(width: away, height: 0)
            // Size the square to contain the ring throughout rotation.
            let side = hypot(bounds.width, bounds.height)
            for (holder, mask, gradient) in rimLayers {
                holder.frame = bounds
                mask.frame = bounds
                mask.path = path
                gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
                // Preserve avatar phase across layout while synchronizing composer rims to the clock.
                if avatar, gradient.animation(forKey: "turn") != nil { continue }
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = ThinkingGlowLayer.rimPeriod
                spin.repeatCount = .infinity
                if avatar {
                    spin.timingFunction = CAMediaTimingFunction(name: .linear)
                    spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                } else {
                    spin.timeOffset = Self.phase(ThinkingGlowLayer.rimPeriod)
                }
                gradient.add(spin, forKey: "turn")
            }
        }

        private func layoutShimmer(cornerRadius: CGFloat) {
            let size = bounds.size
            clip.frame = bounds
            clip.path = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: bounds).cgPath
            let wide = size.width >= size.height
            let radius = max(min(size.width, size.height) * 1.3, 60)
            // A full sine cycle spans two slides for a continuous there-and-back.
            let period = ThinkingGlowLayer.shimmerSlide * 2
            let thetas = (0...96).map { Double($0) / 96 * 2 * .pi }
            for (pool, (across, sign)) in zip(pools, [(0.3, 1.0), (0.75, -1.0)]) {
                pool.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
                // Invert SwiftUI's downward y axis for the layer's upward coordinates.
                func center(_ theta: Double) -> NSValue {
                    let along = 0.5 + sign * 0.55 * sin(theta)
                    return NSValue(point: wide
                        ? CGPoint(x: size.width * along, y: size.height * (1 - across))
                        : CGPoint(x: size.width * across, y: size.height * (1 - along)))
                }
                let move = CAKeyframeAnimation(keyPath: "position")
                move.values = thetas.map(center)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = thetas.map { 0.30 * (0.55 + sign * 0.45 * cos($0)) }
                let slide = CAAnimationGroup()
                slide.animations = [move, fade]
                slide.duration = period
                slide.repeatCount = .infinity
                slide.timeOffset = Self.phase(period)
                pool.add(slide, forKey: "slide")
            }
        }

        private static func phase(_ period: Double) -> Double {
            Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        }
    }
}

struct HazeBottomGlow: View {
    let cornerRadius: CGFloat
    @FacePreference(HazeColor.storageKey) private var hazeRaw = HazeColor.defaultValue.rawValue

    var body: some View {
        FacePreferences(keys: [HazeColor.storageKey]) { preferenceContent }
    }

    @ViewBuilder private var preferenceContent: some View {
        let haze = HazeColor(stored: hazeRaw)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(
                colors: [haze.base.opacity(0), haze.base.opacity(0.08)],
                startPoint: UnitPoint(x: 0.5, y: 0.45),
                endPoint: .bottom
            ))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Mount only for working avatars; idle needs no view, and Reduce Motion keeps a stationary rim.
struct WorkingRim: View {
    fileprivate static let bleed: CGFloat = 6
    /// A circle uses half its side as the corner radius.
    let cornerRadius: CGFloat
    @FacePreference(HazeColor.storageKey) private var hazeRaw = HazeColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FacePreferences(keys: [HazeColor.storageKey]) { preferenceContent }
    }

    @ViewBuilder private var preferenceContent: some View {
        let haze = HazeColor(stored: hazeRaw)
        Group {
            if reduceMotion {
                RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                    .strokeBorder(haze.edgeLight.opacity(0.42), lineWidth: 1.5)
                    .padding(-2)
            } else {
                ThinkingLightLayer(kind: .workingRim, cornerRadius: cornerRadius, haze: haze)
                    .padding(-Self.bleed)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
