import Foundation
import NativeAgentShared
import PersistenceCore
import TurnTrace

extension MacSyncEngine {
    func startWorkActivityObservation() {
        workActivityObservationTask?.cancel()
        let generation = snapshotLifecycleGeneration
        workActivityObservationTask = Task {
            let subscription = await TurnTraceBus.shared.subscribe(capacity: 256)
            defer { Task { await TurnTraceBus.shared.unsubscribe(subscription.id) } }
            do {
                let reader = TurnTraceRecentReader(dataRootOverride: sync.dataRoot)
                let previous = try await reader.read(now: Date().addingTimeInterval(-86400))
                let current = try await reader.read()
                guard generation == snapshotLifecycleGeneration, isActive else { return }
                for event in (previous.events + current.events).sorted(by: { $0.ts < $1.ts }) {
                    reduceWorkActivity(event)
                }
                requestWorkActivityPublication()
            } catch {
                syncError = "Work activity history could not be read: \(error.localizedDescription)"
            }
            var drops = 0
            for await event in subscription.stream {
                guard !Task.isCancelled, generation == snapshotLifecycleGeneration, isActive else { break }
                let count = await TurnTraceBus.shared.dropCount(subscription.id)
                if count != drops {
                    drops = count
                    for id in Array(workActivities.keys) where workActivities[id]?.content.state.isTerminal == false {
                        workActivities[id]?.content.state = .unknown
                        workActivities[id]?.content.status = "Updates were missed — state unknown"
                    }
                    workActivityVersion &+= 1
                    requestWorkActivityPublication()
                }
                if reduceWorkActivity(event) { requestWorkActivityPublication() }
            }
        }
    }

    @discardableResult
    private func reduceWorkActivity(_ event: TurnTraceEvent) -> Bool {
        guard case .object(let payload) = event.payload else { return false }
        func text(_ key: String) -> String? {
            guard case .string(let value)? = payload[key] else { return nil }
            return value
        }
        let id = "turn:\(event.turnId)"
        if event.kind == "work.identified" {
            guard let title = text("title"), !title.isEmpty, workActivities[id] == nil else { return false }
            workActivities[id] = MobileWorkActivity(id: id, sessionID: event.sessionId, startedAt: event.ts,
                content: .init(title: title, state: .preparing, status: "Preparing", updatedAt: event.ts))
        } else {
            guard var row = workActivities[id], event.ts >= row.content.updatedAt,
                  !row.content.state.isTerminal else { return false }
            let state: MobileWorkActivity.State
            let status: String
            switch event.kind {
            case "context.ready": state = .preparing; status = "Context ready"
            case "provider.requestStarted": state = .working; status = "Waiting for the model"
            case "provider.retry": state = .retrying; status = "Retrying the model request"
            case "provider.firstDelta": state = .working; status = "Model is responding"
            case "surface.outputEnqueued": state = .replying; status = "Writing the reply"
            case "tool.dispatch":
                // An app call reads as the action it ran (`shown`).
                if text("phase") == "begin", let name = text("shown") ?? text("name") {
                    state = .tool; status = String(ToolActivityPresentation.progress(name).prefix(120))
                } else if text("status") == "waiting" || text("status") == "blocked" {
                    state = .blocked; status = "Needs your decision"
                } else { state = .working; status = "Tool returned — continuing" }
            case "turn.cancelled": state = .stopped; status = "Stopped"
            case "turn.failed": state = .failed; status = "Failed — open the conversation"
            case "turn.terminal":
                switch text("status") {
                case "completed": state = .completed; status = "Reply ready"
                case "waiting":
                    state = .waiting
                    status = text("terminalReason") == "approval_required" ? "Approval required" : "Needs your answer"
                case "failed": state = .failed; status = "Failed — open the conversation"
                case "interrupted", "braked": state = .interrupted; status = "Stopped before completion"
                default: state = .unknown; status = "Outcome unknown"
                }
            default: return false
            }
            row.content.state = state
            row.content.status = status
            row.content.updatedAt = event.ts
            workActivities[id] = row
        }
        let retained = Set(workActivities.values.sorted { $0.content.updatedAt > $1.content.updatedAt }.prefix(64).map(\.id))
        workActivities = workActivities.filter { retained.contains($0.key) }
        workActivityVersion &+= 1
        return true
    }

    func projectWorkshopWorkActivities(_ data: Data) throws {
        struct Source: Decodable {
            var id: String
            var title: String
            var status: String
            var createdAt: String
            var updatedAt: String?
            var lastMovementAt: String?
        }
        let records = try JSONDecoder().decode([Source].self, from: data)
        for record in records {
            guard let started = DeskActivityState.movementDate(record.createdAt),
                  let updated = DeskActivityState.movementDate(record.updatedAt) else { continue }
            let id = "execution:\(record.id)"
            let state: MobileWorkActivity.State
            let status: String
            switch record.status {
            case "queued": state = .queued; status = "Queued"
            case "blocked_on_approval": state = .blocked; status = "Approval required"
            case "running":
                if let movement = DeskActivityState.movementDate(record.lastMovementAt),
                   movement <= Date(), Date().timeIntervalSince(movement) < DeskActivityState.movementWindow {
                    state = .working; status = "Executing the task"
                } else { state = .unknown; status = "Activity unconfirmed" }
            case "completed": state = .completed; status = "Execution completed"
            case "cancelled": state = .stopped; status = "Stopped"
            case "failed": state = .failed; status = "Execution failed"
            default: state = .unknown; status = "State unknown"
            }
            let row = MobileWorkActivity(id: id, sessionID: nil, startedAt: started,
                content: .init(title: String(TurnTraceRedactor.redactText(record.title).prefix(96)),
                    state: state, status: status, updatedAt: updated))
            if workActivities[id] != row {
                workActivities[id] = row
                workActivityVersion &+= 1
            }
        }
        let retained = Set(workActivities.values.sorted { $0.content.updatedAt > $1.content.updatedAt }.prefix(64).map(\.id))
        workActivities = workActivities.filter { retained.contains($0.key) }
        requestWorkActivityPublication()
    }

    func requestWorkActivityPublication() {
        guard isActive, workActivityPublicationTask == nil else { return }
        let generation = snapshotLifecycleGeneration
        workActivityPublicationTask = Task {
            defer {
                workActivityPublicationTask = nil
                if generation != snapshotLifecycleGeneration { requestWorkActivityPublication() }
            }
            do {
                try await Task.sleep(for: .milliseconds(500))
                var publishedVersion: UInt64
                repeat {
                    publishedVersion = workActivityVersion
                    guard !Task.isCancelled, generation == snapshotLifecycleGeneration, isActive,
                          let snapshotDir else { return }
                    let rows = Array(workActivities.values.sorted { $0.content.updatedAt > $1.content.updatedAt }.prefix(64))
                    guard let pairing = try PairingSecretManager.existingSecretBase64() else { return }
                    let configuration = await sync.apns.workActivityConfiguration(dataRoot: sync.dataRoot)
                    let snapshot = MobileWorkActivitySnapshot(activities: rows,
                        pairingFingerprint: WorkActivityPushRegistration.fingerprint(pairing), pushConfigured: configuration.configured,
                        pushConfigurationError: configuration.error)
                    let data = try await MobileSnapshotBuilder.shared.encode(snapshot)
                    switch await writeSnapshotData(data, to: "work_activity.json", in: snapshotDir, lifecycleGeneration: generation) {
                    case .changed:
                        await publishChangedSnapshots(["work_activity.json"], in: snapshotDir,
                            lifecycleGeneration: generation, scope: .standard)
                    case .failed(let reason): syncError = "Work activity sync failed: \(reason)"
                    case .unchanged: break
                    }
                    guard !Task.isCancelled, generation == snapshotLifecycleGeneration, isActive else { return }
                    if configuration.usable {
                        let errors = await sync.apns.sendWorkActivities(rows, dataRoot: sync.dataRoot)
                        if !errors.isEmpty { syncError = "Live Activity push failed: \(errors.joined(separator: "; "))" }
                    }
                } while publishedVersion != workActivityVersion
            } catch is CancellationError {} catch {
                syncError = "Work activity sync failed: \(error.localizedDescription)"
            }
        }
    }
}
