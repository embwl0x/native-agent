import Foundation
import Synchronization
import NativeAgentCore
import PersistenceCore
import TurnTrace
#if canImport(AppKit) && canImport(ApplicationServices) && os(macOS)
import AppKit
import ApplicationServices
#endif

// Blueprint: | `MacAppWord.swift` | Event-paced effect settlement, off-lane app admission and payload-free mac.settled receipts |

enum MacSettleEnd: String, Sendable { case held, patience, stopped, failed }
enum MacAppReply: String, Sendable { case answered, gone, unreachable, busy, stopped }

struct MacSettledRow: Sendable {
    let what: String
    let endedBy: String
    var firstNotificationMs: Int? = nil
    var passGapMs: Int? = nil
    var passes = 0
    var busyWaitMs: Int? = nil
}

func macSettled(_ row: MacSettledRow) {
    let at = Date()
    TurnTraceBus.fire(TurnTraceEvent(kind: "mac.settled", title: "Mac settlement", status: row.endedBy, payload: .object([
        "what": .string(row.what), "ended_by": .string(row.endedBy),
        "first_notification_ms": row.firstNotificationMs.map { .int(Int64($0)) } ?? .null,
        "pass_gap_ms": row.passGapMs.map { .int(Int64($0)) } ?? .null,
        "passes": .int(Int64(row.passes)),
        "busy_wait_ms": row.busyWaitMs.map { .int(Int64($0)) } ?? .null
    ]), createdAt: NativeTimestampFormat.plainZulu(at), ts: at, turnId: TurnTraceContext.turnId, turn: nil),
        on: TurnTraceContext.bus ?? .shared)
}

/// The observer is armed before emission. Each wake requests evidence; only the judge establishes the effect.
/// A judge that cannot read its evidence throws, ending the wait as failed.
func macSettle(_ what: String, signals: MacWaitSignals, patience: Double, until: Set<String> = [],
               isolation: isolated (any Actor)? = #isolation, judge: () async throws -> Bool) async -> MacSettleEnd {
    await macSettleLoop(what, signals: signals, patience: patience, until: until, record: true, judge: judge)
}

private func macSettleLoop(_ what: String, signals: MacWaitSignals, patience: Double, until: Set<String>, record: Bool,
                           isolation: isolated (any Actor)? = #isolation, judge: () async throws -> Bool) async -> MacSettleEnd {
    let start = Date()
    let deadline = start.addingTimeInterval(max(0, patience))
    var passes = 0
    var gap: Int?
    var end = MacSettleEnd.stopped
    defer {
        if record {
            macSettled(MacSettledRow(what: what, endedBy: end.rawValue,
                firstNotificationMs: signals.collector.first().map { max(0, Int($0.at.timeIntervalSince(signals.startedAt) * 1000)) },
                passGapMs: gap, passes: passes))
        }
    }
    while !Task.isCancelled {
        let batch = signals.collector.drain()
        gap = batch.last.map { max(0, Int(Date().timeIntervalSince($0.at) * 1000)) }
        let atPatience = Date() >= deadline
        if until.isEmpty || batch.contains(where: { until.contains($0.kind) }) || atPatience {
            passes += 1
            do {
                let satisfied = try await judge()
                if Task.isCancelled { break }
                if satisfied { end = .held; return end }
            } catch {
                if Task.isCancelled { break }
                end = .failed
                return end
            }
        }
        if Task.isCancelled { break }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { end = .patience; return end }
        _ = await signals.waitForSignal(seconds: remaining)
    }
    return end
}

private final class MacAppReplyState: Sendable {
    struct Value { var reply: MacAppReply?; var cause: String?; var stopped = false; var probes = 0 }
    let value = Mutex(Value())
}

/// A private AX element keeps a busy app's IPC off the shared observer run loop.
@concurrent func macAppReply(pid: Int32, patience: Double, context: MacOperationContext,
                             onFailure: @escaping @Sendable (String) -> Void = { _ in }) async -> MacAppReply {
    if Task.isCancelled { return .stopped }
    if context.expired { return .busy }
    let start = Date()
    let state = MacAppReplyState()
    let collector = MacAXEffectCollector()
    let signals = MacWaitSignals(collector: collector)
    let launching = DispatchSemaphore(value: 0)
    defer { signals.stop(); state.value.withLock { $0.stopped = true }; launching.signal() }
    #if canImport(AppKit) && canImport(ApplicationServices) && os(macOS)
    let center = NSWorkspace.shared.notificationCenter
    let termination = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier == pid else { return }
        state.value.withLock { if !$0.stopped, $0.reply == nil { $0.reply = .gone } }
        collector.signal()
        launching.signal()
    }
    defer { center.removeObserver(termination) }
    guard !PersonOnlyWindows.isOwnProcess(pid) else { return .unreachable }
    DispatchQueue.global(qos: .userInitiated).async {
        func finish(_ reply: MacAppReply, cause: String? = nil) {
            state.value.withLock {
                if !$0.stopped, $0.reply == nil { $0.reply = reply; $0.cause = cause }
            }
            collector.signal()
        }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { finish(.gone); return }
        let element = AXUIElementCreateApplication(pid)
        let configured = AXUIElementSetMessagingTimeout(element, 6)
        guard configured == .success else { finish(.unreachable, cause: "AX message limit: \(configured.rawValue)"); return }
        var waitedForLaunch = false
        while !state.value.withLock({ $0.stopped }) {
            if app.isTerminated { finish(.gone); return }
            state.value.withLock { $0.probes += 1 }
            let asked = Date()
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
            if error == .success, value != nil { finish(.answered); return }
            guard error == .cannotComplete else {
                finish(.unreachable, cause: "AX application role read: \(error.rawValue) (value present: \(value != nil))"); return
            }
            if Date().timeIntervalSince(asked) >= 1 { continue }
            guard !waitedForLaunch, !app.isFinishedLaunching else {
                finish(.unreachable, cause: "The launched app returned AX cannot-complete (\(error.rawValue)) without a slow IPC wait."); return
            }
            waitedForLaunch = true
            let observation = app.observe(\.isFinishedLaunching, options: [.initial, .new]) { app, _ in
                if app.isFinishedLaunching { launching.signal() }
            }
            launching.wait()
            observation.invalidate()
        }
    }
    #else
    state.value.withLock { $0.reply = .unreachable; $0.cause = "Accessibility admission requires macOS." }
    #endif
    var seconds = max(0, patience)
    if let wall = context.wallDate { seconds = min(seconds, max(0, wall.timeIntervalSinceNow)) }
    let end = await macSettleLoop("app_reply", signals: signals, patience: seconds, until: [], record: false) { state.value.withLock { $0.reply != nil } }
    let reply: MacAppReply = state.value.withLock {
        $0.stopped = true
        return end == .stopped ? .stopped : end == .patience ? .busy : $0.reply ?? .busy
    }
    if let cause = state.value.withLock({ $0.cause }) { onFailure(cause) }
    macSettled(MacSettledRow(what: "app_reply", endedBy: reply.rawValue, passes: state.value.withLock { $0.probes },
        busyWaitMs: max(0, Int(Date().timeIntervalSince(start) * 1000))))
    return reply
}

@concurrent func macAdmit(pid: Int32, context: MacOperationContext,
                          onFailure: @escaping @Sendable (String) -> Void = { _ in }) async -> MacAppReply {
    let reply = await macAppReply(pid: pid, patience: 10, context: context, onFailure: onFailure)
    guard reply == .answered, !Task.isCancelled, !context.expired else {
        return Task.isCancelled ? .stopped : reply == .answered ? .busy : reply
    }
    #if canImport(AppKit) && canImport(ApplicationServices) && os(macOS)
    do { try await SystemMacAXElementSource.prepareRenderer(pid: pid, context: context.with(\.readDeadline, nil)) }
    catch {
        if Task.isCancelled { return .stopped }
        onFailure("Renderer admission: " + error.localizedDescription)
        macSettled(MacSettledRow(what: "renderer_admission", endedBy: "unreachable"))
        return .unreachable
    }
    #endif
    return Task.isCancelled ? .stopped : context.expired ? .busy : .answered
}

extension SwiftNativeMacControl {
    func macAdmissionRefusal(pid: Int32, action: String, context: MacOperationContext) async -> MacControlResult? {
        if PersonOnlyWindows.isOwnProcess(pid) {
            return injectionRefusal(action: action, error: Self.selfInspectionError, status: 409)
        }
        let failure = MacAppReplyState()
        let reply = await macAdmit(pid: pid, context: context) { cause in failure.value.withLock { $0.cause = cause } }
        guard reply != .answered else { return nil }
        let message: String
        switch reply {
        case .busy: message = "The app is busy; nothing was pressed. Wait for it to answer before another action."
        case .gone: message = "The app exited before answering; nothing was pressed."
        case .stopped: message = "Stopped while waiting for the app; nothing was pressed."
        case .unreachable: message = "The app's accessibility channel could not answer; nothing was pressed. Inspect its accessibility availability."
        case .answered: return nil
        }
        var evidence: [String: JSONValue] = ["message": .string(message), "effects": .string("none"), "posted_events": .int(0)]
        if let cause = failure.value.withLock({ $0.cause }) {
            evidence["cause"] = .string(cause)
            evidence["message"] = .string(message + " " + cause)
        }
        return injectionRefusal(action: action, error: "app_" + reply.rawValue, status: 409, extra: evidence)
    }
}
