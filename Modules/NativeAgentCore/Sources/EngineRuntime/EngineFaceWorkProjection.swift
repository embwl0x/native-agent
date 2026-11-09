import Desk
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import Senses
import Studio
// Blueprint: | `EngineFaceWorkProjection.swift` | Finished Desk search/details, Make grants and version-bound Sense presentations from body owners |

enum EngineFaceWorkProjection {
    @concurrent static func prepareWorkPane(_ pane: WorkPaneSnapshot, engine: NativeAgentEngine) async throws {
        guard pane.isVisible else { return }
        await engine.senses.refresh()
        let sense = await MainActor.run {
            senseFace(engine.senses.interactiveView, revision: engine.senses.interactiveRevision,
                loaded: engine.senses.presentationLoaded, issue: engine.senses.presentationIssue)
        }
        await engine.face.post(sense, at: .senseView)
        guard pane.tab == "make" else { return }
        try await engine.make.prepareCapture()
        let shelf = await MainActor.run {
            shelfFace(engine.make.allMetadata, newest: engine.make.newest?.ref, loaded: engine.make.loaded, issue: engine.make.fault)
        }
        await engine.face.post(shelf, at: .makeShelf)
        let reference = pane.reference ?? shelf.newest
        guard let reference else { return }
        guard MakeStudio.isRef(reference), let version = shelf.versions.last(where: {
            $0.reference == reference && (pane.version == nil || $0.version == pane.version)
        }) else {
            throw failure("make_reference_unavailable", "The selected Make reference has no checked version.")
        }
        _ = await preview(reference, version: version.version, studio: MakeStudio(dataRoot: engine.dataRoot), engine: engine)
    }

    @concurrent static func prepareDiagnostics(engine: NativeAgentEngine) async {
        _ = await engine.desk.loadPage()
        let input = await MainActor.run { (engine.desk.page, engine.desk.liveUpdateError) }
        await engine.face.post(diagnostics(input.0, issue: input.1), at: .deskDiagnostics)
    }

    @concurrent static func deskPalette(_ view: UUID, query: String, engine: NativeAgentEngine) async {
        _ = await engine.desk.loadPage()
        let parsed = DeskPaletteQuery.parse(query)
        await EngineFaceProjection.watch(read: { (engine.desk.page, engine.desk.liveUpdateError, engine.desk.faceItem) }) { page, issue, selected in
            guard !Task.isCancelled else { return }
            let active = DeskPageContent.active(page.boardItems)
            let stamps = active.reduce(into: [String: String]()) { $0[$1.handle] = $1.updatedAt }
            let candidates = active.map(DeskPaletteRow.init(item:))
            let matches = parsed.verb != nil && parsed.query.isEmpty ? candidates : DeskFuzzy.filter(candidates, query: parsed.query)
            let rows = matches.map { item in
                PartFace.Row(id: item.handle, title: NativeAppSecretRedactor.redactText(item.title),
                    detail: NativeAppSecretRedactor.redactText(item.alias + " · " + item.status + " · " + item.project),
                    value: item.status, actions: [])
            }
            let commands: [DeskCommandRequest] = parsed.verb.map { verb in
                matches.map { item in
                    var arguments: [String: PartFace.Value] = [:]
                    if verb == .close, let stamp = stamps[item.handle] {
                        arguments["expected_updated_at"] = .string(stamp)
                    }
                    return DeskCommandRequest(command: verb.rawValue, handle: item.handle, arguments: arguments)
                }
            } ?? []
            await engine.face.post(DeskPaletteFace(view: view, query: query, rows: rows, commands: commands,
                state: state(page.deskUnavailable ?? issue, loaded: page.loaded, owner: "Desk search"), selectedHandle: selected), at: .deskPalette(view))
        }
    }

    @concurrent static func observe(_ key: FaceKey, engine: NativeAgentEngine) async {
        switch key {
        case .deskDiagnostics, .workDetail:
            _ = await engine.desk.loadPage()
            await EngineFaceProjection.watch(read: { (engine.desk.page, engine.desk.liveUpdateError) }) { page, issue in
                guard !Task.isCancelled else { return }
                if key == .deskDiagnostics {
                    await engine.face.post(diagnostics(page, issue: issue), at: key)
                } else if case .workDetail(let kind, let id) = key {
                    await engine.face.post(detail(page, kind: kind, id: id, issue: issue), at: key)
                }
            }
        case .makeShelf:
            await engine.make.start()
            await EngineFaceProjection.watch(read: { (engine.make.allMetadata, engine.make.newest?.ref, engine.make.loaded, engine.make.fault) }) {
                metadata, newest, loaded, issue in
                guard !Task.isCancelled else { return }
                await engine.face.post(shelfFace(metadata, newest: newest, loaded: loaded, issue: issue), at: key)
            }
        case .makePreview(let reference, let version):
            let studio = MakeStudio(dataRoot: engine.dataRoot)
            guard MakeStudio.isRef(reference), let number = Int(version), number > 0, String(number) == version else {
                await engine.face.post(previewFailure(reference, version, cause: "Choose a canonical Make ref and version."), at: key)
                return
            }
            await observePreview(reference, version: version, studio: studio, engine: engine)
        case .senseView:
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await engine.senses.observe(dataRoot: engine.dataRoot) }
                await EngineFaceProjection.watch(read: {
                    (engine.senses.interactiveView, engine.senses.interactiveRevision,
                     engine.senses.presentationLoaded, engine.senses.presentationIssue)
                }) { view, revision, loaded, issue in
                    guard !Task.isCancelled else { return }
                    await engine.face.post(senseFace(view, revision: revision, loaded: loaded, issue: issue), at: key)
                }
                group.cancelAll()
            }
        default: break
        }
    }

    @MainActor static func senseEvent(_ identity: String, revision: String, event: PartFace.Value,
        engine: NativeAgentEngine) async throws -> FaceActReply {
        await engine.senses.refresh()
        if let issue = engine.senses.presentationIssue { throw failure("sense_registry_unavailable", issue) }
        guard let view = engine.senses.interactiveView, view.senseID == identity, engine.senses.interactiveRevision == revision else {
            throw failure("sense_view_changed", "This Sense view has changed or closed. Read its current presentation before sending another event.")
        }
        try Task.checkCancellation()
        let issue = await SensesHub.shared.receiveViewEvent(JSONValue(event), presentation: view)
        await engine.senses.refresh()
        if let issue {
            throw WireFailure(code: "sense_event_unconfirmed", message: "The Sense event did not complete.",
                cause: NativeAppSecretRedactor.redactText(issue), effects: .unknown)
        }
        return .acknowledged
    }

    private static func diagnostics(_ page: DeskPageSnapshot, issue: String?) -> DeskDiagnosticsFace {
        guard let board = page.board else { return DeskDiagnosticsFace(rows: [], state: .waiting(on: "Desk")) }
        let records = board.items.map {
            "\($0.alias)  \($0.handle)  \($0.kind.rawValue)  \($0.status.rawValue)  \($0.origin.rawValue)  \($0.project)  —  \($0.title)"
        }.joined(separator: "\n")
        return DeskDiagnosticsFace(rows: [row("projection", "The agent's view", board.debugProjection),
            row("records", "All items (debug — raw records with numbers)", records)],
            state: state(board.deskError ?? issue, loaded: true, owner: "Desk"))
    }

    private static func detail(_ page: DeskPageSnapshot, kind: String, id: String, issue: String?) -> WorkDetailFace {
        var result = WorkDetailFace(kind: kind, id: id, title: nil, status: nil, location: nil, text: nil, sourceDate: nil,
            state: .waiting(on: "work detail"))
        guard let board = page.board else { return result }
        do {
            let work: WorkOverviewRow
            switch kind {
            case "desk":
                if let issue = board.deskError { throw failure("desk_unavailable", issue) }
                guard let item = board.items.first(where: { $0.handle == id }) else {
                    throw failure("desk_item_missing", "This item is absent from the checked Desk.")
                }
                work = WorkOverviewRead.row(for: item, now: page.now)
                result.text = work.detail + (MobileDeskProjectionBounds.isClipped(work.detail) ? "\n\nThis reading copy is cut off." : "")
            case "execution":
                if let issue = board.agentJobs.unavailableReason { throw failure("work_jobs_unavailable", issue) }
                guard let job = board.agentJobs.items.first(where: { $0.id == id }) else {
                    throw failure("work_job_missing", "This work is absent from the checked job records.")
                }
                work = WorkOverviewRead.row(for: job, now: page.now)
                result.text = [job.request.map { "Asking: " + $0.title }, WorkOverviewRead.text(for: job)].compactMap { $0 }.joined(separator: "\n\n")
            case "approval":
                guard let approval = try board.approvals.get().first(where: { $0.id == id }) else {
                    throw failure("approval_missing", "This approval is absent from the checked records.")
                }
                result.title = approval.title
                result.status = approval.status
                result.state = state(issue, loaded: true, owner: "Desk")
                return redacted(result)
            case "inbox":
                guard let item = try board.inbox.get().first(where: { $0.id == id }) else {
                    throw failure("inbox_item_missing", "This item is absent from the checked Inbox.")
                }
                result.title = item.title
                result.state = state(issue, loaded: true, owner: "Desk")
                return redacted(result)
            default: throw failure("work_kind_unknown", "This work detail kind is not recognized.")
            }
            result.title = work.title
            result.status = work.stateLabel(at: page.now)
            result.location = work.location
            result.sourceDate = NativeTimestampFormat.parseISO8601(work.updatedAt)
            result.state = state(issue, loaded: true, owner: "Desk")
        } catch {
            result.state = .unavailable(failure("work_detail_unavailable", error.localizedDescription))
        }
        return redacted(result)
    }

    @concurrent private static func observePreview(_ reference: String, version: String, studio: MakeStudio, engine: NativeAgentEngine) async {
        var file = await preview(reference, version: version, studio: studio, engine: engine)
        let folder = studio.folder(reference)
        let key = FaceKey.makePreview(reference: reference, version: version)
        while !Task.isCancelled {
            var paths = [folder, folder.appendingPathComponent("meta.json")]
            if let file { paths.append(file) }
            let events = FileChangeEvents(paths: paths, emitInitial: true)
            let rearm = await withTaskCancellationHandler {
                guard await events.waitUntilArmed(), !Task.isCancelled else {
                    if !Task.isCancelled {
                        await engine.face.post(previewFailure(reference, version, cause: "Make preview file observation could not open."), at: key)
                    }
                    return false
                }
                for await _ in events.stream {
                    guard !Task.isCancelled else { return false }
                    let selected = await preview(reference, version: version, studio: studio, engine: engine)
                    if let selected, selected != file { file = selected; return true }
                }
                if !Task.isCancelled {
                    await engine.face.post(previewFailure(reference, version, cause: "Make preview file observation closed. Reopen the preview."), at: key)
                }
                return false
            } onCancel: { events.cancel() }
            events.cancel()
            guard rearm else { return }
        }
    }

    @concurrent private static func preview(_ reference: String, version: String, studio: MakeStudio, engine: NativeAgentEngine) async -> URL? {
        let key = FaceKey.makePreview(reference: reference, version: version)
        var file: URL?
        do {
            guard let meta = try studio.readMeta(reference), let selected = meta.versions.first(where: { String($0.n) == version }) else {
                throw failure("make_version_missing", "The selected version is absent from the checked Make metadata.")
            }
            let selectedFile = studio.url(reference, selected)
            file = selectedFile
            let prepared = await engine.make.preview(reference, selected, revision: 0)
            if let issue = prepared.imageFailure { throw failure("make_image_unavailable", issue) }
            await engine.make.flushPreviewTitle(reference, version: selected, revision: 0)
            let kind = makeKind(selectedFile)
            var resources = [try resource(selectedFile)]
            if kind == "web" { resources.append(try resource(studio.folder(reference))) }
            try Task.checkCancellation()
            await engine.face.post(MakePreviewFace(reference: reference, version: version, kind: kind, text: nil,
                resources: resources, revision: UUID().uuidString, state: .ready, titleKey: prepared.titleKey), at: key)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { await engine.face.post(previewFailure(reference, version, cause: error.localizedDescription), at: key) }
        }
        return file
    }

    private static func makeKind(_ file: URL) -> String {
        let type = file.pathExtension.lowercased()
        return MakeStudio.webTypes.contains(type) ? "web" : MakeStudio.imageTypes.contains(type) ? "image" : "file"
    }

    private static func shelfFace(_ metadata: [MakeStudio.Meta], newest: String?, loaded: Bool, issue: String?) -> MakeShelfFace {
        let versions = metadata.flatMap { meta in
            meta.versions.map { version in
                FaceMakeVersion(reference: meta.ref, version: String(version.n), title: meta.ref + "-" + version.file,
                    date: NativeTimestampFormat.parseISO8601(version.created),
                    prompt: version.prompt.map(NativeAppSecretRedactor.redactText), kind: makeKind(URL(fileURLWithPath: version.file)))
            }
        }
        return MakeShelfFace(versions: versions, newest: newest, state: state(issue, loaded: loaded, owner: "Make shelf"))
    }

    private static func senseFace(_ view: SenseInteractiveView?, revision: String?, loaded: Bool, issue: String?) -> SenseViewFace {
        let readable = loaded && issue == nil
        return SenseViewFace(senseID: readable ? view?.senseID : nil, version: readable ? view?.version : nil,
            title: readable ? view.map { NativeAppSecretRedactor.redactText($0.title) } : nil,
            html: readable ? view.map { NativeAppSecretRedactor.redactText($0.html) } : nil,
            revision: readable ? revision : nil, resources: [], state: state(issue, loaded: loaded, owner: "Sense view"))
    }

    private static func resource(_ file: URL) throws -> ResourceGrant {
        guard try file.checkResourceIsReachable() else { throw failure("make_resource_missing", "The selected Make resource is missing.") }
        return ResourceGrant(id: UUID(), name: file.lastPathComponent,
            bookmark: try file.bookmarkData(), writable: false)
    }

    private static func previewFailure(_ reference: String, _ version: String, cause: String) -> MakePreviewFace {
        MakePreviewFace(reference: reference, version: version, kind: nil, text: nil, resources: [], revision: nil,
            state: .unavailable(failure("make_preview_unavailable", cause)))
    }

    private static func redacted(_ value: WorkDetailFace) -> WorkDetailFace {
        var result = value
        result.title = result.title.map(NativeAppSecretRedactor.redactText)
        result.status = result.status.map(NativeAppSecretRedactor.redactText)
        result.location = result.location.map(NativeAppSecretRedactor.redactText)
        result.text = result.text.map(NativeAppSecretRedactor.redactText)
        return result
    }

    private static func row(_ id: String, _ title: String, _ detail: String) -> PartFace.Row {
        PartFace.Row(id: id, title: title, detail: NativeAppSecretRedactor.redactText(detail), actions: [])
    }

    private static func state(_ issue: String?, loaded: Bool, owner: String) -> FaceReadState {
        if let issue { return .unavailable(failure("work_owner_unavailable", issue)) }
        return loaded ? .ready : .waiting(on: owner)
    }

    private static func failure(_ code: String, _ cause: String) -> WireFailure {
        EngineFaceActs.failure(code, NativeAppSecretRedactor.redactText(cause))
    }
}
