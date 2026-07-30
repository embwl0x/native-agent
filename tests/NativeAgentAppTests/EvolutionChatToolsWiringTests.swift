// Evolution chat tools — app-target wiring tests (U2b, 2026-06-11; the L6
// bridge-deny layer was removed 2026-06-13 when the user opened the claude/codex
// bridges, so the self-evolution tools are now REACHABLE from the bridge).
//
// That makes the APP + L5 gates below the load-bearing ones: even reachable
// from an open, human-out-of-the-loop bridge, self_install only ever STAGES an
// approval card the user resolves — it never installs on its own. These are exactly
// the proofs behind the user's "I'm still the final call on self-evolution."
//
//   APP — EvolutionToolBridgeImpl.evolutionStageInstall on a REAL
//        candidate_green proposal STAGES a self_evolution.apply approval card
//        and ONLY stages: it never writes pending_verify, never installs, and
//        leaves the proposal at `staged` (not installed).
//   L5 — the shipped TrustCenter defaults and load-time backfill carry explicit
//        `confirm` entries for all three (an ABSENT key could otherwise fall
//        through to default:auto and auto-fire). This must be provable from a
//        clean source checkout without reading a developer's private live data.
import Foundation
import Testing
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
import SelfImprovement
import TrustCenter
@testable import NativeAgentApp

@Suite("EvolutionChatToolsWiring")
struct EvolutionChatToolsWiringTests {

    // MARK: - APP: self_install stages a card, never installs

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvolutionChatToolsWiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func selfInstall_onCandidateGreen_stagesCard_neverInstalls() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Seed a real candidate_green proposal (diff + candidate run attached).
        let store = EvolutionProposalStore(dataRoot: root)
        let runId = "run-chat-install"
        let p = try await store.propose(
            source: .chat, title: "chat-staged change", evidence: "synthetic evidence",
            diffText: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", expectedHead: "headsha123456")
        _ = try await store.transition(id: p.id, to: .building, candidateRunId: runId)
        _ = try await store.transition(id: p.id, to: .candidateGreen)

        let bridge = EvolutionToolBridgeImpl(dataRoot: root)
        let result = try await bridge.evolutionStageInstall(input: ["proposal_id": .string(p.id)])

        guard case .object(let obj) = result else {
            Issue.record("self_install did not return object"); return
        }
        #expect(obj["status"] == .string("staged"))
        // Card exists in the approval inbox under the self_evolution.apply action.
        let inbox = SwiftNativeApprovalInbox(root: root)
        let pending = try await inbox.list(
            filter: ApprovalFilter(status: "pending", action: NativeClient.selfEvolutionAction))
        #expect(pending.count == 1)
        let card = try #require(pending.first)
        #expect(card.risk == "critical")
        #expect(obj["approval_id"] == .string(card.id))
        #expect(obj["approval_status"] == .string("pending"))

        // THE RAIL: only staged. Proposal advanced to staged (NOT installed),
        // no pending_verify written, no rollback bundle — nothing installed.
        let after = try #require(try await store.get(id: p.id))
        #expect(after.status == .staged)
        let pendingVerify = root.appendingPathComponent("evolution", isDirectory: true)
            .appendingPathComponent("pending_verify.json")
        #expect(!FileManager.default.fileExists(atPath: pendingVerify.path))
        let rollbackDir = root.appendingPathComponent("evolution/rollback_bundle", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: rollbackDir.path))
    }

    @Test func selfInstall_stagedCard_isLocalOnly() async throws {
        // U4 Wave D (gpt-5.5 BLOCKER B1): a self_evolution.apply card COMMITS
        // code to the live repo on approval, so it must be local-only — a
        // remote/iCloud peer must never be able to approve one.
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvolutionProposalStore(dataRoot: root)
        let p = try await store.propose(
            source: .chat, title: "local-only check", evidence: "ev",
            diffText: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", expectedHead: "h")
        _ = try await store.transition(id: p.id, to: .building, candidateRunId: "run-lo")
        _ = try await store.transition(id: p.id, to: .candidateGreen)

        _ = try await EvolutionToolBridgeImpl(dataRoot: root)
            .evolutionStageInstall(input: ["proposal_id": .string(p.id)])

        let inbox = SwiftNativeApprovalInbox(root: root)
        let pending = try await inbox.list(
            filter: ApprovalFilter(status: "pending", action: NativeClient.selfEvolutionAction))
        let card = try #require(pending.first)
        #expect(card.localOnly == true)
        #expect(card.remoteResolvable == false)
    }

    @Test func selfInstall_stagesOnlyTheRequestedProposal() async throws {
        // U4 Wave D (gpt-5.5 SHOULD-FIX): two green candidates exist; installing
        // ONE must stage ONLY that proposal's card, not the other green one.
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvolutionProposalStore(dataRoot: root)
        func seedGreen(_ title: String, _ run: String) async throws -> String {
            let p = try await store.propose(
                source: .chat, title: title, evidence: "ev",
                diffText: "--- a/\(run)\n+++ b/\(run)\n@@ -1 +1 @@\n-a\n+b\n", expectedHead: "h")
            _ = try await store.transition(id: p.id, to: .building, candidateRunId: run)
            _ = try await store.transition(id: p.id, to: .candidateGreen)
            return p.id
        }
        let idA = try await seedGreen("A", "run-a")
        let idB = try await seedGreen("B", "run-b")

        _ = try await EvolutionToolBridgeImpl(dataRoot: root)
            .evolutionStageInstall(input: ["proposal_id": .string(idA)])

        let inbox = SwiftNativeApprovalInbox(root: root)
        let pending = try await inbox.list(
            filter: ApprovalFilter(status: "pending", action: NativeClient.selfEvolutionAction))
        let stagedProposalIds: [String] = pending.compactMap { rec in
            guard case .object(let p) = rec.payload, case .string(let pid)? = p["proposalId"] else { return nil }
            return pid
        }
        #expect(stagedProposalIds == [idA])
        #expect(!stagedProposalIds.contains(idB))
        // B stayed candidate_green (untouched); A advanced to staged.
        #expect(try await store.get(id: idB)?.status == .candidateGreen)
        #expect(try await store.get(id: idA)?.status == .staged)
    }

    @Test func selfInstall_onNonGreen_returnsHonestNotInstallable() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvolutionProposalStore(dataRoot: root)
        // Filed but only `proposed` (no diff-build → not candidate_green).
        let p = try await store.propose(
            source: .chat, title: "not yet green", evidence: "evidence",
            diffText: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", expectedHead: "head")

        let bridge = EvolutionToolBridgeImpl(dataRoot: root)
        let result = try await bridge.evolutionStageInstall(input: ["proposal_id": .string(p.id)])
        guard case .object(let obj) = result else {
            Issue.record("self_install did not return object"); return
        }
        #expect(obj["status"] == .string("not_installable"))
        #expect(obj["proposal_status"] == .string("proposed"))
        // No card staged for a non-green proposal.
        let inbox = SwiftNativeApprovalInbox(root: root)
        let pending = try await inbox.list(
            filter: ApprovalFilter(status: "pending", action: NativeClient.selfEvolutionAction))
        #expect(pending.isEmpty)
    }

    @Test func selfInstall_unknownProposal_returnsNotFound() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = EvolutionToolBridgeImpl(dataRoot: root)
        let result = try await bridge.evolutionStageInstall(input: ["proposal_id": .string("evo_missing")])
        guard case .object(let obj) = result else {
            Issue.record("self_install did not return object"); return
        }
        #expect(obj["status"] == .string("not_found"))
    }

    @Test func propose_and_status_roundTrip() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = EvolutionToolBridgeImpl(dataRoot: root)

        // propose without a diff → needs_diff.
        let proposeResult = try await bridge.evolutionPropose(input: [
            "title": .string("Improve X"),
            "evidence": .string("usage shows Y"),
        ])
        guard case .object(let pobj) = proposeResult,
              case .string(let id)? = pobj["id"] else {
            Issue.record("propose returned no id: \(proposeResult)"); return
        }
        #expect(pobj["proposal_status"] == .string("needs_diff"))

        // status by id returns the record.
        let oneResult = try await bridge.evolutionStatus(input: ["proposal_id": .string(id)])
        guard case .object(let oobj) = oneResult,
              case .object(let prop)? = oobj["proposal"] else {
            Issue.record("status-by-id malformed: \(oneResult)"); return
        }
        #expect(prop["id"] == .string(id))
        #expect(prop["status"] == .string("needs_diff"))
        #expect(prop["risk"] == .string("critical"))

        // status list includes the in-flight proposal.
        let listResult = try await bridge.evolutionStatus(input: [:])
        guard case .object(let lobj) = listResult,
              case .array(let proposals)? = lobj["proposals"] else {
            Issue.record("status-list malformed: \(listResult)"); return
        }
        let ids: [String] = proposals.compactMap {
            if case .object(let o) = $0, case .string(let pid)? = o["id"] { return pid }
            return nil
        }
        #expect(ids.contains(id))
    }

    // MARK: - L5 shipped-policy confirm entries

    @Test func shippedPolicyBackfillsConfirmEntriesForAllThree() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Reproduce an older saved policy whose broad default is permissive and
        // which predates the explicit self-evolution keys. The production loader
        // must backfill the shipped exact-match guards over that saved fallback.
        let trustDirectory = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: true)
        let savedPolicy = try JSONSerialization.data(withJSONObject: [
            "toolAutonomy": ["default": "auto"],
        ])
        try savedPolicy.write(to: trustDirectory.appendingPathComponent("policy.json"))

        let loaded = await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicy()
        guard case .object(let toolAutonomy)? = loaded["toolAutonomy"] else {
            Issue.record("loaded policy has no toolAutonomy object")
            return
        }
        #expect(toolAutonomy["evolution_propose"] == JSONValue.string("confirm"))
        #expect(toolAutonomy["evolution_status"] == JSONValue.string("confirm"))
        #expect(toolAutonomy["self_install"] == JSONValue.string("confirm"))
    }
}
