#if os(macOS)
import AppKit
import QuartzCore
// Blueprint: | `DisplayFrame.swift` | `DisplayFrame`: the Mac window's display rhythm (macOS only); the face feed applies what arrived once per frame |

@MainActor
public final class DisplayFrame: NSObject {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var link: CADisplayLink?
    private var screen: NSScreen?

    public override init() {
        super.init()
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowsChanged(_:)), name: name, object: nil)
        }
    }

    public func next() async {
        await withCheckedContinuation { waiter in
            waiters.append(waiter)
            if link == nil { bindToVisibleScreen() }
            if let link { link.isPaused = false } else { tick() }
        }
    }

    @objc private func windowsChanged(_ notification: Notification) {
        if link != nil { bindToVisibleScreen() }
    }

    private func bindToVisibleScreen() {
        let windows = NSApp?.windows.filter {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? []
        let fastest = NSScreen.screens
            .filter { screen in windows.contains { NSIntersectsRect($0.frame, screen.frame) } }
            .max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }
        guard fastest !== screen else { return }
        link?.invalidate()
        screen = fastest
        link = fastest?.displayLink(target: self, selector: #selector(frame(_:)))
        link?.isPaused = waiters.isEmpty
        link?.add(to: .main, forMode: .common)
        if link == nil { tick() }
    }

    @objc private func frame(_ link: CADisplayLink) { tick() }

    private func tick() {
        link?.isPaused = true
        let ready = waiters
        waiters = []
        for waiter in ready { waiter.resume() }
    }
}
#endif
