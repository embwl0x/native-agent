import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import Senses
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

/// One native operation's call-stack state. Copies refine a nested operation;
/// reference owners retain the exact driver, AX evidence and captured sight.
/// Nothing here is shared implicitly between concurrent calls.
public struct MacOperationContext: Sendable {
    /// The exact sense read's capture and replay recorder, supplied at its raw-reader boundary.
    public var appCapture: SenseAppReadCapture?
    public var readContent: OwnedProgramRunner.ReadContent?
    public var deadline: ContinuousClock.Instant?
    public var observationMode: MacObservationMode = .interactive
    public var driver: MacDriverBinding?
    public var background = false
    var inputStartCount = 0
    var holdsAcrossCalls = false
    var axSession: SwiftNativeMacControl.AXSession?
    var capture: MacSightCaptureBinding?
    public var frameSource = "direct"
    public var batchFrames: [String: MacLookFrame]?
    var nativeSurfaceApp: String?
    var nativeSurfaceLabel: String?
    var foregroundRequested = false
    var typedJustBefore: String?
    var requiredFrontPid: Int32?
    var requiredFrontWindow: Int?
    var holdsActSerial = false
    var restoring: MacForegroundSnapshot?
    public var dataRoot: URL
    var looking = false
    var readDeadline: Date?
    var preparingRenderer = false
    public var handsBack = false
    #if canImport(ApplicationServices) && os(macOS)
    var evidence: MacAXAttributeRead.Evidence?
    var attributeGaps: MacAXAttributeRead.AttributeGaps?
    #endif

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
