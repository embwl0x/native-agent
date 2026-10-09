import Foundation
import CoreGraphics

/// Windows that belong to the person alone — Shotgun, the small chat the app
/// steps aside into while the agent drives the Mac (User, 10-04). The agent
/// never sees one (her screen captures leave it out), never clicks one (her
/// own pointer events pass through it), and never types into one (her
/// keystrokes wait while its composer has the keyboard); the person's own
/// input there is not a takeover. The app registers the window and the one
/// pointer effect; Core reads them here, so nothing in Core depends on the app.
public enum PersonOnlyWindows {
    public struct Window: Sendable, Equatable {
        public let number: Int
        /// Global display coordinates, top-left origin (CGEvent and CGWindow space).
        public let frame: CGRect

        public init(number: Int, frame: CGRect) {
            self.number = number
            self.frame = frame
        }
    }

    /// How long the window keeps passing her pointer through after her last
    /// pointer event on it: long enough for the window server to route the
    /// event she just posted, short enough that the person's own click lands.
    public static let pointerPassThroughSeconds: TimeInterval = 0.1

    private static let lock = NSLock()
    private nonisolated(unsafe) static var windows: [Window] = []
    private nonisolated(unsafe) static var keyHeld = false
    private nonisolated(unsafe) static var passing = false
    private nonisolated(unsafe) static var passUntil = -Double.infinity
    private nonisolated(unsafe) static var lastPersonInputUptime = -Double.infinity
    private nonisolated(unsafe) static var passPointerThrough: (@Sendable () -> Void)?
    /// Windows shown only as decoration over her work (her pointer): left out
    /// of her captures like the rest, but never a hand-back or a click target.
    private nonisolated(unsafe) static var overlays: Set<Int> = []
    private nonisolated(unsafe) static var motorObserver: (@Sendable () -> Void)?
    private nonisolated(unsafe) static var lastMotorSignal = -Double.infinity
    private nonisolated(unsafe) static var pointerObserver: (@Sendable (CGPoint, Bool) -> Void)?

    /// The app's pointer effect, installed once. It runs synchronously before
    /// her event is posted, on whatever thread posts it.
    public static func install(passPointerThrough: @escaping @Sendable () -> Void) {
        lock.lock()
        self.passPointerThrough = passPointerThrough
        lock.unlock()
    }

    /// The app's watchers of her hands: `motor` on her motor output (at most
    /// twice a second), `pointer` with where each pointer action of hers
    /// happened and whether it pressed. Both are called on whatever thread
    /// posts; they must only hand off.
    public static func observeAgent(
        motor: @escaping @Sendable () -> Void,
        pointer: @escaping @Sendable (CGPoint, Bool) -> Void
    ) {
        lock.lock()
        motorObserver = motor
        pointerObserver = pointer
        lock.unlock()
    }

    /// Her hands moved: a posted key or pointer event, or an accessibility press.
    public static func noteAgentMotor() {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard uptime - lastMotorSignal >= 0.5, let observer = motorObserver else { lock.unlock(); return }
        lastMotorSignal = uptime
        lock.unlock()
        observer()
    }

    /// Age of her last motor signal (to within half a second), `.infinity` when none.
    public static func secondsSinceAgentHands() -> TimeInterval {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let last = lastMotorSignal
        lock.unlock()
        return last.isFinite ? uptime - last : .infinity
    }

    /// Her pointer acted at `point` (CGEvent space); `pressed` for a click or drag.
    public static func noteAgentPointer(at point: CGPoint, pressed: Bool) {
        lock.lock()
        let observer = pointerObserver
        lock.unlock()
        observer?(point, pressed)
    }

    /// The decoration window, nil when there is none.
    public static func setOverlay(number: Int?) {
        lock.lock()
        overlays = number.map { [$0] } ?? []
        lock.unlock()
    }

    /// What is on screen now. Empty when nothing of the person's is showing.
    public static func update(_ current: [Window], keyHeld held: Bool) {
        lock.lock()
        windows = current
        keyHeld = held && !current.isEmpty
        lock.unlock()
    }

    /// True while a window of the person's is up. User, 10-04: while Shotgun
    /// is up, Stop is the only hand-back; his input elsewhere never takes the
    /// Mac from her, so he never interrupts her by accident.
    public static var isShowing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !windows.isEmpty
    }

    public static func contains(number: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return windows.contains { $0.number == number } || overlays.contains(number)
    }

    public static func contains(point: CGPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return windows.contains { $0.frame.contains(point) }
    }

    /// Before one of her pointer or scroll events at `point` (CGEvent space):
    /// the window server routes those by location, so when it lands on the
    /// person's window, that window must let it fall through. Her events
    /// anywhere else change nothing.
    public static func beforeAgentPointer(at point: CGPoint) {
        lock.lock()
        guard windows.contains(where: { $0.frame.contains(point) }) else { lock.unlock(); return }
        passUntil = ProcessInfo.processInfo.systemUptime + pointerPassThroughSeconds
        let hop = passing ? nil : passPointerThrough
        passing = true
        lock.unlock()
        hop?()
    }

    /// The app's restore check. Nil: her pointer has been idle long enough,
    /// so the window takes clicks again. Otherwise how long to wait first.
    public static func endPointerPassThroughIfIdle() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        let left = passUntil - ProcessInfo.processInfo.systemUptime
        guard left <= 0 else { return left }
        passing = false
        return nil
    }

    /// True while the person's window holds the keyboard (its composer is
    /// focused). A keystroke posted to whatever is key would land in their
    /// message, so hers wait until they send or click away.
    public static var keyboardHeldByPerson: Bool {
        lock.lock()
        defer { lock.unlock() }
        return keyHeld
    }

    /// The person typed or pointed in their own window just now.
    public static func notePersonInput() {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastPersonInputUptime = uptime
        lock.unlock()
    }

    /// Age of the person's last input in their own window, `.infinity` when none.
    public static func secondsSincePersonInput() -> TimeInterval {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let last = lastPersonInputUptime
        lock.unlock()
        return last.isFinite ? uptime - last : .infinity
    }
}
