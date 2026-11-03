import Foundation
import NativeAgentCore
import PersistenceCore
import CognitiveSubstrate
import NativeAgentShared

// Blueprint: | `AfterTurnSurpriseLedger.swift` | `AfterTurnSurpriseLedger`: the agent's own labelled record of complete-channel interpretation outcomes (append-only, keyed by agent, memory model and detector version): stable precedent claims, deferred turns labelled when their batch judges them, measured provider and delay costs under shared `Expectation` standing, and a bounded dream reading of contradicted no-op predictions |

public struct AfterTurnSurpriseObservation: Sendable, Equatable {
    public let check: AfterTurnMemorySurprise
    public let agreement: AfterTurnSurpriseAgreement
    /// True when this turn was left owed (deferred) instead of interpreted now.
    public var deferred = false
}

public struct AfterTurnSurpriseAgreement: Sendable, Equatable {
    /// Labelled or predicted turns in this scope.
    public let turns: Int
    /// Turns predicted a complete no-op.
    public let wouldDefer: Int
    /// Of those, turns whose interpretation changed ANY channel (memories,
    /// affect, caring, cares, promises): a wrong prediction.
    public let changedOnPrediction: Int
    /// Of those, turns not yet labelled by a complete judgment.
    public let incompletePredictions: Int
    public let ledgerReadable: Bool
}

/// What one judgment measured in each channel; retained judgments may be incomplete.
public struct AfterTurnChannelOutcome: Codable, Sendable, Equatable {
    public let facts: Bool
    public let affect: Bool
    public let caring: Bool
    public let cares: Bool
    /// Nil when a retained judgment never measured promises.
    public let promises: Bool?
    /// All five channels were measured, with facts asked and readable.
    public let complete: Bool
    public var nothingNew: Bool { complete && !facts && !affect && !caring && !cares && promises == false }

    /// The label a judgment gives: did it keep or change a memory, move affect
    /// beyond noise, judge a caring moment, move a care, or make a promise?
    public init(interpretation: AfterTurnInterpretation, factsAsked: Bool) {
        facts = interpretation.memories.contains { $0.action != .skip }
        affect = !interpretation.affect.isNoOp
        caring = interpretation.caring.kind != nil
        cares = !interpretation.cares.isEmpty
        promises = !interpretation.promises.isEmpty
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
    // Retained rows that never measured promises remain incomplete evidence.
    // The reader preserves their unknown channel without rewriting the ledger.
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

    /// Reconstructed once per root, streaming fixed-size chunks. Rows of an
    /// older version (count-only shadow labels) are kept on disk and never
    /// grant standing; a corrupt row, or a current-version row that does not
    /// decode, makes the record explicitly unreadable.
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
                                    // A current-version row that does not decode is
                                    // missing evidence: nothing stands on an
                                    // incomplete record.
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
        // A label keeps the turn's ORIGINAL prediction: comparing a later
        // judgment to memory written after the turn would leak the answer.
        // Its scope stays the model that judged it.
        if let original = book.rows[row.id], row.channels != nil, original.check.at != nil {
            row.check = original.check.judged(by: row.check.scope?.model)
        }
        let changedLabel = row.check.verdict == .nothingNew ? row.channels?.nothingNew == false
            : row.check.verdict == .somethingNew && row.channels?.nothingNew == true
        // Only an unlabelled-precedent turn or a contradicted prediction keeps
        // its vectors as a new precedent.
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

    /// 65,536 chunk pairs admits all 256 newest examples at 16 chunks per
    /// side. The 10-30 retained ledger's median is 4 chunks, p90 is 9 (max 30);
    /// the former 4,096 bound admitted only 4 per side at that population.
    /// This bounds comparison work only, never the nomination or cost bars.
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
        // Every chunk on BOTH sides needs a counterpart. Similarity nominates;
        // only the model's settled judgment labels the complete interpretation.
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
            // The labelled precedent is the claim. Its contrast population
            // still decides nomination, but cannot reset this claim's trials.
            rule = AfterTurnMemorySurprise.fingerprint([best.0.id])
        }
        // THE COST LAW, from this scope's own record. A trial is a turn this
        // claim predicted a no-op and a complete judgment later labelled.
        let trials = all.filter { rule != nil && $0.check.rule == rule && $0.check.verdict == .nothingNew
            && $0.channels?.complete == true }
        let n = trials.count
        let hits = trials.filter { $0.channels?.nothingNew == true }.count
        // c_hit: provider-service seconds a correct deferral saves the live
        // path (the mean of this scope's direct, live judgments). The monotonic
        // stopwatch surrounds only the judgment call, excluding folding and
        // storage. Prediction-to-label wall time remains the separate delay.
        let direct = all.filter { !$0.recovery && !$0.deferred && $0.providerSeconds > 0 }
        let hitCost = direct.isEmpty ? 0 : direct.reduce(0) { $0 + $1.providerSeconds } / Double(direct.count)
        // c_miss: seconds a WRONG deferral keeps a required outcome waiting
        // (from the prediction to its label; before any deferral exists, the
        // live judgments' own delay measures it). A correct deferred no-op has
        // no required outcome to delay.
        let delays = all.compactMap { row -> Double? in
            guard let start = row.check.at, row.channels?.complete == true,
                  !row.deferred || row.channels?.nothingNew == false else { return nil }
            return max(0, row.at.timeIntervalSince(start))
        }
        let missCost = delays.max() ?? 0
        // Defer only while the Wilson 95% lower bound of the claim's hit rate
        // beats c_miss / (c_miss + c_hit). Assumptions, stated: future turns'
        // outcomes are independent and resemble this scope's labelled past;
        // future provider service and delay resemble the measured ones; the
        // bound is per precedent claim and per look (repeated looks are not
        // corrected for; every deferred turn is still judged in its batch and
        // labels the claim). It is a cost estimate, never a guarantee.
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
        // A LABEL'S SCOPE IS THE MODEL THAT JUDGED IT: a turn predicted for
        // one model and judged by another never calibrates the first's claim.
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

    /// The label a batch judgment gives an owed turn: its original
    /// prediction stays the one scored, and it keeps whether it was deferred.
    /// An owed turn that was never deferred (a failed call, a quit) is
    /// recovery, so its batch share never measures the live path's cost.
    func label(dataRoot: URL, session: String, turn: String, surface: String,
               channels: AfterTurnChannelOutcome?, providerSeconds: Double,
               failure: String?, judgedBy: String?) -> AfterTurnSurpriseObservation {
        let original = book(dataRoot).rows[session + "\u{0}" + turn]
        let deferred = original?.deferred ?? false
        return record(dataRoot: dataRoot, session: session, turn: turn, surface: surface, recovery: !deferred,
                      deferred: deferred, check: original?.check ?? .unsure("label_without_prediction"),
                      channels: channels, providerSeconds: providerSeconds, failure: failure,
                      judgedBy: judgedBy)
    }

    /// Of these owed turns (session, turn), the ones that were deferred.
    func deferredTurns(dataRoot: URL, among turns: [(session: String, turn: String)]) -> Set<String> {
        let book = self.book(dataRoot)
        return Set(turns.map { $0.session + "\u{0}" + $0.turn }.filter { book.rows[$0]?.deferred == true })
    }
}

extension SwiftNativeMemoryV2 {
    /// Read the ledger's final labels, retaining the original prediction and
    /// counting a deferred turn once when its batch has actually judged it.
    public static func afterTurnMissesForDream(dataRoot: URL, since: Date, through: Date) async throws -> [String] {
        try await AfterTurnSurpriseLedger.shared.dreamMisses(dataRoot: dataRoot, since: since, through: through)
    }
}
