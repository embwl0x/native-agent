import SwiftUI
import UIKit

/// A leaf driven by signed working evidence. Core Animation owns every frame.
struct PhoneThinkingLight: View {
    let correlationIDs: Set<String>
    @ObservedObject private var activity = PhoneTurnActivity.shared
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if !activity.workingIDs.isDisjoint(with: correlationIDs) {
            PhoneShimmer(color: UIColor(HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: false)),
                moving: !reduceMotion && scenePhase == .active)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct PhoneShimmer: UIViewRepresentable {
    let color: UIColor
    let moving: Bool
    func makeUIView(context: Context) -> ShimmerView { ShimmerView() }
    func updateUIView(_ view: ShimmerView, context: Context) { view.apply(color: color, moving: moving) }

    final class ShimmerView: UIView {
        private let glow = CAGradientLayer()
        private let rim = CAShapeLayer()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            glow.startPoint = CGPoint(x: 0, y: 0.3)
            glow.endPoint = CGPoint(x: 1, y: 0.7)
            glow.locations = [-0.5, 0, 0.5]
            layer.addSublayer(glow)
            rim.fillColor = UIColor.clear.cgColor
            rim.lineWidth = 1.5
            layer.addSublayer(rim)
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            glow.frame = bounds
            rim.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 25).cgPath
            CATransaction.commit()
        }
        func apply(color: UIColor, moving: Bool) {
            glow.colors = [color.withAlphaComponent(0.02).cgColor, color.withAlphaComponent(0.2).cgColor,
                           color.withAlphaComponent(0.02).cgColor]
            rim.strokeColor = color.withAlphaComponent(0.45).cgColor
            if moving && glow.animation(forKey: "thinking") == nil {
                let animation = CABasicAnimation(keyPath: "locations")
                animation.fromValue = [-0.5, 0, 0.5]
                animation.toValue = [0.5, 1, 1.5]
                animation.duration = 3
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glow.add(animation, forKey: "thinking")
            } else if !moving {
                glow.removeAnimation(forKey: "thinking")
                glow.locations = [0, 0.5, 1]
            }
        }
    }
}
