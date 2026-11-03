import CognitiveSubstrate
import Foundation
import Experiences
import PersistenceCore
import NativeAgentShared

// Blueprint: | `CaringReceiptLog.swift` | `CaringReceiptLog`: runtime-root-bound checked interpretation receipts and serialized dosing amendments; failed serialization, reads, framing, matches or publication retain receipt-only repair debt at that root without replaying effects |

/// One actor records typed interpretations and serializes their dosing amendments.
actor CaringReceiptLog {
    private let dataRoot: URL

    init(dataRoot: URL) { self.dataRoot = dataRoot }

    /// Record one metadata/verdict receipt per appraisal, never the message text.
    func record(
        _ request: CaringAppraisalRequest, model: String?, surface: String,
        verdict: CaringAppraisalVerdict?
    ) {
        var row: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
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
            let data = try JSONSerialization.data(withJSONObject: row)
            try append(String(decoding: data, as: UTF8.self))
        } catch { retainFailure(error, session: receiptSessionKey(request.session), turn: request.turn) }
    }

    /// The session key the receipt carries. The row stores a prefix, so the sink
    /// has to shorten its own session id the same way to find its line.
    private func receiptSessionKey(_ session: String) -> String {
        String(session.prefix(8))
    }

    private var url: URL {
        dataRoot
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("caring_appraisals.jsonl")
    }

    /// Amend the existing appraisal receipt with the body's dosing, coalescing or refusal.
    func amendReceipt(
        session: String,
        turn: String,
        outcome: OrganismCaringEventOutcome,
        tendernessAfter: Double
    ) {
        amend(
            session: receiptSessionKey(session),
            turn: turn,
            dosing: Dosing(
                label: dosingLabel(outcome),
                why: dosingRefusal(outcome),
                tendernessAfter: tendernessAfter
            )
        )
    }

    /// Amend the receipt when the substrate refuses a verdict before the body's sink.
    func amendReceiptRefused(
        session: String,
        turn: String,
        why: String,
        tendernessAfter: Double
    ) {
        amend(
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

    /// Retain the newest 2,000 lines only after the log exceeds 1,000,000 bytes.
    private func append(_ line: String) throws {
        try SwiftNativePersistenceCore.appendLines(Data((line + "\n").utf8), to: url)
        try enforceJSONLRetention(at: url, maxLines: 2000, trimWhenBytesExceed: 1_000_001)
    }

    private func retainFailure(_ error: Error, session: String, turn: String) {
        RepairOwed.owe(dataRoot, id: "caring-receipt:" + session + ":" + turn,
            kind: .run, operation: "cognition.caring.receipt:" + session + ":" + turn,
            owner: url.path,
            words: "The caring receipt is not settled: " + error.localizedDescription,
            tap: "Repair cognition/caring_appraisals.jsonl while preserving its bytes; settle the receipt only, without repeating the feeling or dose.")
    }

    /// Find the last row for this session+turn that has no dosing yet, put the
    /// outcome on it, and leave every other byte alone. A row that cannot be
    /// found (log rotated, receipt write failed) remains an explicit repair
    /// obligation; no orphan line invents an appraisal that was not recorded.
    private func amend(session: String, turn: String, dosing: Dosing) {
        do { try amendChecked(session: session, turn: turn, dosing: dosing) }
        catch { retainFailure(error, session: session, turn: turn) }
    }

    private func amendChecked(session: String, turn: String, dosing: Dosing) throws {
        let url = self.url
        let blob = try Data(contentsOf: url)
        guard let text = String(data: blob, encoding: .utf8) else {
            throw PersistenceCoreError.ioFailure("Caring receipts are not valid UTF-8.")
        }
        // Keep the exact byte layout: split on newlines, remember the trailing
        // one, and only the matched line changes.
        var lines = text.components(separatedBy: "\n")
        let endedWithNewline = lines.last?.isEmpty ?? false
        if endedWithNewline { lines.removeLast() }
        var match: (Int, [String: Any])?
        for index in lines.indices.reversed() {
            guard let row = try JSONSerialization.jsonObject(with: Data(lines[index].utf8)) as? [String: Any] else {
                throw PersistenceCoreError.ioFailure("Caring receipt row " + String(index + 1) + " is not an object.")
            }
            guard row["session"] as? String == session, row["turn"] as? String == turn,
                  row["dosing"] == nil else { continue }
            match = (index, row)
            break
        }
        guard let (index, object) = match else {
            throw PersistenceCoreError.ioFailure("The undosed caring receipt for " + session + ":" + turn + " was not found; preserve the log and reconcile the missing settlement.")
        }
        var row = object
        row["dosing"] = dosing.label
        if let why = dosing.why { row["dosingWhy"] = why }
        row["tendernessAfter"] = dosing.tendernessAfter
        let amended = try JSONSerialization.data(withJSONObject: row)
        lines[index] = String(decoding: amended, as: UTF8.self)
        var out = lines.joined(separator: "\n")
        if endedWithNewline { out += "\n" }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(out.utf8), to: url)
    }
}
