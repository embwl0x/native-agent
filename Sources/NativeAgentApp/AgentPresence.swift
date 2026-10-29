import AppKit
import SwiftUI
import QuartzCore
import NativeAgentShared
import Foundation
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
// Blueprint: | `AgentPresence.swift` | Agent presence card and Core Animation breathing orb reflect shared turn state and motion preferences |

/// The agent card shows current activity and shimmers throughout a turn.
/// Its turn-state reads stay separate from the sidebar's other rows.
struct SimpleAgentCard: View {
    let selected: Bool
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var activeState

    static let radius: CGFloat = 14

    /// The window's serif title.
    static let nameFont = Font.system(size: 28, weight: .semibold, design: .serif)

    /// Show delegation, thinking, replying, an owner wait or presence; steps stay in the transcript.
    private var doing: (text: String, waiting: Bool) {
        if appModel.isBusy || appModel.isChatStreaming,
           let presentation = appModel.engine.turns.lifecycle(for: appModel.activeChatSessionId)?.presentation,
           !presentation.isTerminal, presentation.phase == .delegation,
           let partner = presentation.delegateName, !partner.isEmpty {
            return ("Working · with \(partner)", false)
        }
        if appModel.engine.turns.isThinkingBeforeReply(for: appModel.activeChatSessionId) { return ("Thinking…", false) }
        if appModel.isBusy || appModel.isChatStreaming { return ("Replying…", false) }
        return (appModel.engine.desk.ownerWaitingCount ?? 0) > 0 ? ("Waiting on you", true) : ("Here", false)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    var body: some View {
        let name = AgentVoice(name: appModel.agentDisplayName).name
        let line = doing
        // The rim while the reply streams; before it, the plate shimmers.
        let replying = (appModel.isBusy || appModel.isChatStreaming) && !appModel.engine.turns.isThinkingBeforeReply(for: appModel.activeChatSessionId)
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
        // A background window loses the glass's own rim; the hairline keeps
        // the card's edge there.
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
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BreathingOrbLayer(haze: HazeColor(stored: colorRaw), still: reduceMotion)
            .frame(width: 22, height: 22)
            // Round the 14pt disc with a 2pt gap.
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
