import Foundation
import NativeAgentCore
import Senses
import CoreGraphics
import CoreMedia
import Experiences
import PersistenceCore
import ScreenCaptureKit
import Synchronization
// Blueprint: | `MacScreenWatch+Hands.swift` | `MacScreenWatch.hand`: frame-pixel input through four verbs on the watch binding, with current authority, exact front window, secret drag bounds and person takeover |

extension MacScreenWatch {
    /// One hand in frame pixels: click, double_click, right_click and move at
    /// {x,y}; drag {x,y,to_x,to_y}; key, hold ({keys, seconds}), down and up
    /// with {keys}. The four verbs' physical tail with every check but the
    /// fresh sight and the confirming look: the point inside the watched
    /// window where it is now, nothing of another app over it, a drag clear of
    /// password fields, the watched window its app's front window at every
    /// event, the person's input never overridden.
    public func hand(_ verb: String, _ args: [String: JSONValue]) async throws -> JSONValue {
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
                throw SenseFailure(code: "point_outside_frame", message: "hand.\(verb) takes \(x), \(y) inside the \(width)×\(height) frame; nothing was sent.")
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
                throw SenseFailure(code: "window_uninspected", message: "I can't tell where \(app)'s password fields are right now, so I won't drag; nothing was sent.")
            }
            // Each pointer event is hit-tested where it lands (handleHand), so the
            // opening sight's covering windows are not consulted.
            var seen = sighting
            seen.obstructions = []
            landed = at.json
            reply = await bound { await four.performPointer(
                verb == "right_click" ? "click" : verb, at: at, to: to, saying: "\(app) at \(Int(at.x)),\(Int(at.y))",
                destination: to.map { "\(Int($0.x)),\(Int($0.y))" }, before: seen, seconds: nil, holding: nil,
                button: verb == "right_click" ? "right" : nil, attention: nil,
                secrets: (secrets ?? []).map { MacAXFrame(x: $0.x + window.x, y: $0.y + window.y, w: $0.w, h: $0.h) }, confirm: false) }
        case "key", "hold", "down", "up":
            guard case .string(let keys)? = args["keys"], !keys.isEmpty else {
                throw SenseFailure(code: "bad_input", message: "hand.\(verb) takes keys, such as \"w\" or \"cmd+s\".")
            }
            let gesture = verb == "key" ? verb : verb == "hold" ? "hold_key" : "key_" + verb
            var body: [String: JSONValue] = ["keys": .string(keys), "gesture": .string(gesture)]
            if verb == "hold" { body["seconds"] = args["seconds"] ?? .double(0.6) }
            reply = await bound { await four.performHand(body: body, description: "Pressed \(keys) in \(self.app).", before: nil, confirm: false) }
        default:
            throw SenseFailure(code: "unsupported", message: "hand has click, double_click, right_click, move, drag, key, hold, down and up.")
        }
        guard reply.ok else {
            if !binding.allowsEmission { end("taken_over") }
            if let over { throw over }
            let error = reply.detail["error"].flatMap { if case .string(let text) = $0 { text } else { nil } } ?? "refused"
            throw SenseFailure(code: String(error.prefix { $0 != ":" }), message: reply.text, remedy: reply.detail["remedy"])
        }
        lock.withLock { hands += 1 }
        return .object(["screen": landed])
    }

    /// One hand on the watch's binding: every event goes out only while it
    /// lands on the watched window, checked at that event (handleHand).
    private func bound(_ work: () async -> MacFourVerbsReply) async -> MacFourVerbsReply {
        await MacDriverContext.$binding.withValue(binding) {
            await MacDriverContext.$holdsAcrossCalls.withValue(true) {
                await MacFourVerbs.$requiredFrontPid.withValue(pid) {
                    await MacFourVerbs.$requiredFrontWindow.withValue(windowNumber) { await work() }
                }
            }
        }
    }

}
