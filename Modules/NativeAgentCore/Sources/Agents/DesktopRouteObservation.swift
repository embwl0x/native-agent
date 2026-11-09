import AppKit
import ApplicationServices
import AgentConversations
import MacControl
import NativeAgentCore
import PersistenceCore
import Synchronization
// Blueprint: | `DesktopRouteObservation.swift` | Sendable observation owns locked wake state; AX and workspace events wake cancellable desktop waits. |
/// Register before the first predicate read. An unavailable source reports its cause; every caller stops its observer.
final class DesktopRouteObservation: Sendable {
    enum Wake: String, Sendable {
        case initialRead = "initial_read"
        // The AX stream includes its registration-race signal. A wake does not claim that a change notification or content change occurred.
        case accessibility = "accessibility_subscription"
        case workspace
        case unavailable = "observation_unavailable"
    }
    private let stream: AsyncThrowingStream<Wake, Error>
    private let signal: AsyncThrowingStream<Wake, Error>.Continuation
    private let source: MacAppSourceEvents?
    private struct State: Sendable {
        var sourceFailure: Error?
        var lastWake: Wake = .initialRead
        var stopped = false
        var reader: Task<Void, Never>?
    }
    private let state: Mutex<State>
    private let workspace: Mutex<[NSObjectProtocol]>

    init(bundleID: String, context: MacOperationContext, accessibility: Bool = true) async throws {
        try Task.checkCancellation()
        var initialFailure: Error?
        do { source = accessibility ? try await MacAppSourceEvents.open(bundleID: bundleID, context: context) : nil }
        catch is CancellationError { throw CancellationError() }
        catch {
            source = nil
            initialFailure = GrokRoutineAccessibility.observationFailure(error, operation: "for \(bundleID) could not start")
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
        if let source {
            let reader = Task { [weak self] in
                do {
                    for try await _ in source.stream {
                        guard !Task.isCancelled else { return }
                        pair.continuation.yield(.accessibility)
                    }
                    guard !Task.isCancelled else { return }
                    self?.state.withLock { $0.sourceFailure = GrokRoutineAccessibility.Failure(detail: """
                            Accessibility observation ended before the condition was confirmed. Bring the app forward with its Accessibility tree \
                            available, then continue.
                            """) }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.state.withLock { $0.sourceFailure = GrokRoutineAccessibility.observationFailure(error, operation: "stopped") }
                }
                // Let the caller read once before surfacing the lost wake.
                pair.continuation.yield(.unavailable)
            }
            state.withLock { $0.reader = reader }
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
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw GrokRoutineAccessibility.observationFailure(error, operation: "stopped")
        }
        try Task.checkCancellation()
    }
    func stop() {
        let retirement = state.withLock { state -> (stop: Bool, reader: Task<Void, Never>?) in
            guard !state.stopped else { return (false, nil) }
            state.stopped = true
            let reader = state.reader
            state.reader = nil
            return (true, reader)
        }
        guard retirement.stop else { return }
        retirement.reader?.cancel()
        source?.cancel()
        signal.finish()
        workspace.withLock {
            $0.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            $0.removeAll()
        }
    }
}
