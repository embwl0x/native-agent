import AppKit
import os
import ApplicationServices
import AgentConversations
import MacControl
import NativeAgentCore
import PersistenceCore
import Senses
// Blueprint: | `DesktopRouteObservation.swift` | Existing operation-owned AX/workspace/keyboard observation, exact boundary timer and bounded unsupported-source polling |
/// One desktop operation's observation, registered before its first predicate
/// read. AX/workspace/input events wake it; a one-shot timer settles a quiet
/// interval or ends a bounded wait. With no supported AX notifications, reads
/// wake every 250ms only inside the caller's deadline. Every caller stops it.
/// Observation is a wake, never a precondition: a failed registration or
/// renewal is reported only after the caller has read its condition.
@MainActor final class DesktopRouteObservation {
    enum Wake: String, Sendable {
        case initialRead = "initial_read"
        // The AX stream includes its registration-race signal. A wake does
        // not claim that a change notification or content change occurred.
        case accessibility = "accessibility_subscription"
        case workspace, keyboard
        case boundary = "time_boundary"
        case interval = "external_protocol_poll"
        case unavailable = "observation_unavailable"
    }
    private let stream: AsyncThrowingStream<Wake, Error>
    private let signal: AsyncThrowingStream<Wake, Error>.Continuation
    private let source: MacAppSourceEvents?
    private var sourceFailure: Error?
    private let timer: DispatchSourceTimer
    private(set) var pollingReason: String?
    private var lastWake: Wake = .initialRead
    private var stopped = false
    private var reader: Task<Void, Never>?
    private var workspace: [NSObjectProtocol] = []
    private var input: [Any] = []

    init(bundleID: String, accessibility: Bool = true, keyboard: Bool = false) throws {
        try Task.checkCancellation()
        do { source = accessibility ? try MacAppSourceEvents(bundleID: bundleID) : nil }
        catch is CancellationError { throw CancellationError() }
        catch {
            source = nil
            pollingReason = Self.unsupportedReason(error)
            if pollingReason == nil {
                sourceFailure = GrokRoutineAccessibility.observationFailure(error, operation: "for \(bundleID) could not start")
            }
        }
        let pair = AsyncThrowingStream<Wake, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; signal = pair.continuation
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer.resume()
        workspace = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didUnhideApplicationNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
                pair.continuation.yield(.workspace)
            }
        }
        if keyboard {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ in pair.continuation.yield(.keyboard) }) {
                input.append(monitor)
            }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
                pair.continuation.yield(.keyboard); return event
            }) { input.append(monitor) }
        }
        if let source {
            reader = Task { [weak self] in
                do {
                    for try await _ in source.stream {
                        guard !Task.isCancelled else { return }
                        pair.continuation.yield(.accessibility)
                    }
                    guard !Task.isCancelled else { return }
                    self?.sourceFailure = GrokRoutineAccessibility.Failure(detail: "Accessibility observation ended before the condition was confirmed. Bring the app forward with its Accessibility tree available, then continue.")
                } catch {
                    guard !Task.isCancelled else { return }
                    if let reason = Self.unsupportedReason(error) { self?.pollingReason = reason }
                    else { self?.sourceFailure = GrokRoutineAccessibility.observationFailure(error, operation: "stopped") }
                }
                // Let the caller read once before surfacing the lost wake.
                pair.continuation.yield(.unavailable)
            }
        }
    }
    private static func unsupportedReason(_ error: Error) -> String? {
        guard let failure = error as? SenseFailure, failure.code == "source_unsupported" else { return nil }
        return failure.message
    }
    func receipt(readBy: String) -> JSONValue {
        var fields: [String: JSONValue] = ["read_by": .string(readBy), "wake": .string(lastWake.rawValue),
            "mode": .string(pollingReason != nil ? "external_protocol_poll" : sourceFailure != nil ? "unavailable" : "source_events")]
        if let pollingReason { fields["reason"] = .string(pollingReason) }
        if let sourceFailure { fields["reason"] = .string(sourceFailure.localizedDescription) }
        return .object(fields)
    }
    func next(until deadline: Date? = nil) async throws {
        try Task.checkCancellation()
        if let sourceFailure { throw sourceFailure }
        defer { timer.schedule(deadline: .distantFuture) }
        if let deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { lastWake = .boundary; return }
            let interval = pollingReason != nil && remaining > 0.25
            let wake: Wake = interval ? .interval : .boundary
            let signal = self.signal
            timer.setEventHandler { signal.yield(wake) }
            timer.schedule(deadline: .now() + (interval ? 0.25 : remaining))
        } else {
            timer.schedule(deadline: .distantFuture)
            guard pollingReason == nil else {
                throw GrokRoutineAccessibility.Failure(detail: "Desktop interval observation requires the step's own deadline; no unbounded interval reader was started.")
            }
        }
        var iterator = stream.makeAsyncIterator()
        do {
            guard let wake = try await iterator.next() else { throw CancellationError() }
            lastWake = wake
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw GrokRoutineAccessibility.observationFailure(error, operation: "stopped")
        }
        try Task.checkCancellation()
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        reader?.cancel(); reader = nil
        source?.cancel()
        timer.cancel()
        signal.finish()
        workspace.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspace.removeAll()
        input.forEach { NSEvent.removeMonitor($0) }; input.removeAll()
    }
}
