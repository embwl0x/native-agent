import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Procedural skill proposals: the landing strip
//
// The skills-recall rework (2026-07-03) already built every piece of the road
// from an approved skill to craft arriving mid-conversation: body file →
// pointer sync (hygiene-gated, serialized) → recall surfaces it the same day.
// This file only puts the lane's proposal onto that road, through the SAME
// approval card REM proposals use.
//
// Two rules the plan states and this code enforces structurally:
//   * NO autonomous skill creation. Nothing here writes a body without a
//     resolved, approved card whose payload matches the procedure it names.
//   * The card shows HER draft verbatim (`payloadPreview` is the body, the
//     7beadffd lesson). The owner approves the words that will exist, not a
//     summary of them.
//
// Staging lives in MemoryV2 rather than in the ApprovalInbox module for the
// same reason the consolidation gate's card does (U3w2 item 7): the module
// that owns the evidence owns its card, and ApprovalInbox stays a store.

public enum ProceduralSkillProposalError: String, Error, Sendable, Equatable {
    case emptyDraftBody = "empty_draft_body"
    case bodyFailsHygiene = "body_fails_hygiene"
    case approvalNotApproved = "approval_not_approved"
    case approvalNotLocal = "approval_not_local"
    case approvalPayloadMismatch = "approval_payload_mismatch"
    case unsafeSkillName = "unsafe_skill_name"
}

/// What applying a resolved card did.
public enum ProceduralSkillApprovalOutcome: Sendable, Equatable {
    /// Approved: the body landed (or was already there, byte-identical) and
    /// the pointer sync ran.
    case applied(skillName: String, bodyPath: String, bodyWritten: Bool)
    /// Denied or canceled: no body, no pointer, nothing on disk.
    case declined(skillName: String)
}

public enum ProceduralSkillProposal {
    /// The card's action. Distinct from `rem.proposal` so the inbox, the
    /// executors, and the pending cap can all count this lane on its own.
    public static let approvalAction = "skill.proposal"
    public static let payloadSchema = "procedural-skill-proposal.v1"

    // MARK: Stage

    /// File ONE card for a compiled procedure.
    @discardableResult
    public static func stage(
        procedure: CompiledToolProcedure,
        inbox: SwiftNativeApprovalInbox
    ) async throws -> ApprovalRecord {
        let body = procedure.draftSkillBody()
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProceduralSkillProposalError.emptyDraftBody
        }
        // A body that fails hygiene gets no recall pointer, so approving it
        // would promise craft that never arrives. Refuse at stage time, where
        // the failure is still cheap and loud.
        guard SkillBodyHygiene.violations(in: body).isEmpty else {
            throw ProceduralSkillProposalError.bodyFailsHygiene
        }
        guard isSafeSkillName(procedure.suggestedSkillName) else {
            throw ProceduralSkillProposalError.unsafeSkillName
        }
        let actions = procedure.steps.map(\.action).joined(separator: " → ")
        return try await inbox.create(.object([
            "title": .string("Keep this as a skill: \(actions)"),
            "action": .string(approvalAction),
            "risk": .string("low"),
            "reason": .string(
                "This exact sequence ran \(procedure.occurrenceCount) times across "
                + "\(procedure.distinctDayCount) days, verified successful every time. "
                + "Approve to save the draft below as a skill body — she will find it "
                + "through recall when a conversation enters its territory. It grants no "
                + "permission, activates nothing, and runs nothing on its own. "
                + "Deny and nothing is written."
            ),
            "remoteResolvable": .bool(false),
            "localOnly": .bool(true),
            // Her words, verbatim, and only her words (7beadffd).
            "payloadPreview": .string(body),
            "payload": binding(procedure: procedure, body: body),
        ]))
    }

    /// True when a card for this SEQUENCE SHAPE already exists in any status —
    /// the dedupe the lane checks before staging.
    ///
    /// Keyed on `sequenceIdentity`, never on `procedureId`: the latter's digest
    /// folds in the occurrence count and the observed days, so the same
    /// sequence seen once more, or on a new day, compiles to a different
    /// `procedureId` and would match nothing (review finding, 2026-09-01).
    public static func isAlreadyFiled(
        sequenceIdentity: String,
        inbox: SwiftNativeApprovalInbox
    ) async -> Bool {
        guard !sequenceIdentity.isEmpty, let records = try? await inbox.list(
            filter: ApprovalFilter(status: nil, action: approvalAction)
        ) else { return false }
        return records.contains { self.sequenceIdentity(of: $0) == sequenceIdentity }
    }

    static func binding(procedure: CompiledToolProcedure, body: String) -> JSONValue {
        .object([
            "schema": .string(payloadSchema),
            "kind": .string("skill.proposal"),
            "purpose": .string("save_repeated_verified_sequence_as_skill_body"),
            "skillName": .string(procedure.suggestedSkillName),
            "procedureId": .string(procedure.id),
            "sequenceIdentity": .string(procedure.sequenceIdentity),
            "draftBody": .string(body),
            "occurrenceCount": .int(Int64(procedure.occurrenceCount)),
            "distinctDayCount": .int(Int64(procedure.distinctDayCount)),
            "procedure": procedure.jsonValue,
            "automaticActivation": .bool(false),
            "permissionAuthority": .bool(false),
            "externalSendsEligible": .bool(false),
            "generatedExecutableCode": .bool(false),
        ])
    }

    /// The card's dedupe key. Deliberately the only reader of the payload for
    /// this purpose — `procedureId` is a receipt of the evidence aggregate, not
    /// an identity, and reading it here is what let the same sequence re-mint.
    static func sequenceIdentity(of record: ApprovalRecord) -> String? {
        guard case .object(let payload) = record.payload,
              payload["schema"] == .string(payloadSchema),
              case .string(let identity)? = payload["sequenceIdentity"],
              !identity.isEmpty else { return nil }
        return identity
    }

    // MARK: Apply

    /// Apply a RESOLVED card. Approved → the draft body lands under
    /// `<dataRoot>/skills/bodies/` (the RUNTIME shelf; `persona/skills/bodies`
    /// stays the curated one, per the plan's non-goals) and the caller fires
    /// the pointer sync. Denied/canceled → nothing is written.
    ///
    /// Idempotent by the REMGrowthWriter contract: a byte-identical body
    /// already on disk is a no-op that still reports success, so a crash-
    /// window reconcile cannot double-write or fail a second time.
    public static func applyResolved(
        record: ApprovalRecord,
        dataRoot: URL,
        persistence: (any PersistenceCoreProtocol)? = nil
    ) async throws -> ProceduralSkillApprovalOutcome {
        guard record.action == approvalAction, record.status == "resolved",
              let decision = record.decision else {
            throw ProceduralSkillProposalError.approvalNotApproved
        }
        guard case .object(let payload) = record.payload,
              payload["schema"] == .string(payloadSchema),
              case .string(let skillName)? = payload["skillName"],
              case .string(let body)? = payload["draftBody"],
              case .string(let procedureID)? = payload["procedureId"],
              !procedureID.isEmpty else {
            throw ProceduralSkillProposalError.approvalPayloadMismatch
        }
        guard isSafeSkillName(skillName) else {
            throw ProceduralSkillProposalError.unsafeSkillName
        }
        guard decision == ApprovalDecision.approved.rawValue else {
            return .declined(skillName: skillName)
        }
        guard record.localOnly, !record.remoteResolvable else {
            throw ProceduralSkillProposalError.approvalNotLocal
        }
        // The card's own preview is the contract. If the stored preview and
        // the stored body ever disagree, the owner approved something other
        // than what would be written — refuse rather than pick one.
        guard record.payloadPreview == body else {
            throw ProceduralSkillProposalError.approvalPayloadMismatch
        }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProceduralSkillProposalError.emptyDraftBody }
        guard SkillBodyHygiene.violations(in: body).isEmpty else {
            throw ProceduralSkillProposalError.bodyFailsHygiene
        }

        let bodiesDir = dataRoot
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("bodies", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bodiesDir, withIntermediateDirectories: true
        )
        let target = bodiesDir.appendingPathComponent("\(skillName).md")
        let core = persistence ?? SwiftNativePersistenceCore()
        let written = try await core.withFileLock(target) {
            let existing = try? String(contentsOf: target, encoding: .utf8)
            if existing == body { return false }
            guard let data = body.data(using: .utf8) else {
                throw ProceduralSkillProposalError.emptyDraftBody
            }
            try data.write(to: target, options: .atomic)
            return true
        }
        return .applied(
            skillName: skillName, bodyPath: target.path, bodyWritten: written
        )
    }

    /// The skill name reaches a file path, so it never gets to be arbitrary:
    /// lowercase alphanumerics and hyphens only, no separators, no dots.
    public static func isSafeSkillName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 96
            && name.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" }
            && !name.hasPrefix("-") && !name.hasSuffix("-")
    }
}
