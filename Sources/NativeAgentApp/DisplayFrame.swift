import AppKit
import QuartzCore
// Blueprint: | `DisplayFrame.swift` | `DisplayFrame`: the Mac window's display rhythm; the face feed applies what arrived once per frame |

/// The next frame of the screen the window is on. The link runs only while something waits for a frame, and pauses after it.
@MainActor
final class DisplayFrame: NSObject {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var link: CADisplayLink?

    func next() async {
        await withCheckedContinuation { waiter in
            waiters.append(waiter)
            guard let screen = NSScreen.main else {
                // A face with no screen has no frame to wait for: it applies now.
                tick()
                return
            }
            if link == nil {
                let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
                link.add(to: .main, forMode: .common)
                self.link = link
            }
            link?.isPaused = false
        }
    }

    @objc private func frame(_ link: CADisplayLink) { tick() }

    private func tick() {
        link?.isPaused = true
        let ready = waiters
        waiters = []
        for waiter in ready { waiter.resume() }
    }
}
