import Foundation
import NativeAgentCore
import PersistenceCore
import CognitiveSubstrate
import NativeAgentShared

// Blueprint: | `AfterTurnSurpriseLedger.swift` | `AfterTurnSurpriseLedger`, `Expectation`: labelled predictions and measured cost standing |

public struct AfterTurnSurpriseObservation: Sendable, Equatable {
    public let check: AfterTurnMemorySurprise
    public let agreement: AfterTurnSurpriseAgreement
    public var deferred = false
}

public struct AfterTurnSurpriseAgreement: Sendable, Equatable {
    public let turns: Int
    public let wouldDefer: Int
    /// A change in any interpretation channel contradicts a complete-no-op prediction.
    public let changedOnPrediction: Int
    public let incompletePredictions: Int
    public let ledgerReadable: Bool
}

/// What one judgment measured in each channel; retained judgments may be incomplete.
public struct AfterTurnChannelOutcome: Codable, Sendable, Equatable {
    public let facts: Bool
    public let affect: Bool
    public let caring: Bool
    public let cares: Bool
    /// New promises or person-quoted settlements; nil when a retained judgment never measured promises.
    public let promises: Bool?
    /// All five channels were measured, with facts asked and readable.
    public let complete: Bool
    public var nothingNew: Bool { complete && !facts && !affect && !caring && !cares && promises == false }

    /// Any memory, affect, caring, care, promise or settlement change makes the complete judgment nonempty.
    public init(interpretation: AfterTurnInterpretation, factsAsked: Bool) {
        facts = interpretation.memories.contains { $0.action != .skip }
        affect = !interpretation.affect.isNoOp
        caring = interpretation.caring.kind != nil
        cares = !interpretation.cares.isEmpty
        promises = !interpretation.promises.isEmpty || !interpretation.settled.isEmpty
        complete = factsAsked
    }

    private enum CodingKeys: String, CodingKey { case facts, affect, caring, cares, promises, complete }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        facts = try values.decode(Bool.self, forKey: .facts)
        affect = try values.decode(Bool.self, forKey: .affect)
        caring = try values.decode(Bool.self, forKey: .caring)
        cares = try values.decode(Bool.self, forKey: .cares)
        let measuredPromises = try values.decodeIfPresent(Bool.self, forKey: .promises)
        promises = measuredPromises
        complete = try values.decode(Bool.self, forKey: .complete) && measuredPromises != nil
    }
}

actor AfterTurnSurpriseLedger {
    static let shared = AfterTurnSurpriseLedger()
    // Retained rows that never measured promises remain incomplete evidence. The reader preserves their unknown channel without rewriting the ledger.
    static let version = 3
    struct Row: Codable, Sendable {
        let version: Int
        let at: Date
        let session: String
        let turn: String
        let surface: String
        let recovery: Bool
        let deferred: Bool
        var check: AfterTurnMemorySurprise
        var channels: AfterTurnChannelOutcome?
        let providerSeconds: Double
        let failure: String?
        var id: String { session + "\u{0}" + turn }
    }
    private struct Book {
        var rows: [String: Row] = [:]
        var vectorIDs: [String] = []
        var vectorElements = 0
        var readable = true
    }
    private var books: [String: Book] = [:]
    static func path(dataRoot: URL) -> URL { dataRoot.appendingPathComponent("memory/after_turn_surprise.jsonl") }

    /// Stream bounded chunks on reconstruction. Count-only rows grant no standing; corrupt or undecodable current rows make the record unreadable.
    private func book(_ root: URL) -> Book {
        let path = Self.path(dataRoot: root)
        let key = path.standardizedFileURL.path
        if let book = books[key] { return book }
        var book = Book()
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                let handle = try FileHandle(forReadingFrom: path)
                defer { try? handle.close() }
                var pending = Data()
                var oversized = false
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                    for byte in chunk {
                        if byte == 0x0A {
                            if !oversized,
                               let header = (try? JSONSerialization.jsonObject(with: pending)) as? [String: Any],
                               let version = header["version"] as? Int {
                                if version == Self.version {
                                    // Undecodable current rows are missing evidence, never standing.
                                    if let row = try? JSONDecoder().decode(Row.self, from: pending) {
                                        Self.add(row, to: &book)
                                    } else { book.readable = false }
                                } else if version > Self.version { book.readable = false }
                            } else { book.readable = false }
                            pending.removeAll(keepingCapacity: true)
                            oversized = false
                        } else if pending.count < 2_097_152, !oversized { pending.append(byte) }
                        else { oversized = true; book.readable = false }
                    }
                }
                if !pending.isEmpty || oversized { book.readable = false }
            } catch { book.readable = false }
        }
        books[key] = book
        return book
    }

    private static func vectorCount(_ check: AfterTurnMemorySurprise) -> Int {
        (check.vectors ?? []).reduce(0) { $0 &+ $1.count }
    }

    private static func add(_ row: Row, to book: inout Book) {
        // A settled label is final: a later attempt adds no second trial.
        if book.rows[row.id]?.channels?.complete == true { return }
        var row = row
        // Keep the original prediction and judging model: comparing against memory written later would leak the answer. A label's vectors come from here.
        if let original = book.rows[row.id], row.channels != nil, original.check.at != nil {
            row.check = original.check.judged(by: row.check.scope?.model)
        }
        let changedLabel = row.check.verdict == .nothingNew ? row.channels?.nothingNew == false
            : row.check.verdict == .somethingNew && row.channels?.nothingNew == true
        // Only an unlabelled-precedent turn or a contradicted prediction keeps its vectors as a new precedent.
        if row.channels?.complete == true, row.check.rule != nil, !changedLabel {
            row.check = row.check.withoutVectors()
        }
        if let old = book.rows[row.id], old.check.vectors != nil {
            book.vectorElements = max(0, book.vectorElements &- vectorCount(old.check))
            book.vectorIDs.removeAll { $0 == row.id }
        }
        book.rows[row.id] = row
        if row.check.vectors != nil {
            book.vectorIDs.append(row.id)
            book.vectorElements = book.vectorElements &+ vectorCount(row.check)
        }
        // Bounds the WHOLE resident root's precedent vectors; numeric labels stay.
        while !book.vectorIDs.isEmpty, book.vectorIDs.count > 256 || book.vectorElements > 1_048_576 {
            let oldID = book.vectorIDs.removeFirst()
            guard let old = book.rows[oldID] else { continue }
            book.vectorElements = max(0, book.vectorElements &- vectorCount(old.check))
            book.rows[oldID]?.check = old.check.withoutVectors()
        }
    }

    private func rows(_ book: Book, scope: AfterTurnMemorySurprise.Scope?) -> [Row] {
        guard let scope else { return [] }
        return book.rows.values.filter { $0.check.scope == scope }
    }

    private func agreement(_ book: Book, scope: AfterTurnMemorySurprise.Scope?) -> AfterTurnSurpriseAgreement {
        let all = rows(book, scope: scope)
        let predicted = all.filter { $0.check.verdict == .nothingNew }
        return .init(turns: all.count, wouldDefer: predicted.count,
            changedOnPrediction: predicted.filter { $0.channels?.complete == true && $0.channels?.nothingNew == false }.count,
            incompletePredictions: predicted.filter { $0.channels?.complete != true }.count,
            ledgerReadable: book.readable)
    }

    func dreamMisses(dataRoot: URL, since: Date, through: Date) throws -> [String] {
        let book = book(dataRoot)
        guard book.readable else { throw MemoryV2Error.underlying("After-turn surprise ledger is unreadable.") }
        let missed = book.rows.values.filter {
            $0.at > since && $0.at <= through && $0.check.verdict == .nothingNew
                && $0.channels?.complete == true && $0.channels?.nothingNew == false
        }.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
        guard !missed.isEmpty else { return [] }
        return ["After-turn predictions: \(missed.count) expected nothing new, but changed."]
            + missed.prefix(3).map { row in
                let channels = row.channels!
                let changed = [("memory", channels.facts), ("affect", channels.affect),
                               ("caring", channels.caring), ("cares", channels.cares),
                               ("promises", channels.promises == true)].filter { $0.1 }.map { $0.0 }
                return "turn \(row.turn): expected nothing new; changed \(changed.joined(separator: ", "))."
            }
    }

    /// 65,536 chunk pairs admit all 256 newest examples at 16 chunks per side; bound comparison work without changing nomination or cost bars.
    private static let comparisonCap = 65_536

    func predict(dataRoot: URL, scope: AfterTurnMemorySurprise.Scope, epoch: String,
                 vectors: [[Float]], excluding turn: String) -> AfterTurnMemorySurprise {
        let book = self.book(dataRoot)
        guard book.readable else { return .unsure("ledger_unavailable") }
        let all = rows(book, scope: scope)
        let examples = all.filter { $0.turn != turn && $0.channels?.complete == true
            && $0.check.epoch == epoch && $0.check.vectors?.first?.count == vectors.first?.count }
            .sorted { $0.at > $1.at }.prefix(256)
        let comparisons = examples.reduce(0) { $0 &+ ($1.check.vectors?.count ?? 0) }
        guard comparisons <= Self.comparisonCap / max(1, vectors.count) else { return .unsure("precedent_comparison_bound") }
        // Every chunk on BOTH sides needs a counterpart. Similarity nominates; only the model's settled judgment labels the complete interpretation.
        let ranked = examples.compactMap { row -> (Row, Double)? in
            guard let old = row.check.vectors, !old.isEmpty else { return nil }
            let forward = vectors.map { q in old.map { VectorMath.cosine(q, $0) }.max() ?? -1 }.min() ?? -1
            let reverse = old.map { q in vectors.map { VectorMath.cosine(q, $0) }.max() ?? -1 }.min() ?? -1
            return (row, min(forward, reverse))
        }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        var verdict = AfterTurnMemorySurprise.Verdict.unsure
        var rule: String?
        if let best = ranked.first,
           let standout = VectorMath.standout(ranked.map(\.1))[0],
           standout >= VectorMath.chanceBar(.action, among: ranked.count) {
            verdict = best.0.channels?.nothingNew == true ? .nothingNew : .somethingNew
            // The labelled precedent is the claim. Its contrast population still decides nomination, but cannot reset this claim's trials.
            rule = AfterTurnMemorySurprise.fingerprint([best.0.id])
        }
        // Only complete judgments of turns this claim predicted as no-ops count as cost-law trials.
        let trials = all.filter { rule != nil && $0.check.rule == rule && $0.check.verdict == .nothingNew
            && $0.channels?.complete == true }
        let n = trials.count
        let hits = trials.filter { $0.channels?.nothingNew == true }.count
        // Measure c_hit from direct live judgment service time, excluding folding and storage; prediction-to-label wall time measures delay separately.
        let direct = all.filter { !$0.recovery && !$0.deferred && $0.providerSeconds > 0 }
        let hitCost = direct.isEmpty ? 0 : direct.reduce(0) { $0 + $1.providerSeconds } / Double(direct.count)
        // Measure c_miss as prediction-to-label delay of required outcomes; before deferral, use live judgment delay. Correct no-ops delay no outcome.
        let delays = all.compactMap { row -> Double? in
            guard let start = row.check.at, row.channels?.complete == true,
                  !row.deferred || row.channels?.nothingNew == false else { return nil }
            return max(0, row.at.timeIntervalSince(start))
        }
        let missCost = delays.max() ?? 0
        // Defer only when the Wilson 95% lower hit-rate bound beats c_miss / (c_miss + c_hit). This assumes independent, representative outcomes and stable
        // service/delay costs. Bounds are per claim and look, without repeated-look correction; every deferred turn is judged in its batch. This estimates
        // cost, never guarantees it.
        let standing = Expectation.stands(hits: hits, tries: n,
            cHit: hitCost > 0 ? hitCost : nil, cMiss: missCost > 0 ? missCost : nil)
        return .init(verdict: verdict, reason: rule == nil ? "no_standing_precedent" : "labelled_precedent",
            epoch: epoch, scope: scope, rule: rule, at: Date(), vectors: vectors,
            standing: verdict == .nothingNew && standing.stands,
            lowerBound: standing.lower, costBar: standing.bar ?? 1, tries: n, hits: hits)
    }

    func record(dataRoot: URL, session: String, turn: String, surface: String,
                recovery: Bool, deferred: Bool, check: AfterTurnMemorySurprise,
                channels: AfterTurnChannelOutcome?, providerSeconds: Double,
                failure: String?, judgedBy: String?) -> AfterTurnSurpriseObservation {
        var book = self.book(dataRoot)
        // Only the model that judged a turn earns its calibration, regardless of the predicted model.
        var row = Row(version: Self.version, at: Date(), session: session, turn: turn, surface: surface,
            recovery: recovery, deferred: deferred,
            check: channels == nil ? check : check.judged(by: judgedBy), channels: channels,
            providerSeconds: max(0, providerSeconds), failure: failure)
        do {
            var bytes = try JSONEncoder().encode(row)
            if bytes.count >= 2_097_152 {
                row.check = row.check.withoutVectors()
                bytes = try JSONEncoder().encode(row)
            }
            bytes.append(0x0A)
            try SwiftNativePersistenceCore.appendLines(bytes, to: Self.path(dataRoot: dataRoot))
            Self.add(row, to: &book)
        } catch {
            book.readable = false
            nativeLog("MemoryV2: surprise ledger append failed: %@", error.localizedDescription)
        }
        books[Self.path(dataRoot: dataRoot).standardizedFileURL.path] = book
        return .init(check: row.check, agreement: agreement(book, scope: row.check.scope), deferred: deferred)
    }

    /// Score the original prediction of a judged turn and preserve deferral state. Recovery from failed calls or quits never measures live-path cost.
    /// The label row stores no vectors: `add` reads them from the turn's prediction row, so a turn's vectors are written once.
    func label(dataRoot: URL, session: String, turn: String, surface: String,
               channels: AfterTurnChannelOutcome, providerSeconds: Double,
               judgedBy: String?) -> AfterTurnSurpriseObservation {
        let original = book(dataRoot).rows[session + "\u{0}" + turn]
        let deferred = original?.deferred ?? false
        return record(dataRoot: dataRoot, session: session, turn: turn, surface: surface, recovery: !deferred,
                      deferred: deferred, check: original?.check.withoutVectors() ?? .unsure("label_without_prediction"),
                      channels: channels, providerSeconds: providerSeconds, failure: nil,
                      judgedBy: judgedBy)
    }

}

extension SwiftNativeMemoryV2 {
    /// Read the ledger's final labels, retaining the original prediction and counting a deferred turn once when its batch has actually judged it.
    public static func afterTurnMissesForDream(dataRoot: URL, since: Date, through: Date) async throws -> [String] {
        try await AfterTurnSurpriseLedger.shared.dreamMisses(dataRoot: dataRoot, since: since, through: through)
    }
}
