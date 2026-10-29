import SwiftUI
import Foundation
import QuartzCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// Blueprint: | `HazeView.swift` | `HazeView`: shared radial haze rig, overlap cap, weight and tempo; native geometry, lifecycle and phone tab clock |

#if canImport(AppKit)
public typealias HazeNativeView = NSView
#else
public typealias HazeNativeView = UIView
#endif

/// Three drifting discs share one tempo; their outer weight can fade while paused.
@MainActor
public final class HazeView: HazeNativeView {
    /// 1 − (1 − busy·core)³ ≤ 0.44 at the brightest overlap.
    private static let core = CGFloat((1 - pow(1 - 0.44, 1.0 / 3.0)) / Double(HazeMood.busy.opacity))
    private static let ramp: TimeInterval = 1.5
    private static let loops: [CFTimeInterval] = [40, 48, 56]
#if canImport(AppKit)
    private static let lightWeight: Float = 0.85
    private static let size = CGSize(width: 640, height: 580)
    private static let anchors: [CGPoint] = [
        CGPoint(x: 0.18, y: 0.70), CGPoint(x: 0.74, y: 0.42), CGPoint(x: 0.46, y: 0.16),
    ]
    private static let paths: [[CGPoint]] = [
        [.zero, CGPoint(x: 160, y: -60), CGPoint(x: 90, y: -170), CGPoint(x: -120, y: -90), .zero],
        [.zero, CGPoint(x: -150, y: 90), CGPoint(x: -60, y: 180), CGPoint(x: 110, y: 70), .zero],
        [.zero, CGPoint(x: 120, y: 130), CGPoint(x: -100, y: 160), CGPoint(x: -140, y: 20), .zero],
    ]
#else
    private static let lightWeight: Float = 0.7
    private static let size = CGSize(width: 520, height: 600)
    private static let anchors: [CGPoint] = [
        CGPoint(x: 0.10, y: 0.20), CGPoint(x: 0.92, y: 0.52), CGPoint(x: 0.30, y: 0.90),
    ]
    private static let paths: [[CGPoint]] = [
        [.zero, CGPoint(x: 110, y: 60), CGPoint(x: 60, y: 170), CGPoint(x: -70, y: 90), .zero],
        [.zero, CGPoint(x: -110, y: -90), CGPoint(x: -40, y: -190), CGPoint(x: 60, y: -70), .zero],
        [.zero, CGPoint(x: 90, y: -130), CGPoint(x: -60, y: -160), CGPoint(x: -90, y: -20), .zero],
    ]
#endif

    private let weight = CALayer()
    private let drift = CALayer()
    private var discs: [CAGradientLayer] = []
    private var color: HazeColor?
    private var mood: HazeMood = .idle
    private var dark = true
    private var still = false
    private var observers: [NSObjectProtocol] = []
    private var rampStart: (time: CFTimeInterval, from: Float, to: Float)?
#if canImport(AppKit)
    private var rampTimer: Timer?
#else
    private var foreground = true
    private var rampLink: CADisplayLink?
    /// The visible room writes the clock; arriving tabs pick up its phase.
    private static var clock = (local: CFTimeInterval(0), wall: CACurrentMediaTime(), speed: Float(0))
#endif

    public init() {
        super.init(frame: .zero)
#if canImport(AppKit)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(weight)
#else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = true
        layer.addSublayer(weight)
#endif
        weight.opacity = 0
        weight.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        drift.actions = ["bounds": NSNull(), "position": NSNull()]
        weight.addSublayer(drift)
        for (index, loop) in Self.loops.enumerated() {
            let disc = CAGradientLayer()
            disc.type = .radial
            disc.startPoint = CGPoint(x: 0.5, y: 0.5)
            disc.endPoint = CGPoint(x: 1, y: 1)
            disc.locations = [0, 0.35, 0.7, 1]
            disc.bounds = CGRect(origin: .zero, size: Self.size)
            disc.actions = ["position": NSNull(), "bounds": NSNull()]
            drift.addSublayer(disc)
            discs.append(disc)

            let move = CAKeyframeAnimation(keyPath: "position")
#if canImport(AppKit)
            move.values = Self.paths[index].map { NSValue(point: $0) }
#else
            move.values = Self.paths[index].map { NSValue(cgPoint: $0) }
#endif
            move.isAdditive = true
            move.calculationMode = .cubic
            move.duration = loop
            move.repeatCount = .infinity
            move.isRemovedOnCompletion = false
            move.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 20)
            move.timeOffset = loop * Double(index) / 3
            disc.add(move, forKey: "drift")
        }
        setSpeed(0)
#if !canImport(AppKit)
        let center = NotificationCenter.default
        for (name, isForeground) in [(UIApplication.didEnterBackgroundNotification, false),
                                     (UIApplication.willEnterForegroundNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.foreground = isForeground
                    self?.retarget()
                }
            })
        }
#endif
    }

    required public init?(coder: NSCoder) {
#if canImport(AppKit)
        fatalError("init(coder:) has not been implemented")
#else
        return nil
#endif
    }

#if canImport(AppKit)
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// SwiftUI frame changes must request AppKit layout explicitly.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        layoutLayers()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didChangeOcclusionStateNotification, window),
            (NSApplication.didBecomeActiveNotification, NSApp),
            (NSApplication.didResignActiveNotification, NSApp),
        ]
        for (name, object) in names {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retarget() }
            })
        }
        retarget()
    }
#else
    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutLayers()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            stopRamp()
            let now = CACurrentMediaTime()
            setSpeed((still || !foreground) ? 0 : mood.speed, at: now,
                     local: Self.clock.local + (now - Self.clock.wall) * Double(Self.clock.speed))
            weight.removeAnimation(forKey: "weight")
            weight.opacity = mood.opacity * (dark ? 1 : Self.lightWeight)
        }
        retarget()
    }
#endif

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        weight.frame = bounds
        drift.frame = bounds
        for (disc, anchor) in zip(discs, Self.anchors) {
            disc.position = CGPoint(x: bounds.width * anchor.x, y: bounds.height * anchor.y)
        }
        CATransaction.commit()
    }

    public func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        stopRamp()
    }

    public func apply(color: HazeColor, mood: HazeMood, dark: Bool, still: Bool) {
#if canImport(AppKit)
        let recolor = color != self.color || dark != self.dark
#else
        let recolor = color != self.color
#endif
        if recolor {
            CATransaction.begin()
            CATransaction.setAnimationDuration(self.color == nil ? 0 : 1.2)
            CATransaction.setDisableActions(self.color == nil)
            for (disc, hex) in zip(discs, color.shades) {
#if canImport(AppKit)
                let shade = NSColor(Color(hex: hex))
                let base = dark ? shade : (shade.blended(withFraction: 0.5, of: .white) ?? shade)
#else
                let base = UIColor(Color(hex: hex))
#endif
                let k = Self.core
                disc.colors = [k, k * 0.9, k * 0.45, 0].map { base.withAlphaComponent($0).cgColor }
            }
            CATransaction.commit()
        }
        let changed = mood != self.mood || dark != self.dark || still != self.still || self.color == nil
        self.color = color
        self.mood = mood
        self.dark = dark
        self.still = still
        if changed { retarget() }
    }

    private var visible: Bool {
#if canImport(AppKit)
        guard let window else { return false }
        return NSApp.isActive && window.occlusionState.contains(.visible)
#else
        return foreground && window != nil
#endif
    }

    private func retarget() {
        let targetOpacity = mood.opacity * (dark ? 1 : Self.lightWeight)
        let from = weight.presentation()?.opacity ?? weight.opacity
        if from != targetOpacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = targetOpacity
            fade.duration = Self.ramp
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            weight.opacity = targetOpacity
            weight.add(fade, forKey: "weight")
        }

        let target: Float = (still || !visible) ? 0 : mood.speed
        let start = drift.speed
        stopRamp()
        guard start != target else { return }
#if !canImport(AppKit)
        // Phone pauses immediately; active tempo changes ease.
        if target == 0 { setSpeed(0); return }
#endif
        rampStart = (CACurrentMediaTime(), start, target)
#if canImport(AppKit)
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] timer in
            let done = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return true }
                self.stepRamp()
                return self.rampStart == nil
            }
            if done { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
#else
        let link = CADisplayLink(target: self, selector: #selector(stepRamp))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 12)
        link.add(to: .main, forMode: .common)
        rampLink = link
#endif
    }

    @objc private func stepRamp() {
        guard let ramp = rampStart else { stopRamp(); return }
        let t = min(1, (CACurrentMediaTime() - ramp.time) / Self.ramp)
        let eased = Float(t * t * (3 - 2 * t))
        setSpeed(ramp.from + (ramp.to - ramp.from) * eased)
        if t >= 1 { stopRamp() }
    }

    private func stopRamp() {
#if canImport(AppKit)
        rampTimer?.invalidate()
        rampTimer = nil
#else
        rampLink?.invalidate()
        rampLink = nil
#endif
        rampStart = nil
    }

    /// Rebase the drift clock without changing its local time.
    private func setSpeed(_ speed: Float, at now: CFTimeInterval = CACurrentMediaTime(), local: CFTimeInterval? = nil) {
        let local = local ?? drift.convertTime(now, from: nil)
        drift.speed = speed
        drift.timeOffset = local
        drift.beginTime = now
#if !canImport(AppKit)
        if window != nil { Self.clock = (local, now, speed) }
#endif
    }
}
