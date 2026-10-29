import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import CryptoKit
// Blueprint: | `StudioStore.swift` | Append-only journal and corrections, consult and honest-encounter truth; timestamps use NativeTimestampFormat directly; `encounterIntakePage` exposes bounded neutral consult/corrected-history facts with a shared content digest, refuses unreadable/incomplete history and changed pages; `namedEncounterIntake` validates editable `Resources/abilities/studio-intake.js` selection against native encounter truth, retaining no Swift ordering or invitation prose |

// Studio owns aesthetic history and consults under studio/, separately from factual MemoryV2. Storage is persona-independent; the agent supplies her own judgments.

// MARK: - Store

/// Append-under-flock studio store. Stateless — all state lives on disk.
public struct SwiftNativeStudioStore: Sendable {
    public static let logLabel = "StudioStore"

    public let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// `<dataRoot>/studio/`.
    public var studioRoot: URL {
        dataRoot.appendingPathComponent("studio", isDirectory: true)
    }

    /// `<dataRoot>/studio/journal/journal.jsonl`.
    public var journalPath: URL {
        studioRoot
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("journal.jsonl")
    }

    /// `<dataRoot>/studio/consults/`.
    public var consultsDirectory: URL {
        studioRoot.appendingPathComponent("consults", isDirectory: true)
    }

    /// `<dataRoot>/studio/journal/journal_archive_<stamp>.jsonl` — uncapped, byte-exact overflow per trim. Archive before trimming; journalHistory reads this shelf together with the hot journal.
    public func journalArchivePath(now: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return studioRoot
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("journal_archive_\(f.string(from: now)).jsonl")
    }

    /// Every overflow archive on the shelf, oldest stamp first. The combined journal reader uses this inventory for recall, encounter intake and work history.
    public func journalArchivePaths() throws -> [URL] {
        let directory = studioRoot.appendingPathComponent("journal", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("journal_archive_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `<dataRoot>/studio/consults/<id>.json`, for an id that has already been validated by `validatedIdentifier`.
    public func consultPath(id: String) throws -> URL {
        consultsDirectory.appendingPathComponent("\(try Self.validatedIdentifier(id)).json")
    }

    // MARK: Identifiers

    /// Studio ids are `<prefix>_<stamp>_<random>` and contain nothing that could escape the consults directory. Validated on the way in AND on the way out, because the read side takes an id straight from a model.
    static func validatedIdentifier(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw StudioError.invalidIdentifier(raw)
        }
        return trimmed
    }

    /// A stable, sortable, filename-safe id: `<prefix>_<yyyyMMddTHHmmss>_<hex>`.
    static func newIdentifier(prefix: String, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        let random = UUID().uuidString.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
        return "\(prefix)_\(f.string(from: now))_\(random)"
    }

    // MARK: Consults

    /// File a consult. Writes the envelope and NOTHING else: no journal entry, no retrieval, no suggested verdict. Returns the stored envelope so the caller sees exactly what was persisted, including its id.
    @discardableResult
    public func fileConsult(
        artifactRefs: [String],
        description: String?,
        portionAvailable: String?,
        question: String,
        projectContext: String?,
        stage: String?,
        constraints: String?,
        priorDiscussion: String?,
        descriptionOnly: Bool,
        now: Date = Date()
    ) async throws -> StudioConsult {
        let refs = artifactRefs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { throw StudioError.consultQuestionMissing }
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Without artifact refs, require an explicit description-only consult with a description.
        if refs.isEmpty {
            guard descriptionOnly else { throw StudioError.consultMissingDescriptionOnlyFlag }
            guard let trimmedDescription, !trimmedDescription.isEmpty else {
                throw StudioError.consultHasNothingToJudge
            }
        }
        let consult = StudioConsult(
            id: Self.newIdentifier(prefix: "consult", now: now),
            filedAt: NativeTimestampFormat.sixDigitUTCOffset(now),
            artifactRefs: refs,
            description: (trimmedDescription?.isEmpty == false) ? trimmedDescription : nil,
            portionAvailable: portionAvailable?.trimmingCharacters(in: .whitespacesAndNewlines),
            question: trimmedQuestion,
            projectContext: projectContext?.trimmingCharacters(in: .whitespacesAndNewlines),
            stage: stage?.trimmingCharacters(in: .whitespacesAndNewlines),
            constraints: constraints?.trimmingCharacters(in: .whitespacesAndNewlines),
            priorDiscussion: priorDiscussion?.trimmingCharacters(in: .whitespacesAndNewlines),
            // Refs present but declared description-only is honest and allowed: it can only make the consult LESS eligible, never more.
            descriptionOnly: descriptionOnly || refs.isEmpty
        )
        try await SwiftNativePersistenceCore.writeJSON(consult.toJSON(), to: try consultPath(id: consult.id))
        return consult
    }

    public func listConsults() async throws -> [StudioConsult] {
        let paths: [URL]
        do { paths = try FileManager.default.contentsOfDirectory(at: consultsDirectory, includingPropertiesForKeys: nil) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        var consults: [StudioConsult] = []
        for path in paths.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            consults.append(try await readConsult(id: path.deletingPathExtension().lastPathComponent))
        }
        return consults
    }

    /// Read one consult envelope back, verbatim.
    public func readConsult(id: String) async throws -> StudioConsult {
        _ = try Self.validatedIdentifier(id)
        guard let consult = try await consultIfExists(id: id) else {
            throw StudioError.unknownConsult(id)
        }
        return consult
    }

    /// The consult an arbitrary reference NAMES, or nil when it names no consult at all — an origin ref is "whatever identifies the source", so a desk handle, a URL, or a project name is a legitimate ref that simply is not a consult id. A
    /// ref that DOES resolve is returned whatever the entry claims its origin kind to be; a stored envelope that no longer decodes throws rather than passing as "not a consult".
    public func consultIfExists(id: String) async throws -> StudioConsult? {
        guard let path = try? consultPath(id: id),
              FileManager.default.fileExists(atPath: path.path) else { return nil }
        let raw = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .null)
        guard let consult = StudioConsult.fromJSON(raw) else {
            throw StudioError.malformedConsult(id)
        }
        return consult
    }

    // MARK: Journal

    /// Append ONE entry. There is deliberately no counterpart: no update, no delete, no rewrite. Revision happens through a later linked entry.  The append is DURABLE (F_FULLFSYNC before the descriptor closes) and runs through the path-
    /// owned cap registry, so the journal cannot be grown by a writer that skipped retention — see `jsonlPathOwnedCapPolicy`.
    @discardableResult
    public func appendJournalEntry(
        encounteredAt: String?,
        work: StudioWork,
        reception: StudioReception,
        artifactRefs: [String],
        origin: StudioOrigin,
        response: String?,
        stance: StudioStanceValue,
        relations: [StudioRelation],
        tags: [String],
        now: Date = Date()
    ) async throws -> StudioJournalEntry {
        guard !work.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioError.journalWorkTitleMissing
        }
        let trimmedResponse = response?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only an abstained stance may omit its response.
        if stance.kind != .abstained, (trimmedResponse ?? "").isEmpty {
            throw StudioError.journalResponseMissing
        }
        // A consult-origin entry must name its consult.
        if origin.kind == .consult, (origin.ref ?? "").isEmpty {
            throw StudioError.journalOriginConsultRequiresRef
        }
        // Refuse a description-only consult by the resolved reference, regardless of declared origin kind.
        if let ref = origin.ref, !ref.isEmpty,
           let consult = try await consultIfExists(id: ref) {
            if consult.descriptionOnly {
                throw StudioError.descriptionOnlyConsultCannotBecomeEncounter(consult.id)
            }
        } else if origin.kind == .consult, let ref = origin.ref {
            // kind=consult promises a consult; an unresolvable one is a claim we cannot check, so it fails rather than passing unverified.
            throw StudioError.unknownConsult(ref)
        }
        let recordedAt = NativeTimestampFormat.sixDigitUTCOffset(now)
        let encounterStamp: String
        if let encounteredAt, !encounteredAt.isEmpty { encounterStamp = encounteredAt }
        else { encounterStamp = recordedAt }
        let entry = StudioJournalEntry(
            id: Self.newIdentifier(prefix: "entry", now: now),
            encounteredAt: encounterStamp,
            recordedAt: recordedAt,
            work: work,
            reception: reception,
            artifactRefs: artifactRefs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            origin: origin,
            response: (trimmedResponse?.isEmpty == false) ? trimmedResponse : nil,
            stance: stance,
            relations: relations,
            tags: tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        try await appendPathOwnedJSONL(
            entry.toJSON(),
            to: journalPath,
            logLabel: Self.logLabel,
            durable: true,
            // ARCHIVE BEFORE TRIM. This hook runs inside the feed's flock and BEFORE the append, so a throw here means no append and no trim — a shelf that cannot be written is a reason to stop, never a reason to drop the oldest entries
            // quietly.
            beforePotentialLineCap: { try archiveJournalOverflowIfNeeded($0) }
        )
        return entry
    }

    /// Archive the cap owner's selected original rows before append or trim.
    private func archiveJournalOverflowIfNeeded(_ doomed: [Substring]?, now: Date = Date()) throws {
        guard let doomed else {
            throw PersistenceCoreError.ioFailure(
                "studio journal at \(journalPath.path) is not valid UTF-8 — refusing to trim it")
        }
        guard !doomed.isEmpty else { return }

        let directory = journalPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = journalArchivePath(now: now)
        // Raw BYTES, not re-serialized rows: the shelf has to hold exactly what the journal held, including a line this build could not decode.
        var payload = Data()
        for line in doomed {
            payload.append(contentsOf: line.utf8)
            payload.append(0x0A)
        }
        try SwiftNativePersistenceCore.appendOwnedBytes(payload, to: archive, durable: true)
        nativeLog("%@: journal cap reached — moved %d oldest line(s) to %@ before any trim",
              Self.logLabel, doomed.count, archive.lastPathComponent)
    }

    /// Every entry in file (append) order. The journal is a curated life record — a few entries a week, not telemetry — so reading it whole is honest and cheap; `recall` is what bounds what a caller sees.
    public func readJournal() async throws -> [StudioJournalEntry] {
        await applyAmendments(try await rawJournalEntries(path: journalPath).entries)
    }

    /// Usable entries and the holes beside them: damaged lines and rows this build cannot decode are counted, never silently absent.
    private func rawJournalEntries(path: URL) async throws -> (entries: [StudioJournalEntry], holes: [String]) {
        let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
        let entries = rows.compactMap { StudioJournalEntry.fromJSON($0) }
        let lost = report.malformedLineCount + rows.count - entries.count
        var holes = lost > 0 ? ["\(path.lastPathComponent): \(lost) line(s) could not be read as entries"] : []
        if report.trailingPartialLine { holes.append("\(path.lastPathComponent): its last line is torn (a write that had not landed whole)") }
        return (entries, holes)
    }

    // MARK: Amendments (0.4.14)

    /// `<dataRoot>/studio/journal/amendments.jsonl` — one row per correction.  NOT in the path-owned cap registry, and deliberately so: a cap trims the oldest rows, and trimming a correction would restore a claim she has already admitted
    /// is wrong. Like the trim receipts beside it, this file is written durably and never capped. It is tiny by construction — a correction is a rare deliberate act, not telemetry.
    public var journalAmendmentsPath: URL {
        studioRoot
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("amendments.jsonl")
    }

    /// What a read of `amendments.jsonl` got, and whether it got all of it.
    public struct AmendmentsRead: Sendable, Equatable {
        public var amendments: [StudioAmendment]
        /// The file exists and could NOT be read whole: a malformed line, or a row this build cannot decode, or the read itself failed. Which entry's correction was lost is unknowable, so this is a property of the read, not of one row.
        public var unreadable: Bool
        public init(amendments: [StudioAmendment], unreadable: Bool) {
            self.amendments = amendments
            self.unreadable = unreadable
        }
    }

    /// Every correction on file, append order, PLUS whether anything was lost. A row this build cannot decode is still skipped rather than thrown — an unreadable correction must not take the whole journal read down with it — but it is
    /// REPORTED, because a dropped correction silently resurrects the claim she has already admitted is wrong.
    public func readAmendmentsReporting() async throws -> AmendmentsRead {
        guard FileManager.default.fileExists(atPath: journalAmendmentsPath.path) else {
            return AmendmentsRead(amendments: [], unreadable: false)
        }
        let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(journalAmendmentsPath)
        let amendments = rows.compactMap { StudioAmendment.fromJSON($0) }
        // Malformed bytes, a torn trailing line, and a row that parsed as JSON but is not an amendment this build understands are all the same loss.
        let unreadable = !report.isClean || amendments.count != rows.count
        if unreadable {
            nativeLog("%@: journal/amendments.jsonl is damaged (%d malformed, %d undecodable rows) - entries will read as corrections-unreadable",
                  Self.logLabel, report.malformedLineCount, rows.count - amendments.count)
        }
        return AmendmentsRead(amendments: amendments, unreadable: unreadable)
    }

    /// Project the corrections onto the entries they name. This is what makes "append-only on disk, corrected everywhere it is read" true at once: the journal line is untouched, and every consumer that reads through the store sees the
    /// amendment attached to the entry.  An amendment naming an entry that is not in this slice is simply not attached here — it stays on file and attaches wherever that entry is read.
    func applyAmendments(_ entries: [StudioJournalEntry]) async -> [StudioJournalEntry] {
        guard !entries.isEmpty else { return entries }
        // A read failure is NOT "no corrections". Swallowing it here is what let a damaged amendments file serve a corrected claim as if it stood.
        let read: AmendmentsRead
        do { read = try await readAmendmentsReporting() }
        catch {
            nativeLog("%@: journal/amendments.jsonl could not be read (%@) - entries will read as corrections-unreadable",
                  Self.logLabel, String(describing: error))
            read = AmendmentsRead(amendments: [], unreadable: true)
        }
        guard !read.amendments.isEmpty || read.unreadable else { return entries }
        let byEntry = Dictionary(grouping: read.amendments, by: \.entryId)
        return entries.map { entry in
            var corrected = entry
            if let found = byEntry[entry.id], !found.isEmpty {
                corrected.amendments = found.sorted { $0.amendedAt < $1.amendedAt }
            }
            // A damaged file could have lost a correction for ANY entry in this slice, so every one of them carries the warning.
            corrected.correctionsUnreadable = read.unreadable
            return corrected
        }
    }

    /// File ONE correction against an entry that already exists.  Nothing in `journal.jsonl` is read-modify-written: the entry is read to VALIDATE the correction (the entry exists; a superseded passage really is in its response, exactly
    /// once), and then the amendment is appended to its own durable log. Returns the amendment and the entry as it now reads.
    @discardableResult
    public func appendJournalAmendment(
        entryId: String,
        reason: String,
        supersedes: String?,
        correction: String,
        now: Date = Date()
    ) async throws -> (amendment: StudioAmendment, entry: StudioJournalEntry) {
        let id = try Self.validatedIdentifier(entryId)
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else { throw StudioError.amendmentReasonMissing }
        let trimmedCorrection = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCorrection.isEmpty else { throw StudioError.amendmentCorrectionMissing }

        let entries = try await journalEntriesIncludingArchive()
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw StudioError.unknownJournalEntry(entryId)
        }
        var passage: String?
        if let supersedes {
            let trimmed = supersedes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard let response = entry.response, !response.isEmpty else {
                    throw StudioError.amendmentEntryHasNoResponse(id)
                }
                // Verbatim, and unambiguous. A passage that is not there, or is there twice, would have the correction land somewhere she did not name — silent rewriting by another route.
                let occurrences = response.components(separatedBy: trimmed).count - 1
                guard occurrences > 0 else { throw StudioError.amendmentPassageNotFound(trimmed) }
                guard occurrences == 1 else { throw StudioError.amendmentPassageNotUnique(trimmed) }
                passage = trimmed
            }
        }

        let amendment = StudioAmendment(
            id: Self.newIdentifier(prefix: "amend", now: now),
            entryId: id,
            amendedAt: NativeTimestampFormat.sixDigitUTCOffset(now),
            reason: trimmedReason,
            supersedes: passage,
            correction: trimmedCorrection
        )
        try FileManager.default.createDirectory(
            at: journalAmendmentsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try await SwiftNativePersistenceCore.withFileLock(journalAmendmentsPath) {
            let read = try await readAmendmentsReporting()
            guard !read.unreadable else {
                throw PersistenceCoreError.ioFailure("Journal corrections are unreadable; correction was not appended.")
            }
            let existing = read.amendments.filter { $0.entryId == id }
            // Recheck overlap under the append lock: another caller may have corrected this passage since the journal entry was read.
            if let passage = amendment.supersedes, let response = entry.response,
               let range = response.range(of: passage) {
                for correction in existing {
                    guard let taken = correction.supersedes,
                          let takenRange = response.range(of: taken),
                          takenRange.overlaps(range) else { continue }
                    throw StudioError.amendmentPassageOverlaps(
                        passage: passage, existingAmendmentID: correction.id, existingPassage: taken)
                }
            }
            try await SwiftNativePersistenceCore.appendJSONLDurable(amendment.toJSON(), to: journalAmendmentsPath)
            var corrected = entry
            corrected.amendments = (existing + [amendment]).sorted { $0.amendedAt < $1.amendedAt }
            return (amendment, corrected)
        }
    }

    /// Read oldest archives first, reporting unreadable or undecodable history as holes.
    private func archivedJournalEntries() async -> (entries: [StudioJournalEntry], holes: [String]) {
        let paths: [URL]
        do { paths = try journalArchivePaths() } catch {
            return ([], ["journal archive could not be listed: \(error.localizedDescription)"])
        }
        var out: [StudioJournalEntry] = [], holes: [String] = []
        for path in paths {
            do {
                let read = try await rawJournalEntries(path: path)
                out += read.entries
                holes += read.holes
            } catch {
                holes.append("\(path.lastPathComponent) could not be read: \(error.localizedDescription)")
            }
        }
        return (out, holes)
    }

    /// All journal entries, including archives; history holes throw and correction-read warnings remain visible.
    public func journalEntriesIncludingArchive() async throws -> [StudioJournalEntry] {
        try await completeJournalHistory(for: "Journal entry lookup")
    }

    /// Read archives and the hot journal under one flock, deduplicate, then project corrections. Report holes so callers cannot infer absence from incomplete history.
    public func journalHistory() async throws -> (entries: [StudioJournalEntry], holes: [String]) {
        try await SwiftNativePersistenceCore.withFileLock(journalPath) {
            let archive = await self.archivedJournalEntries()
            let hot = try await self.rawJournalEntries(path: self.journalPath)
            // A crash after archiving but before trimming leaves the same entry in both files. It is still one encounter, with one correction view.
            var seen = Set<String>()
            let entries = await self.applyAmendments((archive.entries + hot.entries).filter { seen.insert($0.id).inserted })
            return (entries, archive.holes + hot.holes)
        }
    }

    /// Absence cannot be concluded over holes in the history.
    private func completeJournalHistory(for claim: String) async throws -> [StudioJournalEntry] {
        let history = try await journalHistory()
        guard history.holes.isEmpty else {
            throw PersistenceCoreError.ioFailure("\(claim) needs the whole journal, and part of it is unreadable: "
                + history.holes.joined(separator: "; "))
        }
        return history.entries
    }

    // MARK: Encounter intake

    /// Every consult User left on the table that the journal never answered.  A candidate is a consult that (1) carries real artifact refs — so there IS a work to receive, the honest-encounter rule's whole point — and (2) has no journal
    /// entry naming it, either by origin ref or by sharing one of its refs. Description-only consults are excluded outright: they can never become an encounter, so they can never become an invitation to one.  Read-only. Nothing here opens
    /// a ref, and nothing here writes.
    public func namedEncounterIntake(limit: Int = 20,
        decide: @Sendable (JSONValue) async throws -> JSONValue) async throws -> [StudioEncounterCandidate] {
        let decision = try await decide(.object(["operation": .string("named"), "limit": .int(Int64(max(0, limit)))]))
        struct Selection: Decodable { let ids: [String] }
        let ids = try JSONDecoder().decode(Selection.self, from: decision.serializedData(pretty: false)).ids
        // Editable selection cannot turn a description or an answered consult into an honest encounter. Recheck truth after the part returns.
        let history = try await completeJournalHistory(for: "Which consults were never answered")
        let answered = Set(history.compactMap { $0.origin.ref })
        let refs = Set(history.flatMap(\.artifactRefs))
        let consults = try await listConsults()
        guard ids.count <= max(0, limit), Set(ids).count == ids.count else {
            throw PersistenceCoreError.ioFailure("Studio intake returned duplicate or excess consults.")
        }
        return try ids.map { id in
            guard let consult = consults.first(where: { $0.id == id }), !consult.descriptionOnly,
                  !consult.artifactRefs.isEmpty, !answered.contains(id), refs.isDisjoint(with: consult.artifactRefs) else {
                throw PersistenceCoreError.ioFailure("Studio intake selected a consult without an unanswered artifact: \(id).")
            }
            return StudioEncounterCandidate(source: .named, reference: consult.artifactRefs.first,
                originID: id, noticedAt: consult.filedAt)
        }
    }

    /// Neutral, corrected history facts and consult facts, paged from one content epoch. A changed epoch refuses continuation; no mixed-history absence claim and no retained second store. Missing is empty; corrupt consults and incomplete
    /// archive history throw, never disappear.
    public func encounterIntakePage(kind: String, offset: Int, snapshot: String?) async throws -> JSONValue {
        let history = try await completeJournalHistory(for: "Which consults were never answered")
        let consults = try await listConsults()
        let packets: [String: [JSONValue]] = [
            "history": history.map { .object(["id": .string($0.id), "origin_ref": $0.origin.ref.map(JSONValue.string) ?? .null,
                "artifact_refs": .array($0.artifactRefs.map(JSONValue.string))]) },
            "consults": consults.map { .object(["id": .string($0.id), "filed_at": .string($0.filedAt),
                "description_only": .bool($0.descriptionOnly), "artifact_refs": .array($0.artifactRefs.map(JSONValue.string))]) },
        ]
        guard let rows = packets[kind], offset >= 0, offset <= rows.count else {
            throw PersistenceCoreError.ioFailure("Read history or consults with an offset within that snapshot.")
        }
        let frozen = JSONValue.object(packets.mapValues(JSONValue.array))
        let digest = SHA256.hash(data: try frozen.serializedData(pretty: false)).map { String(format: "%02x", $0) }.joined()
        guard snapshot == nil && offset == 0 || snapshot == digest else {
            throw PersistenceCoreError.ioFailure("Studio history changed during intake. No unanswered-work decision was made.")
        }
        // Bound each page by bytes as well as rows: no host-return truncation.
        var page: [JSONValue] = [], bytes = 0
        for row in rows.dropFirst(offset).prefix(100) {
            let size = try row.serializedData(pretty: false).count
            guard size <= 256_000 else { throw PersistenceCoreError.ioFailure("A Studio intake fact exceeds the page limit.") }
            if bytes + size > 256_000 { break }
            page.append(row); bytes += size
        }
        let next = offset + page.count
        return .object(["status": .string("ok"), "snapshot": .string(digest), "rows": .array(page),
            "next_offset": next < rows.count ? .int(Int64(next)) : .null])
    }

    /// Identities answered anywhere in the complete journal history, including archives.
    public func journaledWorkIdentities() async throws -> Set<String> {
        Set(try await completeJournalHistory(for: "Which works were never journaled").map {
            Self.journaledWorkIdentity(title: $0.work.title, creator: $0.work.creator)
        })
    }

    /// Shared creator-sensitive work identity for journal and graph intake.
    public static func journaledWorkIdentity(title: String, creator: String?) -> String {
        func fold(_ value: String) -> String {
            value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Length-prefix both folded components to prevent delimiter collisions; this key is not persisted.
        let foldedTitle = fold(title)
        let foldedCreator = fold(creator ?? "")
        return "\(foldedTitle.count)|\(foldedTitle)|\(foldedCreator.count)|\(foldedCreator)"
    }

    /// Read-only search. Returns matching entries VERBATIM, newest first, capped by `query.limit`, with an explicit `hasMore`. No scoring, no ranking, and nothing calls this on the agent's behalf.
    public func recall(_ query: StudioRecallQuery) async throws -> StudioRecallResult {
        let (entries, holes) = try await journalHistory()
        let matches = entries.reversed().filter { Self.matches($0, query) }
        let bounded = Array(matches.prefix(query.limit))
        return StudioRecallResult(
            entries: bounded,
            matchedCount: matches.count,
            hasMore: matches.count > bounded.count,
            correctionsUnreadable: entries.contains(where: \.correctionsUnreadable),
            historyUnreadable: holes
        )
    }

    static func matches(_ entry: StudioJournalEntry, _ query: StudioRecallQuery) -> Bool {
        func fold(_ s: String) -> String {
            s.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
        func contains(_ haystack: String?, _ needle: String?) -> Bool {
            guard let needle, !needle.isEmpty else { return true }
            guard let haystack else { return false }
            return fold(haystack).contains(fold(needle))
        }
        guard contains(entry.work.title, query.title) else { return false }
        guard contains(entry.work.creator, query.creator) else { return false }
        guard contains(entry.work.medium, query.medium) else { return false }
        if let tag = query.tag, !tag.isEmpty {
            guard entry.tags.contains(where: { fold($0) == fold(tag) }) else { return false }
        }
        if let kind = query.relationKind {
            guard entry.relations.contains(where: { $0.kind == kind }) else { return false }
        }
        if let relatedTo = query.relatedTo, !relatedTo.isEmpty {
            guard entry.relations.contains(where: { $0.entryId == relatedTo }) else { return false }
        }
        if let text = query.text, !text.isEmpty {
            // Free text reads the whole entry, response included — the response is the point, so it must be searchable in its own words.
            let haystack = [
                entry.id, entry.work.title, entry.work.creator ?? "", entry.work.medium ?? "",
                entry.response ?? "", entry.stance.reason ?? "",
                entry.reception.how ?? "", entry.reception.wholeOrPart ?? "",
                entry.tags.joined(separator: " "),
                entry.artifactRefs.joined(separator: " "),
                // Corrections are part of what the entry now says, so they are searchable in their own words too.
                entry.amendments.map { "\($0.reason) \($0.correction)" }.joined(separator: " "),
            ].joined(separator: " ")
            guard fold(haystack).contains(fold(text)) else { return false }
        }
        return true
    }
}
