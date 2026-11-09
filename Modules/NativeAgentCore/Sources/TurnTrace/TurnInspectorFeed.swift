import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Experiences
// Blueprint: | `TurnInspectorFeed.swift` | Actor-owned checked evidence, grouping, selection-keyed faces and phone summaries through LatestRead |

/// Mac cards and phone summaries share the persisted evidence and its sequence cursor.
public actor TurnInspectorFeed {
    private var groups: [TurnTraceGroup] = []
    private var lastSeq: Int64?
    private var readIssue: String?
    private var hasRead = false
    private let latestRead = LatestRead()
    public var observationActive: Bool { watcher?.isArmed == true }

    private let lane: TurnTracePersistLane
    private var watcher: FileChangeWatcher?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private struct Reader { var cutoff: Date?; var live = true; var face: InspectorFace? }
    private var readers: [UUID: Reader] = [:]
    private var replays: [Date: InspectorFace] = [:]
    private var replayReads: [Date: LatestRead] = [:]
    private let publication: AsyncStream<(FaceKey, InspectorFace)>.Continuation
    private let publishing: Task<Void, Never>

    public init(dataRootOverride: URL? = nil, feed: FaceFeedSource) {
        lane = TurnTracePersistLane(dataRootOverride: dataRootOverride)
        let (stream, continuation) = AsyncStream.makeStream(of: (FaceKey, InspectorFace).self)
        publication = continuation
        publishing = Task.detached {
            for await (key, value) in stream { await feed.post(value, at: key) }
        }
    }

    isolated deinit {
        watcher?.cancel()
        refreshTask?.cancel()
        publication.finish()
    }

    public func start() {
        guard watcher == nil else { return }
        let database = lane.resolvedDataRoot().appendingPathComponent("experiences/experiences.sqlite")
        watcher = FileChangeWatcher(paths: [
            database, URL(fileURLWithPath: database.path + "-wal"), database.deletingLastPathComponent(),
        ], onFailure: { [weak self] _ in Task { await self?.publishObservationState() } }) { [weak self] _ in
            Task { await self?.scheduleRefresh() }
        }
        scheduleRefresh()
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        refreshTask?.cancel()
        refreshRequested = false
        publishObservationState()
    }

    public func rearmObservation() {
        guard !observationActive else { return }
        stop()
        start()
    }

    public func showLive(reader id: UUID, after cutoff: Date?) {
        guard !Task.isCancelled else { return }
        start()
        // A new cutoff is a new key: its first face is always published.
        let previous = readers[id].flatMap { $0.cutoff == cutoff ? $0.face : nil }
        readers[id] = Reader(cutoff: cutoff, face: previous)
        publishLive(id)
    }

    public func removeReader(_ id: UUID) {
        readers.removeValue(forKey: id)
    }

    /// A capture reads persisted evidence without holding a live view subscription.
    public func readLive(after cutoff: Date?) async throws -> InspectorFace {
        _ = try await readGroups().get()
        return liveFace(after: cutoff, requiresObservation: false)
    }

    public func showReplay(for date: Date, reader id: UUID) async {
        guard !Task.isCancelled else { return }
        start()
        readers[id] = Reader(cutoff: nil, live: false, face: nil)
        await loadReplay(for: date, reader: id)
    }

    private func publishLive(_ id: UUID) {
        guard let reader = readers[id], reader.live else { return }
        let face = liveFace(after: reader.cutoff)
        guard reader.face != face else { return }
        readers[id]?.face = face
        publication.yield((.inspector(after: reader.cutoff), face))
    }

    private func liveFace(after cutoff: Date?, requiresObservation: Bool = true) -> InspectorFace {
        var face = InspectorFace()
        face.observationActive = observationActive
        let observationIssue = requiresObservation && !observationActive ? "Inspector cannot observe changes to its persisted traces." : nil
        let issues = [readIssue, observationIssue].compactMap { $0 }
        face.issue = issues.isEmpty ? nil : issues.joined(separator: "\n")
        face.status = face.issue == nil ? (hasRead ? .ready : .reading) : .failed
        let cards: [InspectorTurnCard]
        if let cutoff {
            let now = Date()
            cards = TurnInspectorGrouping.group(groups.flatMap(\.events).filter { $0.ts > cutoff && $0.ts <= now })
        } else { cards = TurnInspectorGrouping.cards(TurnSummarySource.visibleGroups(groups)) }
        face.ids = cards.map(\.id)
        for card in cards { face.cards[card.id] = card }
        return face
    }

    /// The selection and persisted reader use the same day boundary, regardless of a picker's time of day.
    public nonisolated static func replayDay(for date: Date) -> Date {
        TurnTracePersistLane.dayCalendar.startOfDay(for: date)
    }

    /// Replay keeps its loaded date with the cards; a newer request cannot relabel retained evidence.
    public func loadReplay(for date: Date, reader id: UUID) async {
        guard !Task.isCancelled, readers[id] != nil else { return }
        let date = Self.replayDay(for: date)
        let gate: LatestRead
        if let existing = replayReads[date] { gate = existing }
        else { gate = LatestRead(); replayReads[date] = gate }
        var face = replays[date] ?? InspectorFace()
        face.status = .reading; face.requestedDate = date; face.issue = nil
        gate.write { publishReplay(face, for: date) }
        _ = await gate.read({ () -> Result<(hasEvidence: Bool, unreadable: Int, cards: [InspectorTurnCard]), Error> in
            do { return .success(try await readReplay(for: date)) }
            catch { return .failure(error) }
        }, publish: { result in
            guard readers[id] != nil else { return }
            var next = replays[date] ?? face
            switch result {
            case .success(let read):
                next.status = .ready; next.issue = nil; next.loadedDate = date
                next.ids = read.cards.map(\.id)
                next.cards = [:]
                for card in read.cards { next.cards[card.id] = card }
                next.hasEvidence = read.hasEvidence; next.unreadable = read.unreadable
            case .failure(let error): next.status = .failed; next.issue = error.localizedDescription
            }
            publishReplay(next, for: date)
        })
    }

    private func publishReplay(_ face: InspectorFace, for day: Date) {
        var face = face
        face.observationActive = observationActive
        guard replays[day] != face else { return }
        replays[day] = face
        publication.yield((.inspectorReplay(day: day), face))
    }

    private func publishObservationState() {
        for id in Array(readers.keys) { publishLive(id) }
        for (day, face) in replays { publishReplay(face, for: day) }
    }

    private func readReplay(for date: Date) async throws -> (hasEvidence: Bool, unreadable: Int, cards: [InspectorTurnCard]) {
        let calendar = TurnTracePersistLane.dayCalendar
        let from = calendar.startOfDay(for: date)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: from) else { throw CocoaError(.fileReadUnknown) }
        let through = Date(timeIntervalSince1970: nextDay.timeIntervalSince1970.nextDown)
        let read = try await TurnTraceReplayReader.read(.init(from: from, through: through), root: lane.resolvedDataRoot())
        let events = read.events.filter { $0.ts < nextDay && $0.turnId != "unknown" }
        return (!events.isEmpty || read.unreadable > 0, read.unreadable, TurnInspectorGrouping.group(events))
    }

    public func summaryData() async -> Data? {
        start()
        let result = await readGroups()
        guard case .success(let groups) = result else { return nil }
        do { return try TurnSummaryComputer.compute(from: TurnSummarySource.visibleGroups(groups)) }
        catch {
            readIssue = error.localizedDescription
            publishObservationState()
            return nil
        }
    }

    private func readGroups() async -> Result<[TurnTraceGroup], Error> {
        let result: Result<(groups: [TurnTraceGroup], lastSeq: Int64?, changed: Bool), Error> = await latestRead.read {
            do { return .success(try await TurnSummarySource.readNewGroups(root: lane.resolvedDataRoot(), groups: groups, after: lastSeq)) }
            catch { return .failure(error) }
        } publish: { result in
            switch result {
            case .success(let read):
                if read.changed { groups = read.groups }
                lastSeq = read.lastSeq
                readIssue = nil
                hasRead = true
            case .failure(let error): readIssue = error.localizedDescription
            }
            publishObservationState()
        }
        return result.map(\.groups)
    }

    private func scheduleRefresh() {
        refreshRequested = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in await self?.drainRefreshes() }
    }

    private func drainRefreshes() async {
        defer { refreshTask = nil; if refreshRequested { scheduleRefresh() } }
        while refreshRequested, !Task.isCancelled {
            refreshRequested = false
            _ = await readGroups()
        }
    }
}
