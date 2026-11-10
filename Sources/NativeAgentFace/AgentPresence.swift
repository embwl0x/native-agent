import AppKit
import SwiftUI
import QuartzCore
import NativeAgentShared
import Foundation
// Blueprint: | `AgentPresence.swift` | Agent presence card and Core Animation breathing orb reflect shared turn state and motion preferences |

/// Keep turn-state reads separate so updates do not invalidate the sidebar's other rows.
struct SimpleAgentCard: View {
    let selected: Bool
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var activeState

    static let radius: CGFloat = 14

    static let nameFont = Font.system(size: 28, weight: .semibold, design: .serif)

    /// Keep steps in the transcript; the card summarizes the current activity.
    /// Only the line the pill shows: a reply's movement never redraws it.
    private struct TurnLine: Equatable {
        let text: String
        let waiting: Bool

        init?(_ turn: TurnFace?) {
            guard let turn else { return nil }
            // A running step, a wait and a block say what she is doing in the box's own words.
            if turn.steps.contains(where: \.isRunning) || turn.phase == .waiting || turn.phase == .retrying || turn.phase == .blocked,
               let detail = turn.card?.detail {
                (text, waiting) = (detail, turn.card?.approval?.isActionable == true)
            } else if turn.isWorking, turn.phase == .delegation, let partner = turn.card?.delegateName, !partner.isEmpty {
                (text, waiting) = ("Working · with \(partner)", false)
            } else if turn.isThinking {
                (text, waiting) = ("Thinking…", false)
            } else {
                return nil
            }
        }
    }

    private var doing: (text: String, waiting: Bool) {
        if let line = appModel.turnPart("presenceLine", for: appModel.activeChatSessionId, TurnLine.init) { return (line.text, line.waiting) }
        if appModel.isBusy || appModel.isChatStreaming { return ("Replying…", false) }
        let waiting: Bool? = appModel.countPart("deskWaiting.presence") { face in
            guard let count = face?.deskWaiting, count.isAvailable, let value = count.value else { return nil }
            return value > 0
        }
        guard let waiting else { return ("Attention unavailable", false) }
        return waiting ? ("Waiting on you", true) : ("Here", false)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    var body: some View {
        let name = appModel.agentDisplayName
        let line = doing
        let replying = (appModel.isBusy || appModel.isChatStreaming)
            && appModel.turnPart("isThinking?", for: appModel.activeChatSessionId) { $0?.isThinking } == false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SimpleBreathingOrb(replying: replying)
                Text(name)
                    .font(Self.nameFont)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if line.waiting {
                    Circle().fill(NativeAgentShell.needsYou).frame(width: 7, height: 7)
                }
                Text(line.text)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background { shape.fill(selected ? NativeAgentShell.softFill : .clear) }
        .background { ThinkingGlow(kind: .shimmer, cornerRadius: Self.radius, wholeTurn: true) }
        .glassEffect(reduceTransparency ? .identity : HouseGlass.plate, in: shape)
        // Keep a hairline because background windows lose the glass rim.
        .overlay {
            if activeState == .inactive || reduceTransparency {
                shape.strokeBorder(NativeAgentShell.hairline, lineWidth: 1).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name). \(line.text)")
        .accessibilityHint("Opens the chat with \(name)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Core Animation breathes the haze disc without per-frame SwiftUI updates; Reduce Motion keeps it still.
private struct SimpleBreathingOrb: View {
    var replying = false
    @FacePreference(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FacePreferences(keys: [HazeColor.key]) { preferenceContent }
    }

    private var preferenceContent: some View {
        BreathingOrbLayer(haze: HazeColor(stored: colorRaw), still: reduceMotion)
            .frame(width: 22, height: 22)
            .overlay { if replying { WorkingRim(cornerRadius: 8).frame(width: 16, height: 16) } }
            .padding(-4)
            .accessibilityHidden(true)
    }
}

private struct BreathingOrbLayer: NSViewRepresentable {
    var haze: HazeColor
    var still: Bool

    func makeNSView(context: Context) -> OrbView { OrbView() }
    func updateNSView(_ view: OrbView, context: Context) { view.apply(haze: haze, still: still) }

    final class OrbView: NSView {
        private let disc = CAGradientLayer()
        private var applied: (HazeColor, Bool)?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            disc.type = .radial
            disc.startPoint = CGPoint(x: 0.35, y: 0.7)
            disc.endPoint = CGPoint(x: 1.1, y: -0.1)
            disc.shadowRadius = 5
            disc.shadowOffset = .zero
            layer?.addSublayer(disc)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let side: CGFloat = 14
            disc.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            disc.cornerRadius = side / 2
            CATransaction.commit()
        }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

        func apply(haze: HazeColor, still: Bool) {
            if let applied, applied.0 == haze, applied.1 == still { return }
            applied = (haze, still)
            let base = NSColor(haze.base), light = NSColor(haze.edgeLight)
            disc.colors = [light.cgColor, base.cgColor]
            disc.shadowColor = base.cgColor
            disc.removeAllAnimations()
            disc.shadowOpacity = 0.45
            guard !still else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.92; scale.toValue = 1.08
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.35; glow.toValue = 0.7
            let group = CAAnimationGroup()
            group.animations = [scale, glow]
            group.duration = 2.8
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24)
            disc.add(group, forKey: "breathe")
        }
    }
}
