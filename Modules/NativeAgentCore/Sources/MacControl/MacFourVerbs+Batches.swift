import Foundation
import NativeAgentCore
import PersistenceCore
import Experiences
import CryptoKit
// Blueprint: | `MacFourVerbs+Batches.swift` | `MacFourVerbs`: `actSteps`, `SightCarry`, `ActFlow` and step digests; cancellation and confirmed effect mismatches stop further steps while preserving landed or uncertain receipts for resume |

extension MacFourVerbs {
    // MARK: batched steps

    static let maximumActSteps = 12
    static let oneCallNudge = "A whole flow (menu, sheet, name, Save) fits in one act call with steps."

    /// One batch's hand-off: the post-act read of step N, taken once and used
    /// as step N+1's pre-read. Sequential use inside one call only.
    final class SightCarry: @unchecked Sendable {
        var last: Sighting?
        func take() -> Sighting? {
            defer { last = nil }
            return last
        }
    }

    /// Each step uses the prior post-read, verifies its effect and target, and stops the batch at the first failure.
    func actSteps(_ steps: [MacActStep], app: String?, expect: FrontExpectation?, seen: Sighting? = nil,
                  flow: ActFlow? = nil) async -> MacFourVerbsReply {
        guard steps.count <= Self.maximumActSteps else {
            return MacFourVerbsReply(
                ok: false,
                text: "That's \(steps.count) steps; one act takes at most \(Self.maximumActSteps). Nothing was touched.",
                detail: ["error": .string("too_many_steps")]
            )
        }
        let carry = SightCarry()
        carry.last = seen
        let scope = flowSession.map(Self.actFlowScope)
        let keptLine = Self.keptLine(flow)
        let evidence = Experience.currentAct.map { Experience.Ref(source: "act", id: $0) }
        // What each step did, in order: its digest when it landed, "?" before it
        // when it was an optional step that wasn't there (re-checked next time).
        var outcomes: [String] = []
        var lines: [String] = []
        var screen: String?
        var frontChanged = false
        for (index, asked) in steps.enumerated() {
            if let flow, flow.kept(index) {
                lines.append("\(index + 1) \(asked.target) " + (flow.landed[index].hasPrefix("~")
                    ? "~ (its effect was unknown when the batch stopped at \(Self.clockTime(flow.at)); not repeated)"
                    : "✓ (landed \(Self.clockTime(flow.at)), not repeated)"))
                outcomes.append(flow.landed[index])
                continue
            }
            // "OK?" — an optional step (a confirm that only sometimes appears):
            // skipped, not failed, when nothing answers to it.
            let optional = asked.target.hasSuffix("?") && asked.target.count > 1
            let step = optional ? MacActStep(verb: asked.verb, target: String(asked.target.dropLast()), text: asked.text,
                                             mode: asked.mode, to: asked.to, place: asked.place) : asked
            // After step 1 the app's own sheet or dialog (a save sheet) may be
            // what's in front: the same process is still required, not the
            // same window rect.
            let stepExpect: FrontExpectation? = index == 0 ? expect : expect.map { (pid: $0.pid, frame: nil) }
            let commitFollows = index + 1 < steps.count && Self.pressesReturn(steps[index + 1])
            // A batch resumed in front keeps what its last step in the back typed.
            let previousTyped = index == 0 ? Self.typedJustBefore
                : Self.parseVerb(steps[index - 1].verb).0 == "type" ? steps[index - 1].text : nil
            let typedBefore = ["key", "press"].contains(Self.parseVerb(step.verb).0) ? previousTyped : nil
            var reply = await Self.$typedJustBefore.withValue(typedBefore) {
                guard !Task.isCancelled else {
                    return MacFourVerbsReply(ok: false, text: "The action was cancelled; no further steps ran.", detail: ["error": .string("cancelled")])
                }
                return await actOnce(
                    verb: step.verb, target: step.target, text: step.text, mode: step.mode, to: step.to, toApp: nil,
                    seconds: nil, holding: nil, button: nil, scrollAmount: nil, attention: nil,
                    app: app, expect: stepExpect, carry: carry, commitFollows: commitFollows, menus: !optional, place: step.place
                )
            }
            // Allow bounded fresh reads for a settling surface and one re-resolution after pre-act drift.
            var looks = 0
            var reResolved = false
            // Cancellation closes step/retry admission; the returned receipt
            // still owns whether this step landed or may have acted.
            while !Task.isCancelled {
                let error = Self.string(reply.detail["error"])
                if index > 0, looks < 3, error == "no_match" {
                    looks += 1
                } else if !reResolved, ["handle_drifted", "window_drifted", "frame_window_gone", "stale_frame"].contains(error) {
                    reResolved = true
                } else {
                    break
                }
                await clock.sleep(seconds: 0.4)
                if Task.isCancelled { break }
                reply = await Self.$typedJustBefore.withValue(typedBefore) {
                    await actOnce(
                        verb: step.verb, target: step.target, text: step.text, mode: step.mode, to: step.to, toApp: nil,
                        seconds: nil, holding: nil, button: nil, scrollAmount: nil, attention: nil,
                        app: app, expect: stepExpect, carry: carry, commitFollows: commitFollows, menus: !optional, place: step.place
                    )
                }
            }
            if optional, Self.string(reply.detail["error"]) == "no_match" {
                lines.append("\(index + 1) \(step.target) — not there, skipped (optional)")
                if let flow { outcomes.append("?" + flow.digests[index]) }
                continue
            }
            let parts = reply.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count > 1 { screen = String(parts[1]) }
            if Self.bool(reply.detail["owner_front_changed"]) == true
                || Self.string(reply.detail["error"]) == "owner_changed_apps" { frontChanged = true }
            let verified = Self.string(reply.detail["verification"]) == MotorVerificationState.satisfied.rawValue
            let mark = !reply.ok ? "✗" : (verified ? "✓" : "~ (unverified)")
            lines.append("\(index + 1) \(parts.first.map(String.init) ?? step.target) \(mark)")
            if !reply.ok, Self.string(reply.detail["error"]) == "no_match" {
                lines[lines.count - 1] += " (if it only sometimes appears, write it as \"\(step.target)?\")"
            }
            guard reply.ok else {
                let why = Self.string(reply.detail["error"]) ?? Self.string(reply.detail["status"]) ?? "failed"
                var detail = reply.detail
                detail["failed_step"] = .int(Int64(index + 1))
                detail["steps_completed"] = .int(Int64(index))
                detail["steps_total"] = .int(Int64(steps.count))
                detail["owner_front_changed"] = .bool(frontChanged)
                // A step that may have acted is never sent blind again (kept as uncertain);
                // one that didn't is looked for again. Steps past it keep what they did before.
                if let flow { outcomes.append((Self.outcomeUnknown(reply) ? "~" : "?") + flow.digests[index]) }
                let landed = outcomes + (flow?.landed.dropFirst(outcomes.count) ?? [])
                if let root = flowRoot, let scope, let evidence, landed.contains(where: { !$0.hasPrefix("?") }) {
                    Flow.stopped(root, scope: scope, landed: landed,
                        words: "mac.act stopped at step \(index + 1) (\(why)); \(landed.filter { !$0.hasPrefix("?") }.count) steps had landed.",
                        evidence: evidence, cause: [evidence.id])
                }
                return MacFourVerbsReply(
                    ok: false,
                    text: keptLine + "Stopped at step \(index + 1) of \(steps.count) (\(why)); the rest were not run.\n"
                        + lines.joined(separator: "\n") + (screen.map { "\n" + $0 } ?? ""),
                    detail: detail
                )
            }
            if let flow { outcomes.append(flow.digests[index]) }
        }
        if screen == nil, case .seen(let hit) = await sight(part: nil, app: app) { screen = hit.render }
        if let root = flowRoot, let scope, let evidence { Flow.finished(root, scope: scope, evidence: evidence) }
        return MacFourVerbsReply(
            ok: true,
            text: (keptLine.isEmpty ? "Did all \(steps.count) steps." : keptLine + "did the rest.")
                + "\n" + lines.joined(separator: "\n") + (screen.map { "\n" + $0 } ?? ""),
            detail: [
                "steps_completed": .int(Int64(steps.count)),
                "steps_total": .int(Int64(steps.count)),
                "owner_front_changed": .bool(frontChanged),
                "background": .bool(app != nil),
            ]
        )
    }

    /// One stopped batch per chat: the next act in it continues or ends it.
    static func actFlowScope(_ session: String) -> String { "mac.act/" + session }

    static func clockTime(_ stamp: String) -> String { String(stamp.dropFirst(11).prefix(8)) + "Z" }

    /// A batch's steps as digests (never its typed text), with what a stopped
    /// batch in this chat already landed.
    struct ActFlow: Sendable {
        var digests: [String]
        var landed: [String] = []
        var at = ""
        /// A stopped batch continues from matching landed steps; later steps may be corrected.
        func continues(_ landed: [String]) -> Bool {
            let did = Array(landed.reversed().drop { $0.hasPrefix("?") }.reversed())
            return !did.isEmpty && digests.starts(with: did.map { $0.hasPrefix("?") || $0.hasPrefix("~") ? String($0.dropFirst()) : $0 })
        }
        /// Landed ("<digest>") or may have ("~<digest>"); "?<digest>" was an absent optional step, looked for again.
        func kept(_ index: Int) -> Bool { landed.indices.contains(index) && !landed[index].hasPrefix("?") }
        var keptCount: Int { landed.filter { !$0.hasPrefix("?") }.count }
    }

    static func keptLine(_ flow: ActFlow?) -> String {
        guard let flow, flow.keptCount > 0 else { return "" }
        return "Kept \(flow.keptCount) steps that already landed at \(clockTime(flow.at)) (again:true runs them all again); "
    }

    /// The app is part of each step: the same steps in another app never landed there.
    static func actStepDigests(_ steps: [MacActStep], app: String?) -> [String] {
        steps.map { step in
            func point(_ point: MacPointerPosition?) -> JSONValue {
                point.map { .array([.double($0.x), .double($0.y)]) } ?? .null
            }
            let value = JSONValue.array([.string(app ?? ""), .string(step.verb), .string(step.target), step.text.map(JSONValue.string) ?? .null,
                .string(step.mode.rawValue), step.to.map(JSONValue.string) ?? .null,
                step.place.map { .array([$0.image.map(JSONValue.string) ?? .null, point($0.at), point($0.to)]) } ?? .null])
            return SHA256.hash(data: (try? value.serializedData(pretty: false)) ?? Data()).map { String(format: "%02x", $0) }.joined()
        }
    }
}
