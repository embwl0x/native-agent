import NativeAgentShared
import Foundation
import SwiftUI
import Observation

// Blueprint: | `InspectorView.swift` | Selected Inspector faces, held view/subscription identities and checked source-health replies |


struct InspectorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @State private var store = TurnInspectorStore()
    @State private var session = FacePageSession()
    private var slot: FaceSlot {
        appModel.face.slot(store.mode == .replay ? .inspectorReplay(day: store.replayDate) : .inspector(after: store.clearBefore))
    }
    private var replay: InspectorReplayReading? {
        appModel.face.slot(.inspectorReplay(day: store.replayDate)).select("reading", as: InspectorFace.self) { $0.map(InspectorReplayReading.init) }
    }
    private var replayPresentation: TurnInspectorReplayPresentation {
        .resolve(requested: store.replayDate, loaded: replay?.loadedDate,
                 isLoading: replay?.requestedDate != store.replayDate || replay?.status == .reading,
                 failure: replay?.requestedDate == store.replayDate ? replay?.issue : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            header
            Divider()
            if let issue = store.issue { Text(issue).foregroundStyle(.orange).textSelection(.enabled) }
            content
        }
        .padding(NativeAgentSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liveTask(id: store.key) {
            await store.observe(client: appModel.client)
        }
        .onChange(of: inspectorReport, initial: true) { _, report in
            if !quietOffscreenRead, let report { FaceReports.shared.submit(.reportInspector(report)) }
        }
    }

    private var inspectorReport: RendererInspectorReport? {
        FaceReports.shared.connectionID.map { store.report(connection: $0) }
    }

    private var header: some View {
        FaceView(face: headerFace, door: headerDoor, session: session).macFaceStyle()
    }

    private var headerFace: PartFace {
        var rows: [PartFace.Row] = [
            .init(id: "inspector-mode", title: "Chat turn details", control: .choice(
                TurnInspectorStore.Mode.allCases.map { .init(id: $0.rawValue, label: $0.rawValue) },
                selected: store.mode.rawValue, call: .init("inspector.mode"))),
        ]
        if store.mode == .live {
            rows.append(.init(id: "inspector-clear", title: "What happens during each message, as it happens", actions: [
                .init(id: "clear", label: "Clear", call: .init("inspector.clear")),
            ]))
        } else {
            rows.append(.init(id: "inspector-date", title: "Replay date", detail: replayPresentation.statusText,
                control: .init(call: .init("inspector.date"), date: store.replayDate.formatted(.iso8601))))
            if let replay, replay.unreadable > 0 {
                rows.append(.init(id: "inspector-unreadable", title: "\(replay.unreadable) unreadable rows skipped", tone: .attention))
            }
            if let issue = replay?.issue {
                rows.append(.init(id: "inspector-replay-issue", title: issue, tone: .failed))
            }
        }
        return PartFace(sections: [.init(id: "inspector-controls", rows: rows)])
    }

    private var headerDoor: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, perform: { submission in
            guard !submission.checking,
                  let row = headerFace.sections.flatMap(\.rows).first(where: { $0.id == submission.row }) else {
                return .interrupted(WireFailure(code: "inspector_control_changed", message: "The Inspector control changed. Read it again.",
                                                cause: nil, effects: .none))
            }
            if submission.action == "set", let value = submission.value,
               row.control?.settingCall(value) == submission.expectedCall {
                switch row.id {
                case "inspector-mode":
                    guard let mode = TurnInspectorStore.Mode(rawValue: value) else {
                        return .interrupted(WireFailure(code: "inspector_mode_invalid", message: "Choose Live or Replay.", cause: nil, effects: .none))
                    }
                    store.setMode(mode)
                case "inspector-date":
                    do { store.loadReplay(for: try Date.ISO8601FormatStyle().parse(value)) }
                    catch {
                        return .interrupted(WireFailure(code: "inspector_date_invalid", message: "The replay date could not be read.",
                                                        cause: error.localizedDescription, effects: .none))
                    }
                default:
                    return .interrupted(WireFailure(code: "inspector_control_changed", message: "The Inspector control changed. Read it again.",
                                                    cause: nil, effects: .none))
                }
                return .init(effects: .known, accepted: true, committed: [.init(id: "value", value: .string(value))])
            }
            guard row.id == "inspector-clear", submission.action == "clear",
                  row.actions?.first?.call == submission.expectedCall else {
                return .interrupted(WireFailure(code: "inspector_control_changed", message: "The Inspector control changed. Read it again.",
                                                cause: nil, effects: .none))
            }
            store.clearLive()
            return .init(effects: .known, accepted: true)
        })
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let ids = slot.select("ids", as: InspectorFace.self) { $0?.ids ?? [] }
        let status = slot.select("status", as: InspectorFace.self) { $0?.status }
        if let issue = slot.select("issue", as: InspectorFace.self, { $0?.issue }) {
            Text(issue).foregroundStyle(.orange)
        }
        if ids.isEmpty, status == nil || status == .reading {
            statusFace(store.mode == .replay ? replayPresentation.statusText : "Reading saved turns…", waiting: true)
        } else if ids.isEmpty, status == .ready {
            emptyState
        } else if ids.isEmpty {
            statusFace("Inspector evidence is unavailable.", tone: .failed)
        } else {
            List {
                ForEach(ids, id: \.self) { InspectorCardReadout(slot: slot, id: $0, session: session) }
            }
            .environment(\.faceInList, true)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .macFaceStyle()
        }
    }

    private var emptyState: some View {
        statusFace(store.mode == .live
            ? "Waiting for a turn — send a message to watch it happen."
            : (replay?.issue ?? (replay?.hasEvidence == false
                ? "Nothing was recorded for this date."
                : "No readable turns recorded for this date.")))
    }

    private func statusFace(_ words: String, tone: PartFace.Tone = .quiet, waiting: Bool = false) -> some View {
        FaceView(face: PartFace(sections: [
            .init(id: "inspector-status", style: waiting ? .waiting : .note, rows: [
                .init(id: "inspector-status", title: words, tone: tone),
            ]),
        ]), door: ReadOnlyFaceDoor(), session: session).macFaceStyle()
    }
}

private struct InspectorReplayReading: Equatable {
    let status: InspectorFace.Status
    let requestedDate: Date?
    let loadedDate: Date?
    let unreadable: Int
    let hasEvidence: Bool?
    let issue: String?

    init(_ face: InspectorFace) {
        status = face.status; requestedDate = face.requestedDate; loadedDate = face.loadedDate
        unreadable = face.unreadable; hasEvidence = face.hasEvidence; issue = face.issue
    }
}

private struct InspectorCardReadout: View {
    let slot: FaceSlot
    let id: String
    let session: FacePageSession

    private var card: InspectorTurnCard? { slot.select("card." + id, as: InspectorFace.self) { $0?.cards[id] } }

    var body: some View {
        if let card {
            FaceView(face: projected(card), door: door, session: session)
        } else {
            FaceView(face: PartFace(sections: [.init(id: "missing:" + id, rows: [
                .init(id: "missing:" + id, title: "Waiting on the turn's evidence…", tone: .quiet),
            ])]), door: ReadOnlyFaceDoor(), session: session)
        }
    }

    private func projected(_ card: InspectorTurnCard) -> PartFace {
        do { return try card.pageFace() }
        catch {
            return PartFace(sections: [.init(id: "failed:" + id, rows: [
                .init(id: "failed:" + id, title: error.localizedDescription, tone: .failed),
            ])])
        }
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, waitingOn: "the selected Inspector evidence", read: { request in
            guard let card else {
                throw PartCallError(code: "inspector_card_unavailable", message: "The selected turn is unavailable in this Inspector reading.")
            }
            return try card.readDocument(request)
        }, pageRead: { request in
            guard let card else {
                throw PartCallError(code: "inspector_card_unavailable", message: "The selected turn is unavailable in this Inspector reading.")
            }
            return try card.readFace(request)
        }, perform: { _ in
            .interrupted(WireFailure(code: "inspector_read_only", message: "Inspector evidence has no write command.", cause: nil, effects: .none))
        })
    }
}

/// Keep requested and displayed dates separate so a slow replay read cannot relabel retained evidence.
enum TurnInspectorReplayPresentation: Equatable {
    case loading(requested: Date, retained: Date?)
    case loaded(Date)
    case unavailable(requested: Date, retained: Date?, reason: String)

    static func resolve(requested: Date, loaded: Date?, isLoading: Bool, failure: String?) -> Self {
        if isLoading { return .loading(requested: requested, retained: loaded) }
        if let failure { return .unavailable(requested: requested, retained: loaded, reason: failure) }
        guard let loaded else { return .loading(requested: requested, retained: nil) }
        return .loaded(loaded)
    }

    var statusText: String {
        switch self {
        case let .loading(requested, retained):
            let loading = "Loading the turns from \(requested.formatted(date: .abbreviated, time: .omitted))…"
            guard let retained else { return loading }
            return "\(loading) Showing the turns from \(retained.formatted(date: .abbreviated, time: .omitted))."
        case let .loaded(date):
            return "Showing the turns from \(date.formatted(date: .abbreviated, time: .omitted))."
        case let .unavailable(requested, retained, reason):
            let issue = "Could not load the turns from \(requested.formatted(date: .abbreviated, time: .omitted)): \(reason)"
            guard let retained else { return issue }
            return "\(issue) Showing the turns from \(retained.formatted(date: .abbreviated, time: .omitted))."
        }
    }
}

@MainActor
@Observable
final class TurnInspectorStore {
    enum Mode: String, CaseIterable, Identifiable {
        case live = "Live", replay = "Replay"
        var id: String { rawValue }
    }

    private(set) var mode: Mode = .live
    private(set) var clearBefore: Date?
    private(set) var replayDate = Calendar(identifier: .gregorian).startOfDay(for: Date())
    private(set) var subscription: UUID?
    private(set) var issue: String?
    @ObservationIgnored private var mounting: UUID?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var observedKey: FaceKey?
    @ObservationIgnored private weak var client: (any FaceClient)?

    var mounted: Bool { owner != nil }
    var key: FaceKey { mode == .replay ? .inspectorReplay(day: replayDate) : .inspector(after: clearBefore) }

    func observe(client: any FaceClient) async {
        let owner = UUID()
        self.owner = owner
        observedKey = key
        TurnInspectorDoctor.active = self
        if let connection = FaceReports.shared.connectionID { FaceReports.shared.submit(.reportInspector(report(connection: connection))) }
        let (lifetime, held) = AsyncStream<Void>.makeStream()
        defer { held.finish() }
        _ = replace(key, client: client, owner: owner)
        for await _ in lifetime { }
        guard self.owner == owner else { return }
        self.owner = nil
        observedKey = nil
        if TurnInspectorDoctor.active === self { TurnInspectorDoctor.active = nil }
        if let connection = FaceReports.shared.connectionID {
            FaceReports.shared.submit(.reportInspector(.init(connection: connection, view: nil, subscription: nil,
                mounted: false, observing: false, issue: nil)))
        }
        let closing = observationTask
        closing?.cancel()
        await closing?.value
        if observationTask == closing { observationTask = nil }
    }

    private func replace(_ key: FaceKey, client: any FaceClient, owner: UUID) -> AsyncStream<Void> {
        let previous = observationTask
        previous?.cancel()
        subscription = nil
        let (ready, admitted) = AsyncStream<Void>.makeStream()
        let next = Task { [weak self] in
            defer { admitted.finish() }
            await previous?.value
            guard !Task.isCancelled, let self, self.owner == owner else { return }
            await mount(key, client: client, admitted: admitted)
        }
        observationTask = next
        return ready
    }

    private func mount(_ key: FaceKey, client: any FaceClient, admitted: AsyncStream<Void>.Continuation) async {
        let id = UUID()
        mounting = id
        self.client = client
        subscription = nil
        issue = nil
        defer {
            if mounting == id {
                mounting = nil
                subscription = nil
            }
        }
        do {
            try await register(key, client: client, id: id)
            try Task.checkCancellation()
            subscription = id
            admitted.yield(())
            let (lifetime, end) = AsyncStream<Void>.makeStream()
            defer { end.finish() }
            for await _ in lifetime { }
        } catch is CancellationError {
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        subscription = nil
        let release = Task { try await client.act(.unobserve(id: id)).checkedAcknowledgement() }
        do { try await release.value }
        catch { issue = [issue, error.localizedDescription].compactMap { $0 }.joined(separator: "\n") }
    }

    private func register(_ key: FaceKey, client: any FaceClient, id: UUID) async throws {
        let reply = try await client.act(.observe(id: id, demand: .key(key)))
        switch reply {
        case .observation(let accepted) where accepted == id: return
        case .failed(let failure), .refused(let failure): throw failure
        default: throw FaceActionFeedback.unexpected("the Inspector observation identity")
        }
    }

    func setMode(_ value: Mode) { mode = value }
    func clearLive() { clearBefore = Date() }
    func loadReplay(for date: Date) { replayDate = Calendar(identifier: .gregorian).startOfDay(for: date) }

    func report(connection: UUID) -> RendererInspectorReport {
        let state = observedKey.flatMap { client?.face.slot($0).value(as: InspectorFace.self) }
        let pending = owner != nil && (subscription == nil || state?.observationActive == nil)
        return RendererInspectorReport(connection: connection, view: owner, subscription: subscription, mounted: mounted,
            observing: mounted && subscription != nil && issue == nil && state?.observationActive == true,
            issue: issue ?? state?.issue ?? (pending ? "Waiting on the body's trace-observation state."
                : state?.observationActive == false ? "The body trace observer is inactive." : nil))
    }

    func rearm(connection: UUID, view: UUID, subscription expected: UUID?) async throws -> RendererInspectorReport {
        guard mounted, let owner, owner == view, subscription == expected, observedKey == key, let client else {
            throw PartCallError(code: "inspector_selection_changed", message: "The Inspector view or subscription changed. Read its health again.")
        }
        let key = self.key
        let ready = replace(key, client: client, owner: owner)
        for await _ in ready { break }
        try Task.checkCancellation()
        guard self.owner == owner else {
            throw PartCallError(code: "inspector_selection_changed", message: "The Inspector selection changed while its subscription was opening.")
        }
        return report(connection: connection)
    }
}

@MainActor
enum TurnInspectorDoctor {
    static weak var active: TurnInspectorStore?

    static func report(connection: UUID) -> RendererInspectorReport {
        active?.report(connection: connection) ?? RendererInspectorReport(
            connection: connection, view: nil, subscription: nil, mounted: false, observing: false, issue: nil)
    }

    static func rearm(connection: UUID, view: UUID, subscription: UUID?) async throws -> RendererInspectorReport {
        guard let active else {
            throw PartCallError(code: "inspector_closed", message: "The Inspector view closed before its subscription could be rearmed.")
        }
        return try await active.rearm(connection: connection, view: view, subscription: subscription)
    }
}
