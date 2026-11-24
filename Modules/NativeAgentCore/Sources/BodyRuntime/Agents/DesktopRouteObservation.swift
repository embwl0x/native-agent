import AppKit
import ApplicationServices
import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Synchronization
// Blueprint: | `DesktopRouteObservation.swift` | Sendable observation owns locked wake state; AX and workspace events wake cancellable desktop waits. |
/// Register before the first predicate read. An unavailable source reports its cause; every caller stops its observer. A desktop step's observation carries
/// its own patience: when the condition has not come true within it, the caller reads once more and then the step ends with that one sentence, so no
/// desktop operation (or its cleanup) can hold the desktop on silence.
final class DesktopRouteObservation: Sendable {
    enum Wake: String, Sendable {
        case initialRead = "initial_read"
        // The AX stream includes its registration-race signal. A wake does not claim that a change notification or content change occurred.
        case accessibility = "accessibility_subscription"
        case workspace
        case unavailable = "observation_unavailable"
        case expired = "patience_expired"
    }
    /// Seconds one observed desktop step (launch, activation, a control appearing, a panel closing) may wait before it ends its operation.
    static let stepPatience: Double = 20

    /// Opening an app is an observed step like any other: it gets the step's patience, capped by the operation's deadline (the declared TaskWaitDeadline
    /// ceiling). Past it the step ends with `OperationWaitBudget.Exceeded`; the launch request itself stays with macOS.
    static func openApplication(_ url: URL, context: MacOperationContext, patience: Double = stepPatience) async throws {
        try await OperationWaitBudget.withDeadline(seconds: patience, budget: context.waitBudget) { _ in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
    /// The step's patience ran out before its condition came true.
    struct Expired: Error, LocalizedError, Sendable {
        let seconds: Int
        var errorDescription: String? {
            "A desktop step waited \(seconds) seconds and its condition did not come true, so the operation stopped there; nothing more was done."
        }
    }
    private let stream: AsyncThrowingStream<Wake, Error>
    private let signal: AsyncThrowingStream<Wake, Error>.Continuation
    private let source: MacAppSourceEvents?
    /// The watch of the call this observation serves: the observed app is attached to it, and each accessibility event from the app is life.
    private let life: TurnDeadline?
    private struct State: Sendable {
        var sourceFailure: Error?
        var lastWake: Wake = .initialRead
        var stopped = false
        var reader: Task<Void, Never>?
        var expiry: Task<Void, Never>?
        var lifeID: UUID?
    }
    private let state: Mutex<State>
    private let workspace: Mutex<[NSObjectProtocol]>

    /// `patience`: seconds this observed step may wait, capped by the operation's own deadline; nil only for reply watches, which Stop ends.
    init(bundleID: String, context: MacOperationContext, accessibility: Bool = true, patience: Double? = nil) async throws {
        try Task.checkCancellation()
        life = context.life
        var initialFailure: Error?
        do { source = accessibility ? try await MacAppSourceEvents.open(bundleID: bundleID, context: context) : nil }
        catch is CancellationError { throw CancellationError() }
        catch {
            source = nil
            initialFailure = DesktopComposer.observationFailure(error, operation: "for \(bundleID) could not start")
        }
        let pair = AsyncThrowingStream<Wake, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; signal = pair.continuation
        workspace = Mutex([NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didUnhideApplicationNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
                pair.continuation.yield(.workspace)
            }
        })
        state = Mutex(State(sourceFailure: initialFailure))
        // What the call waits on is the app itself: alive while it answers, dead once it has quit or stops answering.
        if let life, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            let id = life.attach(AppleScriptExecution.appLife(pid: app.processIdentifier, name: app.localizedName ?? bundleID))
            state.withLock { $0.lifeID = id }
        }
        if let source {
            let reader = Task { [weak self] in
                do {
                    for try await _ in source.stream {
                        guard !Task.isCancelled else { return }
                        pair.continuation.yield(.accessibility)
                    }
                    guard !Task.isCancelled else { return }
                    self?.state.withLock { $0.sourceFailure = DesktopComposer.Failure(detail: """
                            Accessibility observation ended before the condition was confirmed. Bring the app forward with its Accessibility tree \
                            available, then continue.
                            """) }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.state.withLock { $0.sourceFailure = DesktopComposer.observationFailure(error, operation: "stopped") }
                }
                // Let the caller read once before surfacing the lost wake.
                pair.continuation.yield(.unavailable)
            }
            state.withLock { $0.reader = reader }
        }
        if let patience {
            // The operation's declared wait ceiling (TaskWaitDeadline) wakes this parker; nothing resumes it otherwise, and stop cancels it.
            let budget = context.waitBudget.capped(seconds: patience)
            let expiry = Task { [weak self] in
                await ScopedWaiter().park(budget: budget)
                guard !Task.isCancelled else { return }
                self?.state.withLock { state in
                    if state.sourceFailure == nil { state.sourceFailure = Expired(seconds: Int(patience)) }
                }
                pair.continuation.yield(.expired)
            }
            state.withLock { $0.expiry = expiry }
        }
    }
    func receipt(readBy: String, replyComplete: Bool = false) async -> JSONValue {
        let (sourceFailure, lastWake) = state.withLock { ($0.sourceFailure, $0.lastWake) }
        var fields: [String: JSONValue] = ["read_by": .string(readBy), "wake": .string(lastWake.rawValue),
            "mode": .string(sourceFailure != nil ? "unavailable" : "source_events")]
        if let sourceFailure { fields["reason"] = .string(sourceFailure.localizedDescription) }
        if let source { fields["ax_watch_coverage"] = await source.readCoverage() }
        if replyComplete { fields["completion_signal"] = .string("correlated_reply_idle") }
        return .object(fields)
    }
    func next() async throws {
        try Task.checkCancellation()
        if let sourceFailure = state.withLock({ $0.sourceFailure }) { throw sourceFailure }
        var iterator = stream.makeAsyncIterator()
        do {
            guard let wake = try await iterator.next() else { throw CancellationError() }
            state.withLock { $0.lastWake = wake }
            // The app's own accessibility events are life; workspace news is about any app and proves nothing of this one.
            if wake == .accessibility { life?.moved() }
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw DesktopComposer.observationFailure(error, operation: "stopped")
        }
        try Task.checkCancellation()
    }
    func stop() {
        let retirement = state.withLock { state -> (stop: Bool, reader: Task<Void, Never>?, expiry: Task<Void, Never>?, lifeID: UUID?) in
            guard !state.stopped else { return (false, nil, nil, nil) }
            state.stopped = true
            let reader = state.reader, expiry = state.expiry, lifeID = state.lifeID
            state.reader = nil; state.expiry = nil; state.lifeID = nil
            return (true, reader, expiry, lifeID)
        }
        guard retirement.stop else { return }
        if let lifeID = retirement.lifeID { life?.detach(lifeID) }
        retirement.reader?.cancel()
        retirement.expiry?.cancel()
        source?.cancel()
        signal.finish()
        workspace.withLock {
            $0.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            $0.removeAll()
        }
    }
}
