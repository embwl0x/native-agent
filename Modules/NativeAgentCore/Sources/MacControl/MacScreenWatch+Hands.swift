import Foundation
import NativeAgentCore
import Senses
import CoreGraphics
import CoreMedia
import Experiences
import PersistenceCore
import ScreenCaptureKit
import Synchronization
import NativeAgentShared
// Blueprint: | `MacScreenWatch+Hands.swift` | `MacScreenWatch.hand`: One deadline, per-event authority, exact-window input and secret drag checks |

extension MacScreenWatch {
    /// Watch hands share the physical tail’s per-event authority, exact-window, obstruction and secret-field checks. The stream supplies observation;
    /// person input ends authority rather than being overridden.
    public func hand(_ verb: String, _ args: [String: JSONValue], context: MacOperationContext) async throws -> JSONValue {
        if context.deadline == nil {
            do {
                return try await OperationWaitBudget.withDeadline(
                    seconds: Double(SwiftNativeMacControl.operationTimeoutSeconds(action: "hand", body: args)),
                  budget: context.waitBudget) { budget in
                    let context = context.with(\.deadline, budget.deadline)
                    return try await self.hand(verb, args, context: context) }
            } catch is OperationWaitBudget.Exceeded {
                throw SenseFailure(code: "timed_out", message: MacFourVerbs.interruptedActReply(OperationWaitBudget.Exceeded()).text)
            }
        }
        if let refusal = handRefusal { throw SenseFailure(code: refusal.code, message: refusal.message, remedy: refusal.fields["remedy"]) }
        guard admitOperation() else { throw over ?? CancellationError() }
        defer { finishOperation() }
        guard let verbs, let binding else {
            throw SenseFailure(code: "undeclared", message: "Declare reach hands to use hand.\(verb).")
        }
        if let over { throw over }
        guard await allowed() else { throw over ?? SenseFailure(code: "watch_ended", message: "Screen control was turned off.") }
        let window = try liveWindow()
        let geometry = MacScreenViewGeometry(bounds: place(window), pixelWidth: width, pixelHeight: height)
        func point(_ x: String, _ y: String) throws -> MacPointerPosition {
            guard let px = args[x].flatMap(Self.number), let py = args[y].flatMap(Self.number),
                  let point = geometry.screenPoint(imageX: px, imageY: py) else {
                throw SenseFailure(code: "point_outside_frame", message: """
                    hand.\(verb) takes \(x), \(y) inside the \(width)×\(height) frame; nothing was sent.
                    """)
            }
            return point
        }
        let four = try await verbs()
        try Task.checkCancellation()
        guard lock.withLock({ ended == nil }) else { throw over ?? CancellationError() }
        let reply: MacFourVerbsReply
        var landed: JSONValue = .null
        switch verb {
        case "click", "double_click", "right_click", "move", "drag":
            let at = try point("x", "y"), to = verb == "drag" ? try point("to_x", "to_y") : nil
            let secrets = lock.withLock { self.secrets }
            if to != nil, secrets == nil {
                throw SenseFailure(code: "window_uninspected",
                    message: "I can't tell where \(app)'s password fields are right now, so I won't drag; nothing was sent.")
            }
            // Each pointer event hit-tests its landing point; stale opening-sight obstructions cannot authorize it.
            var seen = sighting
            seen.obstructions = []
            landed = at.json
            reply = await bound(context: context) { context in await four.performPointer(
                verb == "right_click" ? "click" : verb, at: at, to: to, saying: "\(app) at \(Int(at.x)),\(Int(at.y))",
                destination: to.map { "\(Int($0.x)),\(Int($0.y))" }, before: seen, seconds: nil, holding: nil,
                button: verb == "right_click" ? "right" : nil, attention: nil,
                secrets: (secrets ?? []).map { MacAXFrame(x: $0.x + window.x, y: $0.y + window.y, w: $0.w, h: $0.h) }, confirm: false, turn: turn,
                    context: context) }
        case "key", "hold", "down", "up":
            guard case .string(let keys)? = args["keys"], !keys.isEmpty else {
                throw SenseFailure(code: "bad_input", message: "hand.\(verb) takes keys, such as \"w\" or \"cmd+s\".")
            }
            let gesture = verb == "key" ? verb : verb == "hold" ? "hold_key" : "key_" + verb
            var body: [String: JSONValue] = ["keys": .string(keys), "gesture": .string(gesture)]
            if verb == "hold" { body["seconds"] = args["seconds"] ?? .double(0.6) }
            reply = await bound(context: context) { context in await four.performHand(body: body, description: "Pressed \(keys) in \(self.app).",
                before: nil, confirm: false, turn: turn, context: context) }
        default:
            throw SenseFailure(code: "unsupported", message: "hand has click, double_click, right_click, move, drag, key, hold, down and up.")
        }
        guard reply.ok else {
            if !binding.allowsEmission(context: context) { end("taken_over") }
            if let over { throw over }
            let error = reply.detail["error"].flatMap { if case .string(let text) = $0 { text } else { nil } } ?? "refused"
            throw SenseFailure(code: String(error.prefix { $0 != ":" }), message: reply.text, remedy: reply.detail["remedy"])
        }
        lock.withLock { hands += 1 }
        return .object(["screen": landed])
    }

    /// The watch binding permits each event only while it still lands on the watched window.
    private func bound(context: MacOperationContext, _ work: (MacOperationContext) async -> MacFourVerbsReply) async -> MacFourVerbsReply {
        await context.holding(\.driver, binding) { context in
            await context.holding(\.holdsAcrossCalls, true) { context in
                await context.holding(\.requiredFrontPid, pid) { context in
                    await context.holding(\.requiredFrontWindow, windowNumber) { context in await work(context) }
                }
            }
        }
    }

}
