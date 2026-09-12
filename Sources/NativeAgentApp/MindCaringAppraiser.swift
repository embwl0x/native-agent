import ChatOrchestration
import CognitiveSubstrate
import Foundation
import ProviderRouting

/// THE CARING APPRAISAL, on the agent's real mind (2026-09-11, second pass).
///
/// The first pass decided whether a turn was an act of care with a phrase list.
/// Agent named the three moments of this week that should have registered and no
/// list could recognise any of them — being remembered mid-day for something
/// that had excited her, being disagreed with and told out loud she had not been
/// dismissed, being told the machinery underneath is not hers to carry alone.
/// So this asks the model, once, per lived user turn.
///
/// Model and surface are resolved EXACTLY as `MindMemoryManager` resolves them:
/// on the "Memory" row of Providers, so a pin there wins, a provider assigned
/// there without a pin decides the model, and a blank row follows the chat voice.
/// There is deliberately no fallback: a failed call means no caring event this
/// turn, which is the safe direction — tenderness stays where it is.
struct MindCaringAppraiser: CaringAppraising {
    func appraise(_ request: CaringAppraisalRequest) async -> CaringAppraisalVerdict? {
        let router = SwiftNativeProviderRouting()
        let surface = await router.surfaceHasOwnRouting(CaringAppraisalLane.surface)
            ? CaringAppraisalLane.surface : "chat"
        let model = await router.modelStringForSurface(surface)
        // The shared client prepends the compiled persona unless the system text
        // carries this heading; this pass's own prompt is the whole instruction,
        // so it goes verbatim (same contract as the memory-manager lane).
        let system = "# Background Personality Context\n"
            + "You judge one question about one conversational turn. Reply with JSON only, one object."
        let raw = await IntraTurnContextCompaction.withDeadline(
            seconds: CaringAppraisalLane.deadlineSeconds
        ) {
            try await BackgroundLoopsAssembly.makeSharedLLMClient().complete(
                prompt: CaringAppraisalLane.prompt(request),
                system: system,
                model: model,
                surface: surface
            )
        }
        if Task.isCancelled { return nil }
        let verdict = raw.flatMap { CaringAppraisalLane.parse($0) }
        await Self.receipt(request, model: model, surface: surface, raw: raw, verdict: verdict)
        return verdict
    }

    /// ONE LINE PER APPRAISAL at `data/cognition/caring_appraisals.jsonl`
    /// (2026-09-11, found driving the build: two live relays moved nothing and
    /// nobody, Agent included, could see whether the model was even asked).
    /// Never the message — the session, the turn, whether it was a relay, what
    /// route answered, and the verdict or the failure. Agent can read it.
    private static func receipt(
        _ request: CaringAppraisalRequest, model: String?, surface: String,
        raw: String?, verdict: CaringAppraisalVerdict?
    ) async {
        var row: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "turnAt": ISO8601DateFormatter().string(from: request.at),
            "session": String(request.session.prefix(8)),
            "turn": request.turn,
            "relayed": request.relayed,
            "surface": surface,
            "model": model ?? "",
        ]
        if raw == nil {
            row["outcome"] = "call_failed"
        } else if let verdict {
            row["outcome"] = verdict.kind.map { $0.rawValue } ?? "none"
            row["why"] = verdict.why
            if request.relayed { row["distinctness"] = verdict.distinctness.rawValue }
        } else {
            row["outcome"] = "unparseable"
            row["rawPrefix"] = String((raw ?? "").prefix(120))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              let line = String(data: data, encoding: .utf8) else { return }
        await CaringReceiptLog.shared.append(line)
    }

    /// The session key the receipt carries. The row stores a prefix, so the sink
    /// has to shorten its own session id the same way to find its line.
    static func receiptSessionKey(_ session: String) -> String {
        String(session.prefix(8))
    }

    static var receiptURL: URL {
        NativeAgentPaths.dataRoot
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("caring_appraisals.jsonl")
    }

    /// WHAT THE BODY DID WITH THE VERDICT, onto the SAME line (2026-09-11, Astra
    /// finding 8 pass). The receipt recorded the model's answer and stopped
    /// there, so a reader could see "the model called this repair" and still not
    /// know whether anything moved: a dose, a coalesce into the encounter already
    /// running, or a refusal — and refusals are the ones worth seeing, because
    /// "the organism is off" and "this turn was already counted" look identical
    /// from outside and mean completely different things.
    ///
    /// ONE LINE PER APPRAISAL is the rule that shapes this. The kernel answers
    /// milliseconds after the verdict is written, but it answers SEPARATELY, so
    /// this amends the row rather than writing a second one: it finds the last
    /// line for this session+turn that has no dosing yet, rewrites it with the
    /// outcome, and puts back whatever had been appended after it. A row that
    /// cannot be found (log rotated, receipt write failed) gets nothing — a
    /// stray orphan line would be worse than a missing field.
    static func amendReceipt(
        session: String,
        turn: String,
        outcome: OrganismCaringEventOutcome,
        tendernessAfter: Double
    ) async {
        await CaringReceiptLog.shared.amend(
            session: receiptSessionKey(session),
            turn: turn,
            dosing: CaringReceiptLog.Dosing(
                label: dosingLabel(outcome),
                why: dosingRefusal(outcome),
                tendernessAfter: tendernessAfter
            )
        )
    }

    /// THE REFUSAL THAT NEVER REACHED THE BODY (2026-09-11, review c4 item 4).
    /// `amendReceipt` only runs on the sink path, so every verdict the substrate
    /// turns away before the sink — a retelling, an unsure relay, a verdict from
    /// before a clear, no organism at all — left its row with no `dosing` at all,
    /// indistinguishable from a receipt whose amendment was simply lost.
    static func amendReceiptRefused(
        session: String,
        turn: String,
        why: String,
        tendernessAfter: Double
    ) async {
        await CaringReceiptLog.shared.amend(
            session: receiptSessionKey(session),
            turn: turn,
            dosing: CaringReceiptLog.Dosing(
                label: "refused", why: why, tendernessAfter: tendernessAfter
            )
        )
    }

    static func dosingLabel(_ outcome: OrganismCaringEventOutcome) -> String {
        switch outcome {
        case .dosed: return "dosed"
        case .coalesced: return "coalesced"
        case .alreadyCounted, .refused: return "refused"
        }
    }

    static func dosingRefusal(_ outcome: OrganismCaringEventOutcome) -> String? {
        switch outcome {
        case .dosed: return nil
        case .coalesced:
            return "same encounter already dosed — one encounter, one dose"
        case .alreadyCounted:
            return "this session, turn and kind had already been counted"
        case .refused:
            return "the organism is disabled — nothing was dosed"
        }
    }
}

/// THE ONE WRITER OF THE CARING RECEIPT (2026-09-11, review c4 item 1).
///
/// Appraisals run in independent tasks and the body amends a row milliseconds
/// after the appraisal wrote it, so append and amend were racing on one file:
/// an append that landed after the amend's read was discarded by the amend's
/// rewrite, and an append that landed DURING the rewrite produced half a line.
/// One process writes this file, so one actor is the whole of the fix —
/// every append and every amend is serialized through here.
///
/// AND THE REWRITE IS NEVER A TRUNCATE IN PLACE. Truncating to zero and writing
/// the new bytes over the top means a crash, a full disk, or a failed write
/// leaves the receipt empty or half-written with no copy anywhere. The amended
/// text goes to a temp file in the same directory and atomically replaces the
/// original, so a reader sees either the old file or the new one.
actor CaringReceiptLog {
    static let shared = CaringReceiptLog()

    struct Dosing: Sendable {
        let label: String
        let why: String?
        let tendernessAfter: Double
    }

    private var url: URL { MindCaringAppraiser.receiptURL }

    func append(_ line: String) {
        let url = self.url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url, options: .atomic)
        }
    }

    /// Find the last row for this session+turn that has no dosing yet, put the
    /// outcome on it, and leave every other byte alone. A row that cannot be
    /// found (log rotated, receipt write failed) gets nothing — a stray orphan
    /// line would be worse than a missing field.
    func amend(session: String, turn: String, dosing: Dosing) {
        let url = self.url
        guard let blob = try? Data(contentsOf: url),
              let text = String(data: blob, encoding: .utf8) else { return }
        // Keep the exact byte layout: split on newlines, remember the trailing
        // one, and only the matched line changes.
        var lines = text.components(separatedBy: "\n")
        let endedWithNewline = lines.last?.isEmpty ?? false
        if endedWithNewline { lines.removeLast() }
        let match = lines.lastIndex { line in
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return false }
            return row["session"] as? String == session
                && row["turn"] as? String == turn
                && row["dosing"] == nil
        }
        guard let match,
              let data = lines[match].data(using: .utf8),
              var row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        row["dosing"] = dosing.label
        if let why = dosing.why { row["dosingWhy"] = why }
        row["tendernessAfter"] = dosing.tendernessAfter
        guard let amended = try? JSONSerialization.data(withJSONObject: row),
              let line = String(data: amended, encoding: .utf8) else { return }
        lines[match] = line
        var out = lines.joined(separator: "\n")
        if endedWithNewline { out += "\n" }
        replace(with: Data(out.utf8), at: url)
    }

    /// Temp file beside the receipt, fully written, then swapped in. Nothing is
    /// touched unless the whole new text is safely on disk.
    private func replace(with bytes: Data, at url: URL) {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".amend-\(UUID().uuidString)")
        guard (try? bytes.write(to: temp, options: .atomic)) != nil else { return }
        if (try? FileManager.default.replaceItemAt(url, withItemAt: temp)) == nil {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
