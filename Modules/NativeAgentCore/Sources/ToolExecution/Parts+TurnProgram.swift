import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Parts+TurnProgram.swift` | The agent's own turn program, revised by ability.save under trial and the save law, the version it replaces kept as turn.prev.js |

extension Parts {
    /// The agent's turn program: the one shipped id that is the agent's own to revise.
    public static let turnID = "turn"

    /// The agent's turn program is the agent's to revise under the save law every part of the agent's has: under Full Mac, for the agent's own
    /// work, the save is kept and on in one act; otherwise keeping it is the person's, asked on their card for the exact call. Every revision is
    /// a trial carrying the agent's why, which the night judges per turn; the version it replaces is kept as turn.prev.js. `set_aside` saves
    /// turn.prev.js forward as the next current version. A step that throws swaps back to turn.prev.js (the turn recovery exception), which
    /// sets the trial aside; a `weigh` that fails leaves what it weighs waiting and tells the agent.
    func saveTurn(_ input: [String: JSONValue], steer: [String], fullMac: Bool, invocation: Invocation) throws -> [String: JSONValue] {
        func refuse(_ why: String) -> PartError { .invalid(why + " Nothing was saved.") }
        let applies: Set<String> = ["id", "code", "edits", "description", "verb", "preview", "why", "trial", "set_aside"]
        if let other = input.keys.sorted().first(where: { !$0.hasPrefix("__") && !applies.contains($0) }) {
            throw refuse("\(other) does not apply to your turn program; revise it with code or edits and why, or set its trial aside.")
        }
        let settingAside = input["set_aside"] == .bool(true)
        if let trial = input["trial"] {
            guard trial == .bool(true) else { throw refuse("Every revision of your turn program is a trial; send trial: true or leave it out.") }
            guard !settingAside else { throw refuse("Send trial or set_aside, not both.") }
        }
        if settingAside, let extra = input.keys.sorted().first(where: { !$0.hasPrefix("__") && !["verb", "preview", "id", "set_aside", "why"].contains($0) }) {
            throw refuse("set_aside saves the kept version forward as it was; send only id and why, not \(extra).")
        }
        var given: String?
        if input["why"] != nil {
            let text = (Self.string(input, "why") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw refuse("why is nonempty text after trimming.") }
            guard text.count <= Self.whyLimit else { throw refuse("why is at most \(Self.whyLimit) characters after trimming; this one has \(text.count).") }
            given = text
        }
        let turn = invocation.execution.turn
        // Below Full Mac, or on a turn an untrusted agent steered, keeping a revision (or setting a trial aside) is the person's: the save asks
        // for this exact call on the person's card and writes nothing. Their Approve replays it as their own act, which runs it here, trial
        // and why included; their Decline leaves nothing behind.
        let asks = turn?.personAct == nil ? Self.keepRefusal(origin: Self.origin(steeredBy: steer), name: "Your turn program", fullMac: fullMac)
            : nil
        func ask(_ what: String) -> [String: JSONValue] {
            ["status": .string("needs_person"), "id": .string(Self.turnID), "effects": .string("none"),
             "detail": .string("\(asks ?? ""): \(what) waits for the person's card, and their Approve runs this same call as theirs.")]
        }
        if settingAside {
            if asks != nil { return ask("setting your turn program's trial aside") }
            return try setTurnTrialAside(why: given, turn: turn)
        }
        guard let current = try abilities.read(id: Self.turnID, slot: .current), current.kind == .turn else {
            throw refuse("Your turn program is not installed yet; the next turn installs the seed.")
        }
        let source: String
        switch (Self.string(input, "code"), input["edits"]) {
        case (let code?, nil): source = code
        case (nil, let edits?):
            do { source = try AbilityStore.edited(current.body, edits) } catch {
                throw refuse(error.localizedDescription + " The edits apply to your current turn program, which ability.read {id:\"turn\"} shows.")
            }
        case (nil, nil): throw refuse("Send code or edits.")
        default: throw refuse("Send code or edits, not both.")
        }
        guard source.contains("function step(") else { throw refuse("A turn program defines function step(state, event).") }
        guard source != current.body else {
            return ["status": .string("ok"), "id": .string(Self.turnID), "effects": .string("none"),
                    "detail": .string("Your turn program already reads this way.")]
        }
        guard let why = given else {
            throw refuse("Every revision of your turn program is a trial: send why — what it changes and the surprise it answers, in a sentence.")
        }
        if asks != nil { return ask("this revision of your turn program, on trial with your why,") }
        var revised = current
        revised.body = source
        // Validate the complete proposed file before either retained slot or its trial can change.
        _ = try AbilityStore.encode(revised)
        var receipt: [String: JSONValue] = [
            "status": .string("kept"), "id": .string(Self.turnID), "name": .string("turn program"), "ability_status": .string("active"),
            "effects": .string("occurred"), "version": .string(revised.bodyDigest),
            "weighs": .bool(source.contains("function weigh(")),
            "detail": .string("""
                Your turn program is revised and on from your next step, on trial: the night judges it per turn against the kept version in \
                turn.prev.js; ability.save {id:\"turn\", set_aside:true, why} saves that version forward. A step that throws swaps back to it and \
                sets the trial aside; a weigh that fails leaves what it weighs waiting and tells you.
                """)]
        try AbilityStore.withLock {
            guard try abilities.read(id: Self.turnID, slot: .current) == current else {
                throw refuse("Your turn program changed while this revision was prepared; read it and revise that selection.")
            }
            // A trial never became the agent: revising the version under trial replaces it, and the kept self stays turn.prev.js and the
            // baseline the revision is judged against. Otherwise the version replaced is the kept self.
            var kept = abilities.versionKey(current)
            var keptTurns: JSONValue?
            let retained = try abilities.read(id: Self.turnID, slot: .previous)
            if let open = try abilities.states()[Self.turnID]?.objectValue?["trial"]?.objectValue,
               open["version"]?.stringValue == current.bodyDigest, let keptKey = open["kept"]?.stringValue,
               let retained, retained.kind == .turn, abilities.versionKey(retained) == keptKey {
                kept = keptKey
                keptTurns = open["kept_turns"]
                receipt["previous"] = .string(retained.bodyDigest)
            }
            var attempted = false, previousWritten = false
            do {
                if receipt["previous"] == nil {
                    try abilities.write(current, slot: .previous, turn: turn, writing: { attempted = true })
                    previousWritten = true
                    receipt["previous"] = .string(current.bodyDigest)
                }
                try abilities.write(revised, turn: turn, writing: { attempted = true })
            } catch {
                guard attempted else { throw error }
                throw ToolFailureError("Turn-program publication did not complete. "
                    + (previousWritten ? "turn.prev.js was written; " : "A slot write was attempted; ")
                    + "inspect both retained slots before another save. \(error.localizedDescription)",
                    effects: previousWritten ? .partial : .unknown, owner: "abilities/turn.js and turn.prev.js",
                    nextCall: ToolFailureError.call("app", ["action": .string("ability.read"), "args": .object(["id": .string(Self.turnID)])]),
                    code: "turn_publication_incomplete", instruction: "Read both retained versions and reconcile this publication before revising again.",
                    recovery: .reconcile)
            }
            // The files are the act: a trial write that fails after them is reported on the receipt, never an undone save. An open trial whose
            // version just left current closes as superseded by the agent; the revision opens its own.
            do {
                if let closed = try abilities.changeTrial(id: Self.turnID, .reconcile(by: "agent"), turn: turn), closed.objectValue?["verdict"] != nil {
                    receipt["superseded"] = closed
                }
                let opening = AbilityStore.TrialChange.open(version: revised.bodyDigest, kept: kept, why: why, keptTurns: keptTurns)
                if let trial = try abilities.changeTrial(id: Self.turnID, opening, turn: turn) { receipt["trial"] = trial }
                else { receipt["accounting_error"] = .string("Your turn program's trial changed meanwhile, so this version was saved without a trial.") }
            } catch { receipt["accounting_error"] = .string(error.localizedDescription) }
        }
        return receipt
    }

    /// Setting the turn program's open trial aside saves turn.prev.js, the version the trial keeps, forward as the next current version; turn.prev.js
    /// keeps it, so the version set aside is no throwing turn's way back, and the trial closes as set aside by the agent. Never a version swap: that
    /// is the throwing-turn exception's.
    private func setTurnTrialAside(why: String?, turn: Turn?) throws -> [String: JSONValue] {
        func refuse(_ why: String) -> PartError { .invalid(why + " Nothing was saved.") }
        return try AbilityStore.withLock {
            guard let open = try abilities.states()[Self.turnID]?.objectValue?["trial"] else {
                throw refuse("Your turn program has no open trial to set aside.")
            }
            guard case .object(let trial) = open, let version = Self.string(trial, "version"), let keptKey = Self.string(trial, "kept") else {
                throw refuse("Your turn program's open trial is unreadable in abilities/state.json; repair that record before setting it aside.")
            }
            guard let current = try abilities.read(id: Self.turnID, slot: .current), current.kind == .turn else {
                throw refuse("Your turn program is not installed yet; the next turn installs the seed.")
            }
            guard current.bodyDigest == version else {
                throw refuse("Your turn program's trial of \(version.prefix(12)) was superseded: the current version is not it.")
            }
            guard let kept = try abilities.read(id: Self.turnID, slot: .previous), kept.kind == .turn, abilities.versionKey(kept) == keptKey else {
                throw refuse("The kept version \(keptKey) is no longer turn.prev.js, so it cannot be saved forward.")
            }
            var forward = current
            forward.body = kept.body
            var attempted = false
            do { try abilities.write(forward, turn: turn, writing: { attempted = true }) }
            catch {
                guard attempted else { throw error }
                throw ToolFailureError("Setting the turn trial aside did not complete; the current slot may have changed. \(error.localizedDescription)",
                    effects: .unknown, owner: "abilities/turn.js",
                    nextCall: ToolFailureError.call("app", ["action": .string("ability.read"), "args": .object(["id": .string(Self.turnID)])]),
                    code: "turn_publication_incomplete", instruction: "Read the retained turn versions before another save.", recovery: .reconcile)
            }
            var receipt: [String: JSONValue] = [
                "status": .string("kept"), "id": .string(Self.turnID), "name": .string("turn program"), "ability_status": .string("active"),
                "effects": .string("occurred"), "version": .string(forward.bodyDigest), "previous": .string(kept.bodyDigest),
                "set_aside": .string(current.bodyDigest), "weighs": .bool(forward.body.contains("function weigh(")),
                "detail": .string("""
                    Your turn program's trial is set aside: the kept version \(keptKey) is saved forward and on from your next step, and stays in \
                    turn.prev.js; the version set aside is not kept.
                    """)]
            // The files are the act: the trial closes as set aside once the kept version is current, and a failure to record that is reported.
            do {
                try abilities.changeTrial(id: Self.turnID, .settingAside(version: kept.bodyDigest, why: why), turn: turn)
                // The person's own tap (Home's Set aside) is theirs on the record; anything else is the agent's.
                let by = turn?.personAct == nil ? "agent" : "person"
                if let closed = try abilities.changeTrial(id: Self.turnID, .reconcile(by: by), turn: turn),
                   closed.objectValue?["verdict"] == .string("set_aside") {
                    receipt["trial"] = closed
                } else {
                    receipt["accounting_error"] = .string("Your turn program's trial changed meanwhile, so it was not closed as set aside.")
                }
            } catch { receipt["accounting_error"] = .string(error.localizedDescription) }
            return receipt
        }
    }

    /// What reading the turn program adds: the seed's `weigh` beside the agent's own, the open trial, and how to revise it.
    func turnReading() throws -> [String: JSONValue] {
        var reading: [String: JSONValue] = [
            "weighs": .bool(try abilities.read(id: Self.turnID, slot: .current)?.body.contains("function weigh(") == true),
            "revise": .string("""
                ability.save {id:\"turn\", edits:[{old, new}], why} or {id:\"turn\", code, why}: yours under Full Mac, kept and on in one act; \
                below Full Mac the same call asks the person on a card and runs as theirs on their Approve. Every revision is a trial carrying \
                why, what it changes and the surprise it answers; the night judges it per turn. ability.save {id:\"turn\", set_aside:true, why} \
                saves turn.prev.js forward and sets the open trial aside, asking the person the same way below Full Mac.
                """),
            "trial": try abilities.states()[Self.turnID]?.objectValue?["trial"] ?? .null,
        ]
        reading["seed_weigh"] = try AbilityStore.seedFunction("weigh", of: Self.turnID).map(JSONValue.string) ?? .null
        return reading
    }
}
