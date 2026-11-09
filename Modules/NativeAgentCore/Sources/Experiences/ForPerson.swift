import Foundation
import NativeAgentCore
import os
// Blueprint: | `ForPerson.swift` | `Matter`, `Door`, `ForPerson`: the person's matters, deliveries, reading and inbox wire |

/// Something for the person (step 4 §2.4): one experience addressed to `person`. Its row is its face on every door; an ask owes the person's `decide`; each
/// of the person's doors owes `deliver:<door>`.
public struct Matter: Sendable, Equatable {
    /// Two facts replace importance: does it need the person's answer, and did something go wrong
    /// (which breaks quiet hours). The router separately verifies the person's current request for a pinned door.
    public enum Form: Sendable, Equatable {
        case words, ask, done, wentWrong

        var tone: PartFace.Tone {
            switch self {
            case .words: .plain
            case .ask: .attention
            case .done: .done
            case .wentWrong: .failed
            }
        }
    }

    /// The happening; telling it again refreshes its face and never reaches the person a second time.
    public let id: String
    public let form: Form
    /// The part that tells the person: the wire's `source`.
    public let from: String
    public let title: String
    public let summary: String
    /// What the text doors say (Telegram, the agent's conversation): the long words.
    public let words: String
    public let symbol: String?
    public let badge: String?
    /// Where the row leads, in the face vocabulary (`chat:<session>`, `approval:<id>`, `page:<page>`).
    public let open: String?
    /// An ask's answers.
    public let choices: [PartFace.Action]
    public let evidence: [Experience.Ref]
    public let artifacts: [Experience.Ref]

    public init(id: String, form: Form, from: String, title: String, summary: String, words: String? = nil, symbol: String? = nil,
                badge: String? = nil, open: String? = nil, choices: [PartFace.Action] = [], evidence: [Experience.Ref] = [],
                artifacts: [Experience.Ref] = []) {
        (self.id, self.form, self.from, self.title, self.summary) = (id, form, from, title, summary)
        (self.words, self.symbol, self.badge, self.open) = (words ?? summary, symbol, badge, open)
        (self.choices, self.evidence, self.artifacts) = (choices, evidence, artifacts)
    }

    /// The stores a matter's evidence names, so the wire reads them in one place.
    public static let approvals = "workflows/approvals/requests.json"
    public static let delegations = "delegations"
    public static let files = "file"
    public static let conversations = "chat/messages/"
    public static func messages(_ session: String) -> String { conversations + session }

    /// Its birth, the one shape every owner writes (an owner that births inside its own record chain uses this, never its own shape).
    public func born(doors: [Door]) -> Experience {
        var owes = Dictionary(uniqueKeysWithValues: doors.map { ($0.key, Experience.Obligation(to: $0.address)) })
        if form == .ask { owes["decide"] = .init(to: ForPerson.person) }
        return Experience(id: id, kind: form == .ask ? .decision : .message, evidence: evidence,
                          face: face(at: NativeTimestampFormat.fractionalZulu(Date())), addressedTo: [ForPerson.person], owes: owes)
    }

    func face(at: String) -> Experience.Face {
        Experience.Face(words: words, artifacts: artifacts, row: PartFace.Row(id: id, title: title, detail: summary, value: badge, at: at,
                        symbol: symbol, tone: form.tone, open: open, actions: choices.isEmpty ? nil : choices), from: from)
    }
}

/// One of the person's doors. Its obligation key is `deliver:<surface>`; its address is the obligation's `to`.
public enum Door: Hashable, Sendable {
    case phone, mac
    case telegram(chat: String, thread: String?)
    case slack(channel: String, thread: String?)
    case conversation(String)

    /// The person's doors: the phone always, the thread it came from, and the Mac, which is let go at send time
    /// when the person is not at it.
    public static func person(thread: Door?) -> [Door] { [.phone] + [thread].compactMap { $0 } + [.mac] }

    public var key: String { "deliver:" + surface }

    public var surface: String {
        switch self {
        case .phone: "phone"
        case .mac: "mac"
        case .telegram: "telegram"
        case .slack: "slack"
        case .conversation: "conversation"
        }
    }

    public var address: String {
        switch self {
        case .phone, .mac: surface
        case .telegram(let place, let thread), .slack(let place, let thread): ([surface, place] + [thread].compactMap { $0 }).joined(separator: ":")
        case .conversation(let session): "conversation:" + session
        }
    }

    /// The one reading of an obligation's `to`.
    public init?(address: String) {
        let parts = address.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        var values = parts.makeIterator()
        switch (values.next(), values.next(), values.next()) {
        case ("phone", nil, nil): self = .phone
        case ("mac", nil, nil): self = .mac
        case ("telegram", .some(let place), let thread): self = .telegram(chat: place, thread: thread)
        case ("slack", .some(let place), let thread): self = .slack(channel: place, thread: thread)
        case ("conversation", .some, _): self = .conversation(String(address.dropFirst("conversation:".count)))
        default: return nil
        }
    }
}

/// What is for the person, held in memory: every experience addressed to `person` that is open or settled in the last 30 days (newest 500).
/// Loaded once from the record; its own writes feed it before they return, and other owners' writes reach it through the store's write stream.
public actor ForPerson {
    public enum Reading: String, Sendable { case unread, read, archived, dismissed }
    /// Put away by the person (archived, dismissed) or by its owner (resolved).
    public enum PutAway: String, Sendable { case archived, dismissed, resolved }
    public enum Filed: Sendable, Equatable { case born, refreshed, unchanged, settled }

    public struct Attempt: Sendable, Equatable {
        public let matter: String
        public let door: Door
        public let id: String
    }

    public static let person = "person"
    static let horizon: TimeInterval = 30 * 24 * 60 * 60
    static let bound = 500
    private static let owners = OSAllocatedUnfairLock(initialState: [URL: ForPerson]())

    public static func at(_ root: URL) -> ForPerson {
        let key = root.standardizedFileURL
        return owners.withLock { owners in
            if let owner = owners[key] { return owner }
            let owner = ForPerson(root: key)
            owners[key] = owner
            return owner
        }
    }

    public nonisolated let root: URL
    private var reading: [String: Experience] = [:]
    /// The phone's canonical event id for each matter in the reading, so a receipt finds its matter without a query.
    private var byPhoneEvent: [String: String] = [:]
    private var loaded: Task<Result<Void, Error>, Never>?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    private init(root: URL) { self.root = root }

    // MARK: - The reading

    /// Newest first. An unreadable record fails the read; it never reads as nothing for the person.
    public func matters() async throws -> [Experience] {
        try await load()
        return reading.values.sorted { ($0.at, $0.id) > ($1.at, $1.id) }
    }

    public func matter(_ id: String) async throws -> Experience? {
        try await load()
        return reading[id]
    }

    /// The 64-hex id the phone carries for a matter (its alerts, receipts and actions only accept canonical ids).
    public nonisolated static func phoneEvent(_ id: String) -> String {
        NativeAgentDeviceEventIdentity.notification(userInfo: ["itemId": id])
    }

    public func matter(phoneEvent event: String) async throws -> Experience? {
        try await load()
        return byPhoneEvent[event.lowercased()].flatMap { reading[$0] }
    }

    /// The inbox wire, the same for the Mac and the phone's `inbox.json`. The inbox is a reading, never a copy of a conversation: a matter is a row
    /// when it asks the person, when something went wrong, or when it has no thread; words or a done whose thread is a conversation live there (its doors
    /// still reach the person's phone).
    public func inbox() async throws -> [InboxItemRecord] {
        try await matters().filter { Self.isRow($0) }.compactMap(Self.card)
    }

    public static func isRow(_ matter: Experience) -> Bool {
        matter.owes["decide"] != nil || matter.face?.row?.tone == .failed || thread(matter) == nil
    }

    /// The thread it came from: a conversation, Telegram or Slack door, or the chat its row leads to.
    public static func thread(_ matter: Experience) -> Door? {
        let doors = matter.owes.values.compactMap { Door(address: $0.to) }.filter { $0 != .phone && $0 != .mac }
        if let door = doors.sorted(by: { $0.address < $1.address }).first { return door }
        guard let open = matter.face?.row?.open, open.hasPrefix("chat:") else { return nil }
        return .conversation(String(open.dropFirst(5)))
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(())
            continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        }
    }

    /// Deliveries the router still owes, oldest first (a conversation's door is its owner's); `retrying` adds the ones a door refused.
    public func owed(retrying: Bool = false) async throws -> [(matter: Experience, door: Door)] {
        try await matters().reversed().flatMap { matter in
            matter.owes.compactMap { key, owed -> (matter: Experience, door: Door)? in
                guard key.hasPrefix("deliver:"), owed.phase == .owed || retrying && owed.phase == .rejected,
                      let door = Door(address: owed.to), door.surface != "conversation" else { return nil }
                return (matter, door)
            }
        }
    }

    public static func reading(_ matter: Experience) -> Reading {
        if let outcome = matter.outcome {
            return outcome.domain == person && outcome.status == Reading.dismissed.rawValue ? .dismissed : .archived
        }
        if matter.owes["decide"]?.phase.isSettled == true { return .archived }
        return matter.progress == Reading.read.rawValue ? .read : .unread
    }

    // MARK: - Telling the person

    /// Births the matter with its doors (fixed at birth), or refreshes the face of the one already told. A matter the person or its owner settled is not
    /// told again: a new happening mints a new id.
    @discardableResult
    public func tell(_ matter: Matter, doors: [Door]) async throws -> Filed {
        if let open = matter.open, !PartFace.isLink(open) {
            throw ToolFailureError("A matter's row leads only to a face link (chat:, page:, approval:, card:, dream:, url:https://, url:http://); "
                + "\(open) is none.",
                                   effects: .none, owner: "experiences:" + matter.id)
        }
        try await load()
        let filed = OSAllocatedUnfairLock(initialState: Filed.unchanged)
        try await write(matter.id) { store in
            guard let current = try await store.experience(matter.id) else {
                try await store.begin(matter.born(doors: doors))
                filed.withLock { $0 = .born }
                return
            }
            guard Self.reading(current) != .archived, Self.reading(current) != .dismissed else { filed.withLock { $0 = .settled }; return }
            let face = matter.face(at: current.face?.row?.at ?? current.at)
            guard current.face != face else { return }
            try await store.append([.face(face)], to: matter.id)
            filed.withLock { $0 = .refreshed }
        }
        return filed.withLock { $0 }
    }

    // MARK: - The person's reading

    /// An owner's later outcome revises the existing face, including history, without reopening consent or owing a second delivery.
    @discardableResult
    public func updateFace(_ matter: Matter) async throws -> Filed {
        try await load()
        let filed = OSAllocatedUnfairLock(initialState: Filed.unchanged)
        try await write(matter.id) { store in
            guard let current = try await store.experience(matter.id) else {
                throw ToolFailureError("The matter to update does not exist.", effects: .none, owner: matter.id)
            }
            let face = matter.face(at: current.face?.row?.at ?? current.at)
            guard face != current.face else { return }
            try await store.append([.face(face)], to: matter.id)
            filed.withLock { $0 = .refreshed }
        }
        return filed.withLock { $0 }
    }

    public func read(_ id: String) async throws {
        try await write(id) { store in
            guard let current = try await store.experience(id), Self.reading(current) == .unread else { return }
            try await store.append([.progress(Reading.read.rawValue)], to: id)
        }
    }

    /// Putting it away lets go everything still owed: every delivery, and an ask nothing else answers (an approval or an interaction is
    /// declined through its resolve before its card is put away, so its `decide` is already settled here).
    public func putAway(_ id: String, _ how: PutAway) async throws {
        try await write(id) { store in
            guard let current = try await store.experience(id), current.outcome == nil else { return }
            let domain = how == .resolved ? current.face?.from ?? Self.person : Self.person
            let outcome = Experience.Outcome(domain: domain, status: how.rawValue, at: NativeTimestampFormat.fractionalZulu(Date()))
            let ask: [ExperienceStore.Change] = current.owes["decide"]?.phase.isSettled == false ? [.letGo(key: "decide", reason: .cancelled)] : []
            try await store.append([.outcome(outcome)] + ask + Self.unsettledDeliveries(current).map { .letGo(key: $0, reason: .cancelled) }, to: id)
        }
    }

    /// The ask's own owner saw it answered where it lives (the Desk, its card), or gave it up; the doors still owed let it go with it.
    public func answered(_ id: String, evidence: Experience.Ref?, letGo reason: ObligationPhase.LetGo = .abandoned) async throws {
        try await write(id) { store in
            guard let current = try await store.experience(id), current.owes["decide"]?.phase.isSettled == false else { return }
            let settle: ExperienceStore.Change = evidence.map { .obligation(key: "decide", phase: .accepted, evidence: $0) }
                ?? .letGo(key: "decide", reason: reason)
            try await store.append([settle] + Self.unsettledDeliveries(current).map { .letGo(key: $0, reason: .cancelled) }, to: id)
        }
    }

    // MARK: - The person's doors

    /// Durable before the transport runs: a door owed or refused is reserved under a new attempt, unless the matter is already answered or put away.
    public func reserve(_ id: String, _ door: Door) async throws -> Attempt? {
        let attempt = Attempt(matter: id, door: door, id: UUID().uuidString.lowercased())
        let won = OSAllocatedUnfairLock(initialState: false)
        try await write(id) { store in
            guard let current = try await store.experience(id), current.outcome == nil, current.owes["decide"]?.phase.isSettled != true,
                  let owed = current.owes[door.key], owed.phase == .owed || owed.phase == .rejected else { return }
            try await store.append([.obligation(key: door.key, phase: .reserved, attempt: attempt.id)], to: id)
            won.withLock { $0 = true }
        }
        return won.withLock { $0 } ? attempt : nil
    }

    public func started(_ attempt: Attempt) async throws {
        try await write(attempt.matter) { store in
            try await store.append([.obligation(key: attempt.door.key, phase: .dispatchStarted, attempt: attempt.id)], to: attempt.matter)
        }
    }

    /// The transport's verdict: accepted, rejected or outcome_unknown. A receipt that landed first already settled it.
    public func finished(_ attempt: Attempt, _ phase: ObligationPhase) async throws {
        try await write(attempt.matter) { store in
            guard let owed = try await store.experience(attempt.matter)?.owes[attempt.door.key], !owed.phase.isSettled,
                  owed.attempt == attempt.id else { return }
            try await store.append([.obligation(key: attempt.door.key, phase: phase, attempt: attempt.id)], to: attempt.matter)
        }
    }

    /// The door's own receipt is the truth whenever it lands.
    public func accepted(_ id: String, _ door: Door, evidence: Experience.Ref) async throws {
        try await write(id) { store in
            guard let owed = try await store.experience(id)?.owes[door.key], !owed.phase.isSettled else { return }
            try await store.append([.obligation(key: door.key, phase: .accepted, attempt: owed.attempt, evidence: evidence)], to: id)
        }
    }

    /// The person's preference closed this door, or its owner gave up on it.
    public func letGo(_ id: String, _ door: Door, _ reason: ObligationPhase.LetGo) async throws {
        try await write(id) { store in
            guard try await store.experience(id)?.owes[door.key] != nil else { return }
            try await store.append([.letGo(key: door.key, reason: reason)], to: id)
        }
    }

    // MARK: - Fed at write

    /// One record read on first use; the write stream, opened before that read so no write falls between them, keeps it after that.
    private func load() async throws {
        if loaded == nil {
            let store = ExperienceStore.at(root)
            loaded = Task {
                let written = await store.written(addressedTo: Self.person)
                do {
                    let recent = try await store.addressed(to: Self.person, after: Date().addingTimeInterval(-Self.horizon), limit: Self.bound)
                    for matter in try await recent + store.open() where matter.addressedTo.contains(Self.person) { feed(matter) }
                } catch { return .failure(error) }
                Task { for await matter in written { await self.feed(matter) } }
                return .success(())
            }
        }
        guard let loaded else { return }
        if case .failure(let error) = await loaded.value {
            self.loaded = nil
            throw error
        }
    }

    /// An answer anywhere closes it everywhere: once the person's `decide` settles, the doors still owed let it go.
    private func feed(_ matter: Experience) {
        if let held = reading[matter.id], (held.updatedAt ?? held.at) > (matter.updatedAt ?? matter.at) { return }
        // The write stream and the writer's readback meet here. An unchanged matter is no change, including a no-op tell/answer.
        guard reading[matter.id] != matter else { return }
        reading[matter.id] = matter
        byPhoneEvent[Self.phoneEvent(matter.id)] = matter.id
        if matter.owes["decide"]?.phase.isSettled == true, !Self.unsettledDeliveries(matter).isEmpty {
            let root = root
            ExperienceStore.record(root, matter.id) { store in
                guard let current = try await store.experience(matter.id) else { return }
                let keys = Self.unsettledDeliveries(current)
                if !keys.isEmpty { try await store.append(keys.map { .letGo(key: $0, reason: .cancelled) }, to: matter.id) }
            }
        }
        if reading.count > Self.bound {
            let settled = reading.values.filter { !$0.isOpen }.sorted { ($0.updatedAt ?? $0.at) < ($1.updatedAt ?? $1.at) }
            for old in settled.prefix(reading.count - Self.bound) {
                reading[old.id] = nil
                byPhoneEvent[Self.phoneEvent(old.id)] = nil
            }
        }
        for observer in observers.values { observer.yield(()) }
    }

    /// Ordered with every other owner's writes to the same experience; the reading takes the result before the call returns.
    private func write(_ id: String, _ body: @escaping @Sendable (ExperienceStore) async throws -> Void) async throws {
        try await load()
        let failure = OSAllocatedUnfairLock<Error?>(initialState: nil)
        await ExperienceStore.record(root, id) { store in
            do { try await body(store) } catch {
                failure.withLock { $0 = error }
                throw error
            }
        }.value
        if let error = failure.withLock({ $0 }) { throw error }
        if let fresh = try await ExperienceStore.at(root).experience(id), fresh.addressedTo.contains(Self.person) { feed(fresh) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private static func unsettledDeliveries(_ matter: Experience) -> [String] {
        matter.owes.filter { $0.key.hasPrefix("deliver:") && !$0.value.phase.isSettled }.map(\.key).sorted()
    }

    // MARK: - The wire

    /// A matter with a row is a card; the wire keeps the shape the person's phones already read.
    static func card(_ matter: Experience) -> InboxItemRecord? {
        guard let face = matter.face, let row = face.row, let from = face.from else { return nil }
        let reading = reading(matter)
        let ask = matter.owes["decide"] != nil
        let interaction = matter.evidence.first { $0.source.hasPrefix(Matter.conversations) }
        let conversation = matter.owes.values.lazy.compactMap { Door(address: $0.to) }.compactMap { door -> String? in
            if case .conversation(let session) = door { return session }
            return nil
        }.first
        var card = InboxItemRecord(
            id: matter.id, created_at: matter.at, source: from,
            severity: ask ? "actionable" : row.tone == .failed ? "critical" : "info",
            title: row.title, summary: row.detail ?? "", detail: face.words == row.detail ? nil : face.words,
            relatedWorkshopExecutionId: nil,
            related_approval_id: matter.evidence.first { $0.source == Matter.approvals }?.id,
            related_paths: Optional(face.artifacts.filter { $0.source == Matter.files }.map(\.id)).flatMap { $0.isEmpty ? nil : $0 },
            related_groups: nil,
            actions: (row.actions ?? []).map { InboxActionRecord(id: $0.id, label: $0.label, description: nil) },
            status: reading.rawValue, read_at: reading == .unread ? nil : matter.updatedAt,
            chat_session_id: conversation,
            presentation: InboxSourcePresentation(icon: row.symbol ?? "bell.fill", badge: row.value ?? from.uppercased(),
                                                  words: words(ask: ask, tone: row.tone), actLabel: nil),
            interaction_session_id: interaction.map { String($0.source.dropFirst(Matter.conversations.count)) },
            interaction_id: interaction?.id)
        card.relatedDelegationID = matter.evidence.first { $0.source == Matter.delegations }?.id
        return card
    }

    private static func words(ask: Bool, tone: PartFace.Tone?) -> String {
        if ask { return "Asking you" }
        switch tone {
        case .failed: return "Something went wrong"
        case .done: return "Done"
        default: return "A note from me"
        }
    }
}
