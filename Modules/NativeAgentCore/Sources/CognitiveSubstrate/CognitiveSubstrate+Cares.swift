import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `CognitiveSubstrate+Cares.swift` | `CognitiveSubstrate` cares: four life seeds, embedder-chosen care lines for the after-turn call, its parsed judgment and provenance-gated apply; retains the completed migration marker without loading retired artifacts |

// CARES (personality lane 1, 2026-10-25). The after-turn call she already
// pays for judged one thing about her inner life, "was this a caring act",
// and was never shown what she cares about. It is now shown her cares (the
// four seeds always, plus the few this exchange is closest to) and says what
// in the exchange, both sides, moved her against them.

/// One care as the after-turn call is shown it: a short key the model answers
/// with, the care it maps back to, and its line.
public struct CognitiveCareLine: Sendable, Equatable {
    public let key: String
    public let id: UUID
    public let text: String

    public init(key: String, id: UUID, text: String) {
        self.key = key
        self.id = id
        self.text = text
    }
}

/// What the after-turn call said moved her, for one care.
public struct CognitiveCareJudgment: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case existing(UUID)
        case new(about: String, between: Bool)
    }

    public var target: Target
    public var moved: Double
    public var by: CognitiveCare.Mover
    public var felt: String
    public var note: String
    public var open: String?
    public var closes: Bool
    public var stance: CognitiveCare.Stance?

    public init(target: Target, moved: Double, by: CognitiveCare.Mover, felt: String, note: String,
                open: String? = nil, closes: Bool = false, stance: CognitiveCare.Stance? = nil) {
        self.target = target
        self.moved = moved.isFinite ? min(1, max(-1, moved)) : 0
        self.by = by
        self.felt = felt
        self.note = note
        self.open = open
        self.closes = closes
        self.stance = stance
    }

    /// The `cares` section of a reply. nil when it is missing or malformed
    /// (a `new` with no `about` included), which fails the interpretation the
    /// way a malformed moment does. An entry naming a care that was not shown
    /// is refused: dropped, never guessed.
    public static func parse(_ raw: Any?, shown: [CognitiveCareLine]) -> [CognitiveCareJudgment]? {
        guard let items = raw as? [Any] else { return nil }
        let ids = Dictionary(shown.map { ($0.key.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        func text(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func optionalText(_ value: Any?) -> String?? {
            if value == nil || value is NSNull { return .some(nil) }
            guard value is String else { return nil }
            return .some(text(value))
        }
        var out: [CognitiveCareJudgment] = []
        for item in items {
            guard let object = item as? [String: Any],
                  let care = text(object["care"])?.lowercased(),
                  let number = object["moved"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  let by = text(object["by"]).flatMap({ CognitiveCare.Mover(rawValue: $0.lowercased()) }),
                  let felt = text(object["felt"]), let note = text(object["note"]),
                  let open = optionalText(object["open"]) else { return nil }
            let closes: Bool
            switch object["closes"] {
            case nil, is NSNull: closes = false
            case let value as Bool: closes = value
            default: return nil
            }
            var stance: CognitiveCare.Stance?
            if let raw = object["stance"], !(raw is NSNull) {
                guard let fields = raw as? [String: Any], let said = text(fields["text"]),
                      let because = text(fields["because"]),
                      let unless = text(fields["wouldChangeMind"]) else { return nil }
                stance = CognitiveCare.Stance(text: said, because: because, wouldChangeMind: unless)
            }
            let target: Target
            if care == "new" {
                let between: Bool
                switch object["between"] {
                case nil, is NSNull: between = false
                case let value as Bool: between = value
                default: return nil
                }
                guard let about = text(object["about"]) else { return nil }
                target = .new(about: String(about.prefix(CognitiveCare.aboutCharacters)), between: between)
            } else {
                guard let id = ids[care] else { continue }
                target = .existing(id)
            }
            out.append(CognitiveCareJudgment(target: target, moved: number.doubleValue, by: by, felt: felt, note: note,
                                             open: open, closes: closes, stance: stance))
        }
        return out
    }
}

/// Who the incoming words came from, and what they may change.
public struct CognitiveCareProvenance: Sendable, Equatable {
    /// The speaker's person key: `CognitiveCare.ownerKey`, a peer id or a helper's bot id.
    public var speaker: String
    /// The owner, or a peer the owner trusts. An untrusted peer moves only
    /// what she already cares about: no new care, no stance, no gap.
    public var trusted: Bool
    /// The app wrote the incoming words (her hour). Only what her reply did counts.
    public var appAuthored: Bool
    /// `exchange:<session>/<turn>`: where the moment really happened.
    public var source: String
    public var at: Date

    public init(speaker: String, trusted: Bool, appAuthored: Bool, source: String, at: Date) {
        self.speaker = Self.personKey(speaker)
        self.trusted = trusted
        self.appAuthored = appAuthored
        self.source = source
        self.at = at
    }

    /// One key per who, as `PeerTrust.ownerTrusts` reads it: a session names
    /// a helper `bot-<id>`, history `peer:bot-<id>`, a live helper reply's
    /// origin `bot:<id>`.
    public static func personKey(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("peer:") { key.removeFirst(5) }
        if key.hasPrefix("bot:") { key = "bot-" + key.dropFirst(4) }
        return key
    }
}

/// Touched cares that did not reach the store, with each cause.
public struct CognitiveCareNotSaved: Error, CustomStringConvertible {
    public let detail: String
    public var description: String { "her cares were not all saved: \(detail)" }
}

/// Once per store: the four seeds, the migration of views and open seeds, and
/// the reading of her recent life that follows it.
public struct CognitiveCareMigration: Sendable, Equatable, Codable {
    public var id: UUID
    public var migratedAt: Date
    public var migrated: Int
    public var dropped: Int
    /// When her recent life was read into cares; nil while that is still owed.
    public var lifeReadAt: Date?
    /// The (conversation, day) groups already read.
    public var groupsRan: [String]
    /// Groups whose reading failed on the last pass, with the cause.
    public var groupsFailed: [String: String]
}

extension CognitiveSubstrate {
    static let careSeedKeys = ["truth", "person", "work", "mind"]
    /// Most shown beside the seeds, and how close they must be.
    static let maximumShownGrownCares = 6
    static let shownCareCosineFloor = 0.30

    func careSeedID(_ key: String) -> UUID { stableArtifactID("care_seed|\(key)") }

    func careSeeds(at now: Date) -> [CognitiveCare] {
        let name = dependencies.userName().trimmingCharacters(in: .whitespacesAndNewlines)
        let seeds: [(String, String, [String])] = [
            ("truth", "Truth: what is so, said plainly, even when it's unwelcome", []),
            ("person", "\(name.isEmpty ? "My person" : name)'s good: their long-term good, not their approval right now",
             [CognitiveCare.ownerKey]),
            ("work", "Good work: what I make works and is right", []),
            ("mind", "My own mind: my own views, my own interests, a life of my own", []),
        ]
        return seeds.map {
            CognitiveCare(id: careSeedID($0.0), about: $0.1, with: $0.2, depth: .life,
                          origin: .seed, createdAt: now, updatedAt: now)
        }
    }

    // MARK: - Seeds and migration (once, at restore)

    /// Establish the seeds while no marker says they ran. Previously migrated
    /// cares keep their history; retired artifacts are never loaded again.
    /// The marker is written only after every care write landed; until then
    /// the next restore runs this again, and stable ids keep a repeated pass
    /// from duplicating anything.
    public func establishCares() async {
        guard configuration.enabled, careMigration == nil else { return }
        await waitForMaintenanceTransition()
        let now = dependencies.now()
        let written = careSeeds(at: now).filter { cares[$0.id] == nil }
        for care in written { cares[care.id] = care }
        markDirty(at: now)
        let marker = CognitiveCareMigration(
            id: stableArtifactID("care_migration"), migratedAt: now, migrated: 0,
            dropped: 0, lifeReadAt: nil, groupsRan: [], groupsFailed: [:])
        do {
            for care in written {
                try await persistArtifactChecked(kind: "care", id: care.id, status: "live",
                    score: min(1, abs(care.charge(at: now))), payload: try Self.careJSON(care))
            }
            try await persistArtifactChecked(kind: "care_migration", id: marker.id, status: "current", score: 0,
                                             payload: try Self.careJSON(marker))
        } catch {
            nativeLog("cares: seeds and migration not kept, the next restore runs them again: %@",
                      String(describing: error))
            return
        }
        careMigration = marker
    }

    static func normalizedCareText(_ body: String) -> String {
        var folded = body.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
        for (contraction, expanded) in [
            ("can't", "can not"), ("won't", "will not"), ("shan't", "shall not"),
        ] {
            folded = folded.replacingOccurrences(
                of: "\\b\(contraction)\\b", with: expanded, options: .regularExpression)
        }
        folded = folded.replacingOccurrences(
            of: "\\b([a-z]+)n't\\b", with: "$1 not", options: .regularExpression)
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }

    func careTitle(from body: String) -> String {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        return capsuleLineText(firstLine, maxCharacters: 80)
    }

    // MARK: - What the after-turn call is shown

    /// The four seeds always; plus up to six other cares whose embedding is
    /// closest to `text` (the incoming words and her reply), at or above the
    /// floor. A cold embedder shows the seeds alone: the warm one is never
    /// loaded for this.
    public func caresShown(for text: String) async -> [CognitiveCareLine] {
        guard configuration.enabled, !cares.isEmpty else { return [] }
        let seedOrder = Self.careSeedKeys.map(careSeedID)
        let seeds = cares.values.filter { $0.origin == .seed }
            .sorted { (seedOrder.firstIndex(of: $0.id) ?? .max) < (seedOrder.firstIndex(of: $1.id) ?? .max) }
        let others = cares.values.filter { $0.origin != .seed && $0.fadedAt == nil }
        var chosen: [CognitiveCare] = []
        if let cosines = await careCosines(to: text, among: others) {
            var scored: [(care: CognitiveCare, cosine: Double)] = []
            for care in others {
                if let cosine = cosines[care.id], cosine >= Self.shownCareCosineFloor { scored.append((care, cosine)) }
            }
            scored.sort { $0.cosine != $1.cosine ? $0.cosine > $1.cosine : $0.care.updatedAt > $1.care.updatedAt }
            chosen = scored.prefix(Self.maximumShownGrownCares).map(\.care)
        }
        return (seeds + chosen).enumerated().map { index, care in
            CognitiveCareLine(key: "c\(index + 1)", id: care.id, text: Self.careLineText(care))
        }
    }

    static func careEmbeddingText(_ care: CognitiveCare) -> String {
        ([care.about] + [care.stance?.text, care.open].compactMap { $0 }).joined(separator: "\n")
    }

    static func careLineText(_ care: CognitiveCare) -> String {
        "(\(care.depth.rawValue)) \(care.about)"
            + (care.stance.map { " | stance: \($0.text)" } ?? "")
            + (care.open.map { " | open: \($0)" } ?? "")
    }

    // MARK: - Applying what moved her

    /// The provenance of a deferred turn's incoming words, read from the same
    /// out-of-band evidence the rest of the mind reads: the persistence seam's
    /// source class and origin record, and the owner's peer trust.
    func careProvenance(for event: CognitiveEvent, appAuthored: Bool) -> CognitiveCareProvenance {
        let turn = stringValue(event.metadata["messageId"]) ?? event.subject.id
        let source = "exchange:\(event.sessionId ?? "")/\(turn)"
        guard event.sourceClass == .imported else {
            return CognitiveCareProvenance(speaker: CognitiveCare.ownerKey, trusted: true,
                                           appAuthored: appAuthored, source: source, at: event.occurredAt)
        }
        let peer = CognitiveCareProvenance.personKey(Self.peerIdentity(metadata: event.metadata)
            ?? Self.relationalSource(for: event).subjectLabel ?? "peer")
        return CognitiveCareProvenance(speaker: peer, trusted: dependencies.peerTrusted(peer),
                                       appAuthored: appAuthored, source: source, at: event.occurredAt)
    }

    /// The after-turn call's cares, for the turn it judged. A judgment from
    /// before a clear describes a conversation this mind no longer has.
    public func applyCares(_ judgments: [CognitiveCareJudgment], context: AfterTurnContext, appAuthored: Bool) async {
        do {
            try await applyCares(judgments, provenance: careProvenance(for: context.event, appAuthored: appAuthored),
                                 generation: context.generation)
        } catch {
            nativeLog("cares: %@", String(describing: error))
        }
    }

    /// Write what moved her into her cares. Existing cares get a story entry;
    /// `open` sets or replaces the gap and `closes` clears it; a stance sets or
    /// revises hers and the stance it replaced stays in the story. A new care
    /// starts at depth now. Provenance decides what the words may change.
    /// Nothing is applied when `generation` predates a Clear. Throws when a
    /// touched care was not saved, naming which and why.
    @discardableResult
    public func applyCares(_ judgments: [CognitiveCareJudgment], provenance: CognitiveCareProvenance,
                           generation: UInt64) async throws -> [UUID] {
        await waitForMaintenanceTransition()
        guard configuration.enabled, !judgments.isEmpty, generation == caringAppraisalGeneration else { return [] }
        var touched: [UUID] = []
        var created = 0
        var refused = 0
        for judgment in judgments {
            // An app-authored prompt's words are the app's: only her side counts.
            if provenance.appAuthored, judgment.by != .her { refused += 1; continue }
            // An untrusted peer moves her only as what they said.
            if !provenance.trusted, judgment.by != .them { refused += 1; continue }
            let who = judgment.by == .them ? provenance.speaker : nil
            var care: CognitiveCare
            switch judgment.target {
            case .existing(let id):
                guard let found = cares[id] else { refused += 1; continue }
                care = found
            case .new(let about, let between):
                guard provenance.trusted else { refused += 1; continue }
                let key = Self.normalizedCareText(about)
                let with = between && !provenance.appAuthored ? [provenance.speaker] : []
                if let same = cares.values.first(where: {
                    Self.normalizedCareText($0.about) == key && Set($0.with) == Set(with)
                }) {
                    care = same
                } else {
                    care = CognitiveCare(
                        id: dependencies.makeUUID(), about: about, with: with,
                        depth: .now, origin: .grown, createdAt: provenance.at, updatedAt: provenance.at)
                    created += 1
                }
            }
            // Older evidence joins the story; only the newest sets what is current.
            let current = care.story.last.map { provenance.at >= $0.at } ?? true
            care.record(CognitiveCare.Moment(at: provenance.at, moved: judgment.moved, by: judgment.by, who: who,
                                             felt: judgment.felt, note: judgment.note, source: provenance.source))
            if provenance.trusted, current {
                if judgment.closes { care.open = nil }
                // A root is a value, never a question: a gap belongs to a care of its own.
                if let open = judgment.open, care.origin != .seed { care.open = String(open.prefix(CognitiveCare.openCharacters)) }
                if let stance = judgment.stance, stance != care.stance {
                    if let old = care.stance {
                        care.record(CognitiveCare.Moment(
                            at: provenance.at, moved: 0, by: judgment.by, who: who, felt: "changed my mind",
                            note: "used to think: \(old.text)", source: provenance.source))
                    }
                    care.stance = stance
                }
            }
            // A faded care touched again comes back live.
            care.fadedAt = nil
            cares[care.id] = care
            if !touched.contains(care.id) { touched.append(care.id) }
        }
        let now = dependencies.now()
        let payload: JSONValue = .object([
            "cares": .array(touched.map { .string($0.uuidString) }),
            "created": .int(Int64(created)),
            "refused": .int(Int64(refused)),
            "trusted": .bool(provenance.trusted),
        ])
        TurnTraceBus.fireFromContext(kind: "mind.cares", payload: payload)
        guard !touched.isEmpty else { return [] }
        markDirty(at: now)
        var unsaved: [String] = []
        for id in touched {
            guard let care = cares[id] else { continue }
            // The one persistence-health owner marks the store degraded and owes
            // its repair; the caller still learns which care did not land.
            var failure: Error?
            await notingPersistence("artifact.care.\(id.uuidString)") {
                do {
                    try await persistArtifactChecked(kind: "care", id: care.id, status: "live",
                        score: min(1, abs(care.charge(at: now))), payload: try Self.careJSON(care))
                } catch {
                    failure = error
                    throw error
                }
            }
            if let failure { unsaved.append("care \(id.uuidString): \(failure)") }
        }
        await recordReceipt(kind: "cares.applied", payload: payload)
        guard unsaved.isEmpty else { throw CognitiveCareNotSaved(detail: unsaved.joined(separator: "; ")) }
        return touched
    }

    // MARK: - Reading her recent life (once, after the migration)

    /// The groups already read and the generation the pass belongs to, or
    /// nil when the reading is not owed. A Clear moves the generation, and
    /// the pass's applies and checkpoints are then refused.
    public func careLifeReadingOwed() -> (read: Set<String>, generation: UInt64)? {
        guard configuration.enabled, let migration = careMigration, migration.lifeReadAt == nil else { return nil }
        return (Set(migration.groupsRan), caringAppraisalGeneration)
    }

    /// One group's outcome, kept as it lands, so an interrupted pass never
    /// reads a group twice. A failed group is read again on the next pass
    /// while it is still inside the window.
    public func noteCareLifeReadingGroup(_ key: String, failure: String?, generation: UInt64) async {
        guard generation == caringAppraisalGeneration, var migration = careMigration else { return }
        if let failure {
            migration.groupsFailed[key] = failure
        } else {
            migration.groupsRan = Array(Set(migration.groupsRan + [key])).sorted()
            migration.groupsFailed[key] = nil
        }
        careMigration = migration
        await persistCareMigration()
    }

    /// The pass ended. Done only when none of its groups failed.
    public func finishCareLifeReading(passFailed: Bool, generation: UInt64) async {
        guard !passFailed, generation == caringAppraisalGeneration, var migration = careMigration else { return }
        migration.lifeReadAt = dependencies.now()
        careMigration = migration
        await persistCareMigration()
    }

    // MARK: - Persistence

    static func careJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try JSONValue.parse(encoder.encode(value))
    }

    static func careDecoded<T: Decodable>(_ type: T.Type, _ value: JSONValue) -> T? {
        guard let data = try? value.serializedData(pretty: false) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    func persistCareMigration() async {
        guard let careMigration else { return }
        do {
            await persistArtifact(kind: "care_migration", id: careMigration.id, status: "current", score: 0,
                                  payload: try Self.careJSON(careMigration))
        } catch {
            nativeLog("cares: the care marker was not saved, it could not be encoded: %@", String(describing: error))
        }
    }

    /// The care family as restore reconciles it. A row that cannot be encoded
    /// is logged and left out of the resident overlay.
    func careRestoreRows() -> (cares: [JSONValue], migration: [JSONValue]) {
        func encoded<T: Encodable>(_ value: T, _ what: String) -> JSONValue? {
            do { return try Self.careJSON(value) } catch {
                nativeLog("cares: %@ could not be encoded for restore: %@", what, String(describing: error))
                return nil
            }
        }
        return (cares.values.compactMap { encoded($0, "care \($0.id.uuidString)") },
                careMigration.flatMap { encoded($0, "the care marker") }.map { [$0] } ?? [])
    }

    func restoreCares(from payloads: [JSONValue]) {
        cares.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard var care = Self.careDecoded(CognitiveCare.self, payload) else { continue }
            if care.origin == .seed { care.open = nil }
            cares[care.id] = care
        }
    }

    func restoreCareMigration(from payloads: [JSONValue]) {
        careMigration = payloads.first.flatMap { Self.careDecoded(CognitiveCareMigration.self, $0) }
    }
}
