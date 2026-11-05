import CognitiveSubstrate
import Foundation
import Experiences
import PersistenceCore
import NativeAgentShared

// Blueprint: | `CaringReceiptLog.swift` | `CaringReceiptLog`. |

/// Record appraisal interpretations and the body's later response as immutable details of the same heard experience (the appraised turn's
/// `Turn.id`). The row's `turn` stays the cognitive subject (`session:message`) the substrate names it by.
actor CaringReceiptLog {
    private let dataRoot: URL

    init(dataRoot: URL) { self.dataRoot = dataRoot }

    /// Record verdict metadata, never message text. `heard` is the appraised turn's id; empty when the moment did not carry it.
    func record(
        _ request: CaringAppraisalRequest, heard: String, model: String?, surface: String,
        verdict: CaringAppraisalVerdict?
    ) async {
        let at = Date()
        var row: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: at),
            "turnAt": ISO8601DateFormatter().string(from: request.at),
            "session": receiptSessionKey(request.session),
            "turn": request.turn,
            "relayed": request.relayed,
            "surface": surface,
            "model": model ?? "",
        ]
        if let verdict {
            row["outcome"] = verdict.kind.map { $0.rawValue } ?? "none"
            row["why"] = verdict.why
            if request.relayed { row["distinctness"] = verdict.distinctness.rawValue }
        } else {
            row["outcome"] = "unparseable"
            row["rawPrefix"] = "{}"
        }
        do {
            try await store.note([ExperienceStore.Detail(source: "caring", at: at, subject: heard, kind: "caring.appraisal",
                                                        row: JSONSerialization.data(withJSONObject: row))])
        } catch { retainFailure(error, session: receiptSessionKey(request.session), turn: request.turn) }
    }

    /// Match the sink's shortened session ID to the receipt's stored prefix.
    private func receiptSessionKey(_ session: String) -> String {
        String(session.prefix(8))
    }

    private var store: ExperienceStore { ExperienceStore.at(dataRoot) }

    func amendReceipt(
        session: String,
        turn: String,
        outcome: OrganismCaringEventOutcome,
        tendernessAfter: Double
    ) async {
        await amend(
            session: receiptSessionKey(session),
            turn: turn,
            dosing: Dosing(
                label: dosingLabel(outcome),
                why: dosingRefusal(outcome),
                tendernessAfter: tendernessAfter
            )
        )
    }

    func amendReceiptRefused(
        session: String,
        turn: String,
        why: String,
        tendernessAfter: Double
    ) async {
        await amend(
            session: receiptSessionKey(session),
            turn: turn,
            dosing: Dosing(
                label: "refused", why: why, tendernessAfter: tendernessAfter
            )
        )
    }

    private func dosingLabel(_ outcome: OrganismCaringEventOutcome) -> String {
        switch outcome {
        case .dosed: return "dosed"
        case .coalesced: return "coalesced"
        case .refused, .forgotten: return "refused"
        }
    }

    private func dosingRefusal(_ outcome: OrganismCaringEventOutcome) -> String? {
        switch outcome {
        case .dosed: return nil
        case .coalesced:
            return "same encounter already dosed — one encounter, one dose"
        case .refused:
            return "the organism is disabled — nothing was dosed"
        case .forgotten:
            return "the body was reset after this moment — it was not dosed into the body that replaced it"
        }
    }

    private struct Dosing: Sendable {
        let label: String
        let why: String?
        let tendernessAfter: Double
    }

    private func retainFailure(_ error: Error, session: String, turn: String) {
        RepairOwed.owe(dataRoot, id: "caring-receipt:" + session + ":" + turn,
            kind: .run, operation: "cognition.caring.receipt:" + session + ":" + turn,
            owner: "experiences/experiences.sqlite",
            words: "The caring receipt is not settled: " + error.localizedDescription,
            tap: "Repair the caring details in the experience record; settle the receipt only, without repeating the feeling or dose.")
    }

    /// A dosing detail requires a recorded appraisal and is about the same heard experience, read from that appraisal; absence remains repair owed,
    /// and repeated settlement writes nothing.
    private func amend(session: String, turn: String, dosing: Dosing) async {
        do { try await amendChecked(session: session, turn: turn, dosing: dosing) }
        catch { retainFailure(error, session: session, turn: turn) }
    }

    private func amendChecked(session: String, turn: String, dosing: Dosing) async throws {
        let at = Date()
        var row: [String: Any] = ["session": session, "turn": turn, "dosing": dosing.label,
                                  "tendernessAfter": dosing.tendernessAfter]
        if let why = dosing.why { row["dosingWhy"] = why }
        func names(_ detail: ExperienceStore.Detail) throws -> Bool {
            guard let row = try JSONSerialization.jsonObject(with: detail.row) as? [String: Any] else {
                throw PersistenceCoreError.ioFailure("A caring detail in the experience record is not an object.")
            }
            return row["session"] as? String == session && row["turn"] as? String == turn
        }
        guard let appraisal = try await store.details(.init(kinds: ["caring.appraisal"], newestFirst: true)).first(where: names) else {
            throw PersistenceCoreError.ioFailure("The caring appraisal for " + session + ":" + turn
                + " was not found in the experience record; reconcile the missing receipt without repeating the feeling or dose.")
        }
        let detail = ExperienceStore.Detail(source: "caring", at: at, subject: appraisal.subject, kind: "caring.dosing",
                                            row: try JSONSerialization.data(withJSONObject: row))
        try await store.note(detail) { details in
            var appraised = false
            var dosed = false
            for detail in details where detail.kind == "caring.appraisal" || detail.kind == "caring.dosing" {
                guard let row = try JSONSerialization.jsonObject(with: detail.row) as? [String: Any] else {
                    throw PersistenceCoreError.ioFailure("A caring detail in the experience record is not an object.")
                }
                guard row["session"] as? String == session, row["turn"] as? String == turn else { continue }
                if detail.kind == "caring.appraisal" { appraised = true }
                if detail.kind == "caring.dosing" { dosed = true }
            }
            guard appraised else {
                throw PersistenceCoreError.ioFailure("The caring appraisal for " + session + ":" + turn
                    + " was not found in the experience record; reconcile the missing receipt without repeating the feeling or dose.")
            }
            return dosed
        }
    }
}
