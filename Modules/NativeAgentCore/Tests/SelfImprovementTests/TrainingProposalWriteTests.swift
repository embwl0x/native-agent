import Testing
import Foundation
import os
@testable import SelfImprovement
import NativeAgentCore
import PersistenceCore

// MARK: - wave 33 W10: training-proposal write-side parity tests
//
// Seeds a temp data root mirroring the daemon's on-disk layout, then asserts
// approveTrainingProposalLocal / rejectTrainingProposalLocal reproduce the
// direct proposal mutation path and the Swift-native route_through_promotion
// staging path.

private struct WriteTempRoot {
    let root: URL

    static func make() throws -> WriteTempRoot {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tp-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return WriteTempRoot(root: root)
    }

    func proposalsDir() throws -> URL {
        let d = root
            .appendingPathComponent("training_journal", isDirectory: true)
            .appendingPathComponent("proposals", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func memoryDir() throws -> URL {
        let d = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func ledgerPath() -> URL {
        root.appendingPathComponent("training_journal", isDirectory: true)
            .appendingPathComponent("audit_ledger.jsonl")
    }

    /// Write `<root>/trust/policy.json` raw. Omit to leave it absent (defaults
    /// apply: route_through_promotion default-TRUE, training allowed default-TRUE).
    func writeTrustPolicy(_ json: String) throws {
        let dir = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("policy.json"), atomically: true, encoding: .utf8)
    }

    func write(_ url: URL, _ text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func wactor(_ t: WriteTempRoot) -> SwiftNativeSelfImprovement {
    SwiftNativeSelfImprovement(dataRoot: t.root)
}

private func wobj(_ v: JSONValue) -> [String: JSONValue] {
    if case .object(let o) = v { return o }
    return [:]
}

private func wstr(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}

/// Direct-mode trust policy: route_through_promotion EXPLICITLY false, training
/// allowed (autonomous_training true). This is the only policy under which the
/// Swift approve does the work; the default routes through promotion.
private let directModePolicy = """
{"trainingPolicy":{"autonomous_training":true,"route_through_promotion":false}}
"""

@Suite("Training-proposal write-side")
struct TrainingProposalWriteTests {

    // MARK: reject

    @Test("reject: sets status+reason, preserves other keys, returns daemon shape")
    func rejectHappy() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        let pdir = try t.proposalsDir()
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-1","status":"pending","target_doc":"SOUL.md","rationale":"keep me"}
        """)

        let result = try await wactor(t).rejectTrainingProposalLocal(proposalId: "P-1", reason: "nope")
        // Daemon shape: {"status":"rejected","proposal_id":...,"reason":...}.
        #expect(wstr(wobj(result)["status"]) == "rejected")
        #expect(wstr(wobj(result)["proposal_id"]) == "P-1")
        #expect(wstr(wobj(result)["reason"]) == "nope")

        // File mutated in place; sibling keys preserved.
        let raw = try #require(t.read(pdir.appendingPathComponent("p1.json")))
        let parsed = wobj(try JSONValue.parse(Data(raw.utf8)))
        #expect(wstr(parsed["status"]) == "rejected")
        #expect(wstr(parsed["rejection_reason"]) == "nope")
        #expect(wstr(parsed["rationale"]) == "keep me")
        #expect(wstr(parsed["target_doc"]) == "SOUL.md")
    }

    @Test("reject: any prior status can be overwritten (daemon does not gate)")
    func rejectAnyStatus() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        let pdir = try t.proposalsDir()
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-2","status":"approved"}
        """)
        _ = try await wactor(t).rejectTrainingProposalLocal(proposalId: "P-2", reason: "x")
        let parsed = wobj(try JSONValue.parse(Data(t.read(pdir.appendingPathComponent("p1.json"))!.utf8)))
        #expect(wstr(parsed["status"]) == "rejected")
    }

    @Test("reject: not-found throws .proposalNotFound")
    func rejectNotFound() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        _ = try t.proposalsDir()
        await #expect(throws: SwiftNativeSelfImprovement.TrainingProposalWriteError.proposalNotFound("ghost")) {
            _ = try await wactor(t).rejectTrainingProposalLocal(proposalId: "ghost", reason: "x")
        }
    }

    @Test("reject: empty reason defaults to \"No reason given\"")
    func rejectEmptyReasonDefaults() async throws {
        // Preserve the established external behavior: empty reason persists
        // "No reason given"; whitespace-only reasons are preserved.
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        let pdir = try t.proposalsDir()
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-E1","status":"pending","target_doc":"SOUL.md"}
        """)

        let result = try await wactor(t).rejectTrainingProposalLocal(proposalId: "P-E1", reason: "")
        // Returned shape carries the defaulted reason.
        #expect(wstr(wobj(result)["reason"]) == "No reason given")
        // Persisted rejection_reason is the default too.
        let parsed = wobj(try JSONValue.parse(Data(t.read(pdir.appendingPathComponent("p1.json"))!.utf8)))
        #expect(wstr(parsed["status"]) == "rejected")
        #expect(wstr(parsed["rejection_reason"]) == "No reason given")
    }

    @Test("reject: whitespace-only reason is NOT defaulted (Python truthy parity)")
    func rejectWhitespaceReasonNotDefaulted() async throws {
        // Python `bool("   ") == True`, so `"   " or "No reason given"` keeps
        // "   ". Only the empty string is falsy. Pin that exact boundary.
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        let pdir = try t.proposalsDir()
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-E2","status":"pending","target_doc":"SOUL.md"}
        """)
        let result = try await wactor(t).rejectTrainingProposalLocal(proposalId: "P-E2", reason: "   ")
        #expect(wstr(wobj(result)["reason"]) == "   ")
        let parsed = wobj(try JSONValue.parse(Data(t.read(pdir.appendingPathComponent("p1.json"))!.utf8)))
        #expect(wstr(parsed["rejection_reason"]) == "   ")
    }

    // MARK: approve — route_through_promotion staging

    @Test("approve: default policy stages a Swift promotion candidate")
    func approveDefaultRoutesToPromotion() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("SOUL.md"), "original soul\n")
        // No policy.json -> defaults apply -> route_through_promotion default TRUE.
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-3","status":"pending","target_doc":"SOUL.md","change_type":"append","proposed":"x","rationale":"stage it"}
        """)
        let result = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-3")
        let o = wobj(result)
        #expect(wstr(o["status"]) == "promotion_staged")
        let candidateId = try #require(wstr(o["candidate_id"]))
        #expect(candidateId == "training_P-3")
        #expect(t.read(mdir.appendingPathComponent("SOUL.md")) == "original soul\n")

        let proposal = wobj(try JSONValue.parse(Data(t.read(pdir.appendingPathComponent("p1.json"))!.utf8)))
        #expect(wstr(proposal["status"]) == "promotion_staged")
        #expect(wstr(proposal["promotion_candidate_id"]) == candidateId)

        let candidatePath = t.root
            .appendingPathComponent("training_journal/promotion_candidates", isDirectory: true)
            .appendingPathComponent("\(candidateId).json")
        let candidate = wobj(try JSONValue.parse(Data(t.read(candidatePath)!.utf8)))
        #expect(wstr(candidate["decision"]) == "STAGE_FOR_HUMAN")
        #expect(wstr(candidate["source"]) == "training_b1")

        let stagePath = t.root
            .appendingPathComponent("training_journal/promotion_stages", isDirectory: true)
            .appendingPathComponent("\(candidateId).json")
        let stage = wobj(try JSONValue.parse(Data(t.read(stagePath)!.utf8)))
        #expect(wstr(stage["status"]) == "pending")
    }

    @Test("approve: explicit route_through_promotion:true stages instead of applying doc")
    func approveExplicitRouteTrue() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("""
        {"trainingPolicy":{"autonomous_training":true,"route_through_promotion":true}}
        """)
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("SOUL.md"), "original")
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-4","status":"pending","target_doc":"SOUL.md","change_type":"append","proposed":"x"}
        """)
        let result = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-4")
        #expect(wstr(wobj(result)["status"]) == "promotion_staged")
        #expect(t.read(mdir.appendingPathComponent("SOUL.md")) == "original")
    }

    @Test("promotion stage approve applies staged patch and resolves proposal")
    func promotionStageApproveAppliesPatch() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("VOICE.md"), "voice body\n")
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-STAGE","status":"pending","target_doc":"VOICE.md","change_type":"append","proposed":"new rule","rationale":"ok"}
        """)
        let actor = wactor(t)
        let staged = try await actor.approveTrainingProposalLocal(proposalId: "P-STAGE")
        let candidateId = try #require(wstr(wobj(staged)["candidate_id"]))

        let approved = try await actor.approvePromotionStageLocal(candidateId: candidateId)
        #expect(wstr(wobj(approved)["status"]) == "approved")
        #expect(t.read(mdir.appendingPathComponent("VOICE.md")) == "voice body\n\nnew rule\n")
        #expect(t.read(mdir.appendingPathComponent("VOICE.backup-\(candidateId).md")) == "voice body\n")

        let proposal = wobj(try JSONValue.parse(Data(t.read(pdir.appendingPathComponent("p1.json"))!.utf8)))
        #expect(wstr(proposal["status"]) == "approved")
        #expect(wstr(proposal["approved_at"]) != nil)

        let stagePath = t.root
            .appendingPathComponent("training_journal/promotion_stages", isDirectory: true)
            .appendingPathComponent("\(candidateId).json")
        let stage = wobj(try JSONValue.parse(Data(t.read(stagePath)!.utf8)))
        #expect(wstr(stage["status"]) == "approved")
    }

    @Test("promotion stage reject resolves proposal without touching doc")
    func promotionStageRejectResolvesProposal() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("GROWTH.md"), "growth body\n")
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-REJECT","status":"pending","target_doc":"GROWTH.md","change_type":"append","proposed":"bad rule"}
        """)
        let actor = wactor(t)
        let staged = try await actor.approveTrainingProposalLocal(proposalId: "P-REJECT")
        let candidateId = try #require(wstr(wobj(staged)["candidate_id"]))

        let rejected = try await actor.rejectPromotionStageLocal(candidateId: candidateId, reason: "not right")
        #expect(wstr(wobj(rejected)["status"]) == "rejected")
        #expect(t.read(mdir.appendingPathComponent("GROWTH.md")) == "growth body\n")

        let proposal = wobj(try JSONValue.parse(Data(t.read(pdir.appendingPathComponent("p1.json"))!.utf8)))
        #expect(wstr(proposal["status"]) == "rejected")
        #expect(wstr(proposal["rejection_reason"]) == "not right")
    }

    // MARK: approve — direct mode happy paths

    @Test("approve direct: append applies, backs up, sets approved, writes ledger")
    func approveAppend() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("VOICE.md"), "Existing voice line.\n")
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-5","status":"pending","target_doc":"VOICE.md","change_type":"append","proposed":"New cadence rule.","rationale":"why"}
        """)

        let result = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-5")
        // Return shape: {"status":"approved","backup":...,ts,proposal_id,target_doc,before_hash,after_hash,rationale,approved_by}
        #expect(wstr(wobj(result)["status"]) == "approved")
        #expect(wstr(wobj(result)["approved_by"]) == "user")
        #expect(wstr(wobj(result)["target_doc"]) == "VOICE.md")
        #expect(wstr(wobj(result)["proposal_id"]) == "P-5")
        #expect(wstr(wobj(result)["rationale"]) == "why")

        // Doc: rstrip + "\n\n" + proposed + "\n".
        let after = try #require(t.read(mdir.appendingPathComponent("VOICE.md")))
        #expect(after == "Existing voice line.\n\nNew cadence rule.\n")

        // Backup created with original content (named <doc>.backup-<id>.md).
        let backup = mdir.appendingPathComponent("VOICE.backup-P-5.md")
        #expect(t.read(backup) == "Existing voice line.\n")

        // Proposal flipped to approved with approved_at.
        let parsed = wobj(try JSONValue.parse(Data(t.read(pdir.appendingPathComponent("p1.json"))!.utf8)))
        #expect(wstr(parsed["status"]) == "approved")
        #expect(wstr(parsed["approved_at"]) != nil)

        // Ledger appended (one line).
        let ledger = try #require(t.read(t.ledgerPath()))
        let lines = ledger.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        let entry = wobj(try JSONValue.parse(Data(lines[0].utf8)))
        #expect(wstr(entry["proposal_id"]) == "P-5")
        #expect(wstr(entry["approved_by"]) == "user")
        #expect(wstr(entry["target_doc"]) == "VOICE.md")
        // before/after hashes are 64-hex sha256 digests.
        #expect(wstr(entry["before_hash"])?.count == 64)
        #expect(wstr(entry["after_hash"])?.count == 64)
    }

    @Test("approve direct: edit replaces FIRST occurrence only")
    func approveEditFirstOnly() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("GROWTH.md"), "foo bar foo")
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-6","status":"pending","target_doc":"GROWTH.md","change_type":"edit","current":"foo","proposed":"BAZ"}
        """)
        _ = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-6")
        #expect(t.read(mdir.appendingPathComponent("GROWTH.md")) == "BAZ bar foo")
    }

    // MARK: approve — direct-mode failure paths

    @Test("approve direct: non-pending throws .notPending, leaves doc untouched")
    func approveNotPending() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("SOUL.md"), "original")
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-7","status":"approved","target_doc":"SOUL.md","change_type":"append","proposed":"x"}
        """)
        await #expect(throws: SwiftNativeSelfImprovement.TrainingProposalWriteError.notPending(id: "P-7", status: "approved")) {
            _ = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-7")
        }
        #expect(t.read(mdir.appendingPathComponent("SOUL.md")) == "original")
    }

    @Test("approve direct: disallowed target_doc throws .targetDocNotAllowed")
    func approveBadDoc() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        _ = try t.memoryDir()
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-8","status":"pending","target_doc":"SECRETS.md","change_type":"append","proposed":"x"}
        """)
        await #expect(throws: SwiftNativeSelfImprovement.TrainingProposalWriteError.targetDocNotAllowed("SECRETS.md")) {
            _ = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-8")
        }
    }

    @Test("approve direct: USER.md is not a training-promotion target")
    func approveUserDocRejected() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("USER.md"), "generated projection")
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-USER","status":"pending","target_doc":"USER.md","change_type":"append","proposed":"x"}
        """)
        await #expect(throws: SwiftNativeSelfImprovement.TrainingProposalWriteError.targetDocNotAllowed("USER.md")) {
            _ = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-USER")
        }
        #expect(t.read(mdir.appendingPathComponent("USER.md")) == "generated projection")
    }

    @Test("approve direct: missing doc file throws .targetDocMissing")
    func approveMissingDoc() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        _ = try t.memoryDir()   // exists, but GROWTH.md inside it does not
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-9","status":"pending","target_doc":"GROWTH.md","change_type":"append","proposed":"x"}
        """)
        await #expect(throws: SwiftNativeSelfImprovement.TrainingProposalWriteError.targetDocMissing("GROWTH.md")) {
            _ = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-9")
        }
    }

    @Test("approve direct: edit with current not in doc throws .cannotApplyChange")
    func approveEditMiss() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("AGENTS.md"), "nothing matches")
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-10","status":"pending","target_doc":"AGENTS.md","change_type":"edit","current":"absent","proposed":"x"}
        """)
        await #expect(throws: SwiftNativeSelfImprovement.TrainingProposalWriteError.cannotApplyChange(changeType: "edit")) {
            _ = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-10")
        }
        #expect(t.read(mdir.appendingPathComponent("AGENTS.md")) == "nothing matches")
    }

    @Test("approve direct: non-string change_type str()-coerces (NOT defaulted to append) -> .cannotApplyChange")
    func approveNonStringChangeType() async throws {
        // gpt-5.5 wave-33 finding: Python str(data.get("change_type","append"))
        // coerces a PRESENT non-string (e.g. null/0/false) to "None"/"0"/"False",
        // none of which equal "append"/"edit", so the daemon RAISES cannot_apply.
        // The Swift port must NOT silently treat a present non-string as "append".
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("SOUL.md"), "original soul")
        // change_type is JSON null (present, non-string) -> str(None)=="None".
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-11","status":"pending","target_doc":"SOUL.md","change_type":null,"proposed":"x"}
        """)
        await #expect(throws: SwiftNativeSelfImprovement.TrainingProposalWriteError.cannotApplyChange(changeType: "None")) {
            _ = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-11")
        }
        // Doc untouched.
        #expect(t.read(mdir.appendingPathComponent("SOUL.md")) == "original soul")
    }

    @Test("approve direct: absent change_type DOES default to append (key missing, not present)")
    func approveAbsentChangeTypeDefaultsAppend() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        try t.write(mdir.appendingPathComponent("GROWTH.md"), "line one\n")
        // No change_type key at all -> default "append" applies.
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-12","status":"pending","target_doc":"GROWTH.md","proposed":"appended line"}
        """)
        _ = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-12")
        #expect(t.read(mdir.appendingPathComponent("GROWTH.md")) == "line one\n\nappended line\n")
    }

    @Test("approve direct: unreadable doc would throw, not silently overwrite (BLOCKER fix shape)")
    func approveUnreadableDocDoesNotOverwrite() async throws {
        // We cannot easily simulate a UTF-8 decode failure portably, so this test
        // pins the BEHAVIORAL contract via an invalid-UTF-8 byte sequence written
        // raw. If the read fails, approve must THROW .targetDocUnreadable and leave
        // the (raw) doc bytes untouched — never overwrite with the proposed snippet.
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        // 0xFF 0xFE is not valid UTF-8.
        let badDoc = mdir.appendingPathComponent("GROWTH.md")
        try Data([0xFF, 0xFE, 0xFF]).write(to: badDoc)
        try t.write(pdir.appendingPathComponent("p1.json"), """
        {"proposal_id":"P-13","status":"pending","target_doc":"GROWTH.md","change_type":"append","proposed":"NEW"}
        """)
        await #expect(throws: SwiftNativeSelfImprovement.TrainingProposalWriteError.targetDocUnreadable("GROWTH.md")) {
            _ = try await wactor(t).approveTrainingProposalLocal(proposalId: "P-13")
        }
        // Raw doc bytes untouched (NOT overwritten with "...\n\nNEW\n").
        let rawBytes = try #require(try? Data(contentsOf: badDoc))
        #expect(Array(rawBytes) == [0xFF, 0xFE, 0xFF])
    }

    @Test("approve direct: not-found throws .proposalNotFound")
    func approveNotFound() async throws {
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        _ = try t.proposalsDir()
        await #expect(throws: SwiftNativeSelfImprovement.TrainingProposalWriteError.proposalNotFound("ghost")) {
            _ = try await wactor(t).approveTrainingProposalLocal(proposalId: "ghost")
        }
    }

    // MARK: approve — in-lock target_doc revalidation (wave-34 W04 race fix)

    @Test("approve direct: target_doc validated + applied from the IN-LOCK snapshot, not the pre-lock read")
    func approveRevalidatesTargetDocInLock() async throws {
        // wave-34 W04 fix: the wave-33 port validated target_doc / allow-list /
        // escape / file-exists PRE-LOCK off `found.data`, then applied the
        // freshData content INSIDE the lock. A concurrent rewrite of the
        // proposal's target_doc between the pre-lock read and lock-acquire would
        // have applied the fresh content to the STALE doc. The fix moves ALL
        // target_doc-derived checks inside the lock off freshData.
        //
        // We simulate the race with a persistence shim that flips the proposal's
        // target_doc on disk AFTER the pre-lock read but BEFORE the in-lock read,
        // then assert the WRITE landed on the NEW (in-lock) doc — and the ledger /
        // backup reference the new doc — not the stale pre-lock one.
        let t = try WriteTempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(directModePolicy)
        let pdir = try t.proposalsDir()
        let mdir = try t.memoryDir()
        // Two valid docs; the proposal initially names SOUL.md, then is flipped to
        // VOICE.md on disk between reads. Only VOICE.md should be appended to.
        try t.write(mdir.appendingPathComponent("SOUL.md"), "soul body\n")
        try t.write(mdir.appendingPathComponent("VOICE.md"), "voice body\n")
        let proposalFile = pdir.appendingPathComponent("p1.json")
        try t.write(proposalFile, """
        {"proposal_id":"P-RACE","status":"pending","target_doc":"SOUL.md","change_type":"append","proposed":"INJECTED"}
        """)

        let shim = RaceShim(
            proposalFile: proposalFile,
            rewriteAfterReadCount: 1,   // flip AFTER the pre-lock findProposalFile read
            rewrittenJSON: """
            {"proposal_id":"P-RACE","status":"pending","target_doc":"VOICE.md","change_type":"append","proposed":"INJECTED"}
            """
        )
        let actor = SwiftNativeSelfImprovement(persistence: shim, dataRoot: t.root)
        let result = try await actor.approveTrainingProposalLocal(proposalId: "P-RACE")

        // The in-lock snapshot named VOICE.md → VOICE.md is the doc that changed.
        #expect(t.read(mdir.appendingPathComponent("VOICE.md")) == "voice body\n\nINJECTED\n")
        // SOUL.md (the stale pre-lock target) is UNTOUCHED.
        #expect(t.read(mdir.appendingPathComponent("SOUL.md")) == "soul body\n")
        // Ledger + backup reference the in-lock doc, not the stale one.
        #expect(wstr(wobj(result)["target_doc"]) == "VOICE.md")
        #expect((wstr(wobj(result)["backup"]) ?? "").hasSuffix("VOICE.backup-P-RACE.md"))
    }
}

/// Test persistence shim: real on-disk IO, but rewrites the proposal file on disk
/// the moment its read-count for `proposalFile` reaches `rewriteAfterReadCount`,
/// simulating a concurrent daemon write landing between the approve's pre-lock
/// read and its in-lock re-read. Backed by the concrete SwiftNative IO for every
/// other path so the rest of the approve (backup/doc/ledger writes) behaves
/// normally. NOT a SwiftNativePersistenceCore subclass, so the actor's
/// withTrainingFileLock falls back to bare execution (no real flock) — fine here.
private final class RaceShim: PersistenceCoreProtocol, @unchecked Sendable {
    private let inner = SwiftNativePersistenceCore()
    private let proposalFile: URL
    private let rewriteAfterReadCount: Int
    private let rewrittenJSON: String
    private let proposalReads = OSAllocatedUnfairLock(initialState: 0)

    init(proposalFile: URL, rewriteAfterReadCount: Int, rewrittenJSON: String) {
        self.proposalFile = proposalFile
        self.rewriteAfterReadCount = rewriteAfterReadCount
        self.rewrittenJSON = rewrittenJSON
    }

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        let value = await inner.readJSON(path, defaultValue: defaultValue)
        if path.standardizedFileURL == proposalFile.standardizedFileURL {
            let shouldRewrite = proposalReads.withLock { count -> Bool in
                count += 1
                return count == rewriteAfterReadCount
            }
            if shouldRewrite {
                try? rewrittenJSON.write(to: proposalFile, atomically: true, encoding: .utf8)
            }
        }
        return value
    }

    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await inner.writeJSON(value, to: path)
    }
    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try await inner.appendJSONL(record, to: path)
    }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await inner.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }
    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await inner.readJSONL(path)
    }
}
