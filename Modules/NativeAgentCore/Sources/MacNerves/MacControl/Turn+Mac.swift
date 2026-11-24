import Foundation
import Synchronization
import Darwin
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import SenseCore
// Blueprint: | `Turn+Mac.swift` | `Turn` holds Mac admission and continuation; `MacOperationContext` carries native call-stack state |

private enum MacContinuationPart: TurnPart { static let unset: MacWorkContinuation? = nil }
private enum FullMacAdmittedPart: TurnPart { static let unset: Bool = false }
private enum InjectionCapabilityPart: TurnPart { static let unset: MacInjectionCapability? = nil }

extension Turn {
    /// Where the person was when their door received a take-over: bounded evidence and authority.
    public var macContinuation: MacWorkContinuation? {
        get { self[MacContinuationPart.self] }
        set { self[MacContinuationPart.self] = newValue }
    }
    /// Full Mac was checked and admitted for this act.
    public var fullMacAdmitted: Bool {
        get { self[FullMacAdmittedPart.self] }
        set { self[FullMacAdmittedPart.self] = newValue }
    }
    /// The exact checked injection approval this act spends.
    public var injectionCapability: MacInjectionCapability? {
        get { self[InjectionCapabilityPart.self] }
        set { self[InjectionCapabilityPart.self] = newValue }
    }
}

/// The apps one Mac operation's Accessibility messages go to. While Accessibility holds the operation, they are what it waits on: alive
/// while any of those processes runs, however hung (shown as waiting; Stop ends it); dead only when every one of them has quit.
final class MacAXTargets: Sendable {
    private let apps = Mutex([pid_t: String]())
    /// Apps whose renderer this operation already found ready: preparation answers once per app per operation, not once per message.
    private let readyRenderers = Mutex(Set<pid_t>())

    func rendererReady(_ pid: pid_t) -> Bool { readyRenderers.withLock { $0.contains(pid) } }
    func noteRendererReady(_ pid: pid_t) { readyRenderers.withLock { _ = $0.insert(pid) } }

    func note(_ pid: pid_t) {
        guard pid > 0, apps.withLock({ $0[pid] == nil }) else { return }
        var buffer = [CChar](repeating: 0, count: 256)
        let named = proc_name(pid, &buffer, UInt32(buffer.count)) > 0
            ? buffer.withUnsafeBufferPointer { unsafe String(cString: $0.baseAddress!) } : "process \(pid)"
        apps.withLock { $0[pid] = named }
    }

    var life: CallLife {
        CallLife(what: "the app Accessibility is reaching") { [self] in
            let noted = apps.withLock { $0 }
            guard !noted.isEmpty else { return .unknown }
            if noted.keys.contains(where: { kill($0, 0) == 0 || errno == EPERM }) { return .alive }
            return .dead("\(noted.values.sorted().joined(separator: ", ")) has quit")
        }
    }
}

/// One native operation's call-stack state. Copies refine a nested operation;
/// reference owners retain the exact driver, AX evidence and captured sight.
/// Nothing here is shared implicitly between concurrent calls.
public struct MacOperationContext: Sendable {
    /// The exact sense read's capture and replay recorder, supplied at its raw-reader boundary.
    public var appCapture: SenseAppReadCapture?
    public var readContent: OwnedProgramRunner.ReadContent?
    public var deadline: ContinuousClock.Instant?
    /// The watch of the call this operation serves: what the operation waits on is attached to it.
    public var life: TurnDeadline?
    public var observationMode: MacObservationMode = .interactive
    public var driver: MacDriverBinding?
    public var background = false
    var inputStartCounts = (requested: 0, recovery: 0)
    var holdsAcrossCalls = false
    var axSession: SwiftNativeMacControl.AXSession?
    /// The apps this operation's Accessibility messages go to, noted as each message is prepared.
    var axTargets: MacAXTargets?
    var capture: MacSightCaptureBinding?
    public var frameSource = "direct"
    public var batchFrames: [String: MacLookFrame]?
    var nativeSurfaceApp: String?
    var nativeSurfaceLabel: String?
    var foregroundRequested = false
    var typedJustBefore: String?
    var requiredFrontPid: Int32?
    var sightedHandWindow: MacAXWindowIdentity?
    var requiredFrontWindow: Int?
    var holdsActSerial = false
    var restoring: MacForegroundSnapshot?
    public var dataRoot: URL
    var looking = false
    /// Under Full Mac her eyes see what the person sees: pixels carry no secret masks. Her saved receipts keep their own redaction.
    public internal(set) var seesAsPerson = false
    var readDeadline: Date?
    var preparingRenderer = false
    public var handsBack = false
    var evidence: MacAXAttributeRead.Evidence?
    var attributeGaps: MacAXAttributeRead.AttributeGaps?

    public init(dataRoot: URL = defaultDataRoot(), deadline: ContinuousClock.Instant? = nil,
                observationMode: MacObservationMode = .interactive) {
        self.dataRoot = dataRoot
        self.deadline = deadline
        self.observationMode = observationMode
    }

    public var expired: Bool { deadline.map { ContinuousClock.now >= $0 } == true }
    public var waitBudget: OperationWaitBudget { .init(deadline: deadline) }
    public var cancellationError: any Error { waitBudget.cancellationError }
    var wallDate: Date? {
        guard let deadline else { return nil }
        let remaining = ContinuousClock.now.duration(to: deadline).components
        return Date().addingTimeInterval(Double(remaining.seconds) + Double(remaining.attoseconds) * 1e-18)
    }

    func with<Value>(_ key: WritableKeyPath<Self, Value>, _ value: Value) -> Self {
        var next = self
        next[keyPath: key] = value
        return next
    }

    /// Stop ends work, while the same operation still owes its terminal record and releases.
    func settling() -> Self {
        var next = self
        next.deadline = nil
        next.readDeadline = nil
        return next
    }

    public func holding<Value, Result>(_ key: WritableKeyPath<Self, Value>, _ value: Value,
                                _ body: (Self) throws -> Result) rethrows -> Result {
        var next = self
        next[keyPath: key] = value
        return try body(next)
    }

    public func holding<Value, Result>(_ key: WritableKeyPath<Self, Value>, _ value: Value,
                                isolation: isolated (any Actor)? = #isolation,
                                _ body: (Self) async throws -> Result) async rethrows -> Result {
        var next = self
        next[keyPath: key] = value
        return try await body(next)
    }
}

extension Turn {
    /// A nested native act keeps this turn, explicitly refining its admission.
    func holding<Value, Result>(_ key: WritableKeyPath<Self, Value>, _ value: Value,
                                isolation: isolated (any Actor)? = #isolation,
                                _ body: (Self) async throws -> Result) async rethrows -> Result {
        try await body(with(key, value))
    }
}
