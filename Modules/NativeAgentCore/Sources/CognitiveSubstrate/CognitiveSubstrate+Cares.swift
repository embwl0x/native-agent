import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import NativeAgentShared
// Blueprint: | `CognitiveSubstrate+Cares.swift` | `CognitiveSubstrate` cares: four life seeds, embedder-ordered care lines (the call names the care), shared embedding text and provenance-gated apply returning affected IDs; converts retired views and thought seeds once |

// After-turn interpretation reads both sides against the four care seeds and the closest existing cares.

/// One care as the after-turn call is shown it: a short key the model answers
/// with, the care it maps back to, and its line.
public struct CognitiveCareLine: Codable, Sendable, Equatable {
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
public struct CognitiveCareJudgment: Codable, Sendable, Equatable {
    public enum Target: Codable, Sendable, Equatable {
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
    /// way a malformed memories section does. An entry naming a care that was not shown
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
    /// Resident changes whose durability is still owed, without reapplying them.
    public let ids: [UUID]
    public init(detail: String, ids: [UUID] = []) {
        self.detail = detail
        self.ids = ids
    }
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
    /// Most shown beside the seeds.
    static let maximumShownGrownCares = 6

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

    /// Establish the seeds while no marker says they ran, and convert the
    /// retired views and thought seeds (their raw rows, read at restore) while
    /// no `care_retired_migration` marker says that ran: a store upgraded
    /// after the 0.6.12 seed marker still gets it. Each marker is written only
    /// after every care write landed; until then the next restore runs this
    /// again, and stable ids keep a repeated pass from duplicating anything.
    public func establishCares(retiredViews: [JSONValue] = [], retiredSeeds: [JSONValue] = []) async {
        guard configuration.enabled else { return }
        await waitForMaintenanceTransition()
        let owesSeeds = careMigration == nil
        let owesRetired = careRetiredMigration == nil
        guard owesSeeds || owesRetired else { return }
        let now = dependencies.now()
        let retired = owesRetired
            ? retiredCares(views: retiredViews, seeds: retiredSeeds, at: now) : (cares: [], dropped: 0)
        let carried = retired.cares.filter { cares[$0.id] == nil }
        let written = (owesSeeds ? careSeeds(at: now) : []).filter { cares[$0.id] == nil } + carried
        for care in written { cares[care.id] = care }
        markDirty(at: now)
        let marker = CognitiveCareMigration(
            id: stableArtifactID("care_migration"), migratedAt: now, migrated: 0,
            dropped: 0, lifeReadAt: nil, groupsRan: [], groupsFailed: [:])
        let retiredMarker: JSONValue = .object([
            "id": .string(stableArtifactID("care_retired_migration").uuidString),
            "migratedAt": .double(now.timeIntervalSince1970),
            "migrated": .int(Int64(carried.count)),
            "dropped": .int(Int64(retired.dropped)),
        ])
        do {
            try await saveCares(written.map(\.id), at: now).get()
            if owesSeeds {
                try await persistArtifactChecked(kind: "care_migration", id: marker.id, status: "current", score: 0,
                                                 payload: try Self.careJSON(marker))
                careMigration = marker
            }
            if owesRetired {
                try await persistArtifactChecked(kind: "care_retired_migration",
                    id: stableArtifactID("care_retired_migration"), status: "current", score: 0,
                    payload: retiredMarker)
                careRetiredMigration = retiredMarker
                nativeLog("cares: retired views and thoughts, once: migrated=%ld dropped=%ld",
                          carried.count, retired.dropped)
            }
        } catch {
            nativeLog("cares: seeds and migration not kept, the next restore runs them again: %@",
                      String(describing: error))
        }
    }

    /// The retired standing views and thought seeds as cares, read from their
    /// raw rows (the types are gone), with the mapping of the first migration.
    /// Each keeps one story entry pointing at the row it came from. Retired
    /// views and machine noise (every anomaly, the microcycle pressure seed,
    /// runtime talk, any follow-up that is not a pinned concern) are dropped.
    func retiredCares(views: [JSONValue], seeds: [JSONValue], at now: Date)
        -> (cares: [CognitiveCare], dropped: Int) {
        var out: [CognitiveCare] = []
        var dropped = 0
        func carried(_ row: [String: JSONValue], updatedKey: String, about: String, depth: CognitiveCare.Depth,
                     stance: CognitiveCare.Stance? = nil, open: String? = nil, was: String) -> CognitiveCare? {
            guard let id = uuidValue(row["id"]), let created = dateValue(row["createdAt"]),
                  let updated = dateValue(row[updatedKey]) else { return nil }
            let at = min(updated, now)
            return CognitiveCare(
                id: stableArtifactID("care_migrated|\(id.uuidString)"), about: about, depth: depth,
                stance: stance, open: open,
                story: [CognitiveCare.Moment(at: at, moved: 0, by: .her, felt: "carried over",
                                             note: "was \(was)", source: id.uuidString)],
                origin: .migrated(id.uuidString), createdAt: min(created, at), updatedAt: at)
        }
        for case .object(let row) in views {
            var care: CognitiveCare?
            if let title = row["title"]?.stringValue, let body = row["body"]?.stringValue,
               let status = row["status"]?.stringValue {
                let stance = CognitiveCare.Stance(text: body, because: row["because"]?.stringValue ?? "",
                                                  wouldChangeMind: row["wouldChangeMind"]?.stringValue ?? "")
                switch status {
                case "active", "opinion":
                    care = carried(row, updatedKey: "updatedAt", about: title, depth: .season, stance: stance,
                                   was: status == "opinion" ? "an opinion" : "an approved view")
                case "held", "proposed":
                    care = carried(row, updatedKey: "updatedAt", about: title, depth: .lately, stance: stance,
                                   was: "a \(status) view")
                case "interest":
                    care = carried(row, updatedKey: "updatedAt", about: title, depth: .season, open: body,
                                   was: "an interest")
                default:
                    break
                }
            }
            if let care { out.append(care) } else { dropped += 1 }
        }
        let pinned = "Pinned concern:"
        for case .object(let row) in seeds {
            var care: CognitiveCare?
            let text = row["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lower = text.lowercased()
            switch row["kind"]?.stringValue {
            case let kind? where kind == "reflectionTakeaway" || kind == "openQuestion":
                let noise = text.isEmpty || isOperationalSubconsciousNoise(lower)
                    || isConversationalPresenceStatement(lower)
                    || (kind == "openQuestion" && isRuntimeMetaStatement(lower))
                if !noise {
                    care = carried(row, updatedKey: "lastUpdatedAt", about: careTitle(from: text), depth: .now,
                                   open: text, was: kind == "openQuestion" ? "an open question" : "a takeaway")
                }
            case "followUp"? where text.hasPrefix(pinned):
                let concern = strippingPrefix(pinned, from: text)
                care = carried(row, updatedKey: "lastUpdatedAt", about: careTitle(from: concern), depth: .lately,
                               open: concern, was: "a pinned concern")
            default:
                break
            }
            if let care { out.append(care) } else { dropped += 1 }
        }
        return (out, dropped)
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

    /// The four seeds always; plus the six other cares whose embedding is
    /// closest to `text` (the incoming words and her reply). The embedding only
    /// orders the list; which care moved, or whether it is new, is the reading
    /// call's to name. A cold embedder shows the seeds alone: the warm one is
    /// never loaded for this.
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
                if let cosine = cosines[care.id] { scored.append((care, cosine)) }
            }
            scored.sort { $0.cosine != $1.cosine ? $0.cosine > $1.cosine : $0.care.updatedAt > $1.care.updatedAt }
            chosen = scored.prefix(Self.maximumShownGrownCares).map(\.care)
        }
        return (seeds + chosen).enumerated().map { index, care in
            CognitiveCareLine(key: "c\(index + 1)", id: care.id, text: Self.careLineText(care))
        }
    }

    static func careEmbeddingText(_ care: CognitiveCare) -> String {
        careMemoryTexts(care).joined(separator: "\n")
    }

    static func careMemoryTexts(_ care: CognitiveCare) -> [String] {
        [care.about] + [care.stance?.text, care.open].compactMap { $0 }
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
        let turn = event.metadata["messageId"]?.stringValue ?? event.subject.id
        let source = "exchange:\(event.sessionId ?? "")/\(turn)"
        guard event.sourceClass == .imported else {
            return CognitiveCareProvenance(speaker: CognitiveCare.ownerKey, trusted: true,
                                           appAuthored: appAuthored, source: source, at: event.occurredAt)
        }
        let peer = CognitiveCareProvenance.personKey(Self.peerIdentity(metadata: event.metadata, dataRoot: conversationDataRoot)
            ?? Self.relationalSource(for: event).subjectLabel ?? "peer")
        return CognitiveCareProvenance(speaker: peer, trusted: dependencies.peerTrusted(peer),
                                       appAuthored: appAuthored, source: source, at: event.occurredAt)
    }

    /// A new care's identity for a lived moment: derived from (moment,
    /// ordinal), so a refold finds the care its first fold created.
    static func momentCareID(_ momentID: String, ordinal: Int) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(momentID)|care|\(ordinal)".utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Write provenance-admitted movement, story, gap and stance; return affected
    /// IDs after checked saves. A generation before Clear applies nothing.
    /// `seq`: the lived moment's fold seq (nil off the journal). Every care's
    /// watermark is read once before the moment's judgments, a care already at
    /// or past `seq` is left alone, and each touched care is stamped after ALL
    /// of the moment's judgments (two may move the same care).
    @discardableResult
    public func applyCares(_ judgments: [CognitiveCareJudgment], provenance: CognitiveCareProvenance,
                           generation: UInt64, seq: UInt64? = nil,
                           momentID: String? = nil) async throws -> [UUID] {
        await waitForMaintenanceTransition()
        guard configuration.enabled, generation == caringAppraisalGeneration, !judgments.isEmpty else { return [] }
        var touched: [UUID] = []
        var created = 0
        var refused = 0
        let livedBefore = cares.mapValues { $0.lived ?? 0 }
        // Cares this moment already moved (a refold): saved again, not moved.
        var relived: [UUID] = []
        func alreadyLived(_ id: UUID) -> Bool {
            guard let seq else { return false }
            return (livedBefore[id] ?? 0) >= seq
        }
        for (ordinal, judgment) in judgments.enumerated() {
            // An app-authored prompt's words are the app's: only her side counts.
            if provenance.appAuthored, judgment.by != .her { refused += 1; continue }
            // An untrusted peer moves her only as what they said.
            if !provenance.trusted, judgment.by != .them { refused += 1; continue }
            let who = judgment.by == .them ? provenance.speaker : nil
            var care: CognitiveCare
            switch judgment.target {
            case .existing(let id):
                guard let found = cares[id] else { refused += 1; continue }
                guard !alreadyLived(id) else { relived.append(id); continue }
                care = found
            case .new(let about, let between):
                guard provenance.trusted else { refused += 1; continue }
                let key = Self.normalizedCareText(about)
                let with = between && !provenance.appAuthored ? [provenance.speaker] : []
                let newID = momentID.map { Self.momentCareID($0, ordinal: ordinal) } ?? dependencies.makeUUID()
                if let mine = cares[newID] {
                    // This moment's own care, created by its first fold.
                    guard !alreadyLived(newID) else { relived.append(newID); continue }
                    care = mine
                } else if let same = cares.values.first(where: {
                    Self.normalizedCareText($0.about) == key && Set($0.with) == Set(with)
                        && (judgment.open == nil || $0.origin != .seed)
                }) {
                    guard !alreadyLived(same.id) else { relived.append(same.id); continue }
                    care = same
                } else {
                    care = CognitiveCare(
                        id: newID, about: about, with: with,
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
        if let seq {
            // Read, then write: `cares[id]?.lived = max(cares[id]?.lived …)`
            // reads `cares` inside its own write access, which aborts at runtime.
            for id in touched {
                let prior = cares[id]?.lived ?? 0
                cares[id]?.lived = max(prior, seq)
            }
        }
        let toSave = touched + relived.filter { !touched.contains($0) }
        guard !toSave.isEmpty else { return [] }
        if !touched.isEmpty { markDirty(at: now) }
        let saving = await saveCares(toSave, at: now)
        await recordReceipt(kind: "cares.applied", payload: payload)
        try saving.get()
        return touched
    }

    /// Writes these cares as they stand in RAM. A failed write leaves the care
    /// resident but not on disk, so what dedupes by a care's story saves it
    /// before it answers that something is already there.
    func saveCares(_ ids: [UUID], at now: Date) async -> Result<Void, CognitiveCareNotSaved> {
        guard !configuration.persistenceEnabled || store != nil else {
            return .failure(CognitiveCareNotSaved(detail: CognitivePersistenceError.storeUnavailable.description, ids: ids))
        }
        var unsaved: [String] = []
        for id in ids {
            guard let care = cares[id] else { continue }
            // The one persistence-health owner marks the store degraded and owes
            // its repair; the caller still learns which care did not land.
            var failure: Error?
            await notingPersistence("artifact.care.\(id.uuidString)") {
                do {
                    try await persistArtifactChecked(kind: "care", id: care.id, status: care.fadedAt == nil ? "live" : "faded",
                        score: min(1, abs(care.charge(at: now))), payload: try Self.careJSON(care))
                } catch {
                    failure = error
                    throw error
                }
            }
            if let failure { unsaved.append("care \(id.uuidString): \(failure)") }
        }
        return unsaved.isEmpty ? .success(()) : .failure(CognitiveCareNotSaved(detail: unsaved.joined(separator: "; "), ids: ids))
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

}
