import Foundation
import CoreGraphics
import Synchronization

// Blueprint: | `PersonOnlyWindows.swift` | `PersonOnlyWindows`: capture exclusion and input coordination |

/// Person-only windows are excluded from agent captures, pass agent pointer events through, and hold agent typing while their composer has the keyboard; person
/// input there is not a takeover. The app registers windows and effects here without Core depending on it.
public enum PersonOnlyWindows {
    private static let facePID = Atomic<Int32>(0)

    /// Her body and window share the fence, including before attachment and through pipe loss.
    public static func isOwnProcess(_ pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return false }
        return pid == ProcessInfo.processInfo.processIdentifier || isFaceProcess(pid)
    }

    public static func isFaceProcess(_ pid: Int32) -> Bool {
        pid > 0 && pid == facePID.load(ordering: .acquiring)
    }

    public static func faceStarted(processID: Int32) throws {
        guard processID > 0 else { throw MotorFailure(detail: "The window process has no live process identity.") }
        facePID.store(processID, ordering: .releasing)
    }

    public static func faceExited(processID: Int32) {
        _ = facePID.compareExchange(expected: processID, desired: 0, ordering: .acquiringAndReleasing)
    }

    public struct Window: Sendable, Equatable {
        public let number: Int
        /// Global display coordinates, top-left origin (CGEvent and CGWindow space).
        public let frame: CGRect

        public init(number: Int, frame: CGRect) {
            self.number = number
            self.frame = frame
        }
    }

    public struct MotorHost: Sendable {
        public let prepare: @Sendable (UUID, CGPoint, Driver?) async throws -> Void
        public let restore: @Sendable (UUID) async throws -> Void
        public let stepAside: @Sendable (Driver?) async throws -> Void
        public let pointer: @Sendable (CGPoint, Bool) -> Void
        public let keyboard: (@Sendable () async throws -> Void)?
        public let disconnected: (@Sendable () -> Void)?

        public init(prepare: @escaping @Sendable (UUID, CGPoint, Driver?) async throws -> Void,
                    restore: @escaping @Sendable (UUID) async throws -> Void,
                    stepAside: @escaping @Sendable (Driver?) async throws -> Void,
                    pointer: @escaping @Sendable (CGPoint, Bool) -> Void,
                    keyboard: (@Sendable () async throws -> Void)? = nil,
                    disconnected: (@Sendable () -> Void)? = nil) {
            self.prepare = prepare; self.restore = restore; self.stepAside = stepAside; self.pointer = pointer
            self.keyboard = keyboard
            self.disconnected = disconnected
        }
    }

    private struct State {
        var windows: [Window] = []
        var keyHeld = false
        var rendererWindows: [UUID: [Window]] = [:]
        var rendererKeyHeld: Set<UUID> = []
        var rendererOverlays: [UUID: Int] = [:]
        var allWindows: [Window] { windows + rendererWindows.values.flatMap { $0 } }
        var localMotor: MotorHost?
        var rendererMotors: [UUID: MotorHost] = [:]
        var keyboardReaders: [UUID: AsyncStream<Bool>.Continuation] = [:]
        var lastPersonInputUptime = -Double.infinity
        /// Decoration is excluded from captures, never a hand-back or click target.
        var overlays: Set<Int> = []
        var motorObserver: (@Sendable () -> Void)?
        var lastMotorSignal = -Double.infinity
    }
    private static let state = Mutex(State())

    /// The session and turn whose tool call is running, read from the held Turn: the agent's windows step aside for that turn, and Shotgun binds to
    /// it, whichever surface it came from.
    public struct Driver: Sendable, Equatable {
        public let session: String
        public let turn: String
        public init(session: String, turn: String) { self.session = session; self.turn = turn }
    }

    /// From any surface's turn, wait for the agent's own windows to step aside before it looks at or acts on the screen.
    public static func stepAsideForScreen(turn: Turn?) async throws {
        let hosts = state.withLock { ($0.localMotor.map { [$0] } ?? []) + Array($0.rendererMotors.values) }
        for host in hosts { try await host.stepAside(turn?.windowDriver) }
    }

    public static func install(localMotor: MotorHost) {
        state.withLock { $0.localMotor = localMotor }
    }

    public static func installRenderer(connection: UUID, motor: MotorHost) {
        state.withLock { $0.rendererMotors[connection] = motor }
    }

    /// The local body's coarse motor observer hands UI work to its actor.
    public static func observeAgent(motor: @escaping @Sendable () -> Void) {
        state.withLock { $0.motorObserver = motor }
    }

    /// The agent's hands moved: a posted key or pointer event, or an accessibility press.
    public static func noteAgentMotor() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let observer = state.withLock { state -> (@Sendable () -> Void)? in
            guard uptime - state.lastMotorSignal >= 0.5, let observer = state.motorObserver else { return nil }
            state.lastMotorSignal = uptime
            return observer
        }
        observer?()
    }

    /// Age of the agent's last motor signal (to within half a second), `.infinity` when none.
    public static func secondsSinceAgentHands() -> TimeInterval {
        let uptime = ProcessInfo.processInfo.systemUptime
        let last = state.withLock { $0.lastMotorSignal }
        return last.isFinite ? uptime - last : .infinity
    }

    /// The agent's pointer acted at `point` (CGEvent space); `pressed` for a click or drag.
    public static func noteAgentPointer(at point: CGPoint, pressed: Bool) {
        let hosts = state.withLock { ($0.localMotor.map { [$0] } ?? []) + Array($0.rendererMotors.values) }
        for host in hosts { host.pointer(point, pressed) }
    }

    public static func setOverlay(number: Int?) {
        state.withLock { $0.overlays = number.map { [$0] } ?? [] }
    }

    /// What is on screen now. Empty when nothing of the person's is showing.
    public static func update(_ current: [Window], keyHeld held: Bool) {
        state.withLock {
            $0.windows = current; $0.keyHeld = held && !current.isEmpty
            publishKeyboard(&$0)
        }
    }

    public static func updateRenderer(connection: UUID, windows: [Window], keyHeld: Bool) {
        state.withLock {
            $0.rendererWindows[connection] = windows
            if keyHeld && !windows.isEmpty { $0.rendererKeyHeld.insert(connection) }
            else { $0.rendererKeyHeld.remove(connection) }
            publishKeyboard(&$0)
        }
    }

    public static func setRendererOverlay(connection: UUID, number: Int?) {
        state.withLock { $0.rendererOverlays[connection] = number }
    }

    public static func removeRenderer(connection: UUID) {
        let motor = state.withLock {
            $0.rendererWindows.removeValue(forKey: connection)
            $0.rendererKeyHeld.remove(connection)
            $0.rendererOverlays.removeValue(forKey: connection)
            let motor = $0.rendererMotors.removeValue(forKey: connection)
            publishKeyboard(&$0)
            return motor
        }
        motor?.disconnected?()
    }

    public static func disconnect() {
        let motors = state.withLock {
            let motors = Array($0.rendererMotors.values)
            $0.windows = []
            $0.keyHeld = false
            $0.overlays = []
            $0.rendererWindows.removeAll()
            $0.rendererKeyHeld.removeAll()
            $0.rendererOverlays.removeAll()
            $0.rendererMotors.removeAll()
            publishKeyboard(&$0)
            return motors
        }
        for motor in motors { motor.disconnected?() }
    }

    /// While a person-only window is up, only Stop hands control back; person input elsewhere does not interrupt the agent.
    public static var isShowing: Bool {
        state.withLock { !$0.allWindows.isEmpty }
    }

    public static func contains(number: Int) -> Bool {
        state.withLock {
            $0.allWindows.contains { $0.number == number } || $0.overlays.contains(number) || $0.rendererOverlays.values.contains(number)
        }
    }

    public static func contains(point: CGPoint) -> Bool {
        state.withLock { $0.allWindows.contains { $0.frame.contains(point) } }
    }

    /// Every host acknowledges its current geometry and passage before input. Settlement releases every attempted host, even after Stop.
    public static func withAgentPointer(at point: CGPoint, driver: Driver? = nil, emit: (Set<UUID>) async throws -> Void) async throws {
        let (hosts, connections) = state.withLock { state in
            (Array(state.rendererMotors.values) + (state.localMotor.map { [$0] } ?? []), Set(state.rendererMotors.keys))
        }
        let operation = UUID()
        var attempted: [MotorHost] = []
        var failure: (any Error)?
        do {
            for host in hosts {
                attempted.append(host)
                let prepared: Result<Void, Error> = await settle {
                    do { try await host.prepare(operation, point, driver); return .success(()) }
                    catch { return .failure(error) }
                }
                try prepared.get()
            }
            try Task.checkCancellation()
            try await emit(connections)
        } catch { failure = error }
        let held = attempted
        let releaseFailures = await settle {
            var failures: [String] = []
            for host in held {
                do { try await host.restore(operation) }
                catch { failures.append(error.localizedDescription) }
            }
            return failures
        }
        if !releaseFailures.isEmpty {
            throw MotorFailure(detail: ([failure?.localizedDescription].compactMap { $0 } + releaseFailures).joined(separator: "\n"))
        }
        if let failure { throw failure }
    }

    public struct MotorFailure: Error, LocalizedError, Sendable {
        public let detail: String
        public var errorDescription: String? { detail }
        public init(detail: String) { self.detail = detail }
    }

    public static func keyboardChanges() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, reader) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        reader.onTermination = { _ in _ = state.withLock { $0.keyboardReaders.removeValue(forKey: id) } }
        state.withLock {
            $0.keyboardReaders[id] = reader
            reader.yield($0.keyHeld || !$0.rendererKeyHeld.isEmpty)
        }
        return stream
    }

    public static func waitForKeyboard() async throws {
        let renderers = state.withLock { Array($0.rendererMotors.values) }
        for host in renderers { try await host.keyboard?() }
        for await held in keyboardChanges() {
            try Task.checkCancellation()
            if !held { return }
        }
        try Task.checkCancellation()
    }

    private static func publishKeyboard(_ state: inout State) {
        let held = state.keyHeld || !state.rendererKeyHeld.isEmpty
        for reader in state.keyboardReaders.values { reader.yield(held) }
    }

    /// True while the person's window holds the keyboard (its composer is focused). A keystroke posted to whatever is key would land in their message, so the
    /// agent's wait until they send or click away.
    public static var keyboardHeldByPerson: Bool {
        state.withLock { $0.keyHeld || !$0.rendererKeyHeld.isEmpty }
    }

    public static func notePersonInput() {
        let uptime = ProcessInfo.processInfo.systemUptime
        state.withLock { $0.lastPersonInputUptime = uptime }
    }

    /// Age of the person's last input in their own window, `.infinity` when none.
    public static func secondsSincePersonInput() -> TimeInterval {
        let uptime = ProcessInfo.processInfo.systemUptime
        let last = state.withLock { $0.lastPersonInputUptime }
        return last.isFinite ? uptime - last : .infinity
    }
}
