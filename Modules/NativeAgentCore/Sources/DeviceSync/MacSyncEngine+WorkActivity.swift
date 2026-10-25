import Foundation
import NativeAgentShared
import PersistenceCore
import Experiences
import TurnTrace
// Blueprint: | `MacSyncEngine+WorkActivity.swift` | `MacSyncEngine`: `startWorkActivityObservation`, `projectWorkshopWorkActivities`, `requestWorkActivityPublication` |

extension MacSyncEngine {
    func startWorkActivityObservation() {
        workActivityObservationTask?.cancel()
        let generation = snapshotLifecycleGeneration
        workActivityObservationTask = Task {
            for await _ in await ExperienceStore.at(sync.dataRoot).changes() {
                guard !Task.isCancelled, generation == snapshotLifecycleGeneration, isActive else { return }
                workActivityVersion &+= 1
                requestWorkActivityPublication()
                await writeSnapshots()
            }
        }
    }

    private func activity(_ experience: Experience) -> MobileWorkActivity? {
        // Only the person's conversations: a worker's brief answers its caller, never him.
        guard experience.kind == .heard, let answer = experience.owes["answer"], answer.to.hasPrefix("conversation:"),
              let started = DeskActivityState.movementDate(experience.at) else { return nil }
        let state: MobileWorkActivity.State
        let status: String
        if answer.phase == .accepted { state = .completed; status = "Reply ready" }
        else if answer.phase == .letGo {
            state = answer.reason == .cancelled ? .stopped : .failed
            status = answer.reason == .cancelled ? "Stopped" : "Failed — open the conversation"
        } else if experience.progress == "waiting" || (experience.progress == nil && experience.outcome?.status == "waiting") {
            state = .waiting; status = "Answer owed"
        } else if experience.evidence.contains(.init(source: "runtime", id: ExperienceStore.processID)) {
            state = .working; status = "Answering"
        } else {
            state = .unknown; status = "Answer settlement unconfirmed"
        }
        let destination = answer.to
        return MobileWorkActivity(id: "turn:" + experience.id,
            sessionID: destination.hasPrefix("conversation:") ? String(destination.dropFirst(13)) : nil,
            startedAt: started, content: .init(
                title: String((experience.face?.words ?? "Conversation").prefix(96)), state: state,
                status: status, updatedAt: DeskActivityState.movementDate(experience.updatedAt) ?? started))
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
                    let experiences: [Experience]
                    let unavailable: String?
                    do {
                        experiences = try await ExperienceStore.at(sync.dataRoot).projection()
                        unavailable = nil
                    } catch {
                        experiences = []
                        unavailable = error.localizedDescription
                    }
                    var rows = Array((experiences.compactMap(activity) + workActivities.values)
                        .sorted { $0.content.updatedAt > $1.content.updatedAt }.prefix(64))
                    if let unavailable {
                        rows.append(.init(id: "experience:unavailable", sessionID: nil, startedAt: Date(),
                            content: .init(title: "Work state unavailable", state: .unknown,
                                status: unavailable, updatedAt: Date())))
                    }
                    guard let pairing = try PairingSecretManager.existingSecretBase64() else { return }
                    let configuration = await sync.apns.workActivityConfiguration(dataRoot: sync.dataRoot)
                    var snapshot = MobileWorkActivitySnapshot(activities: rows,
                        pairingFingerprint: WorkActivityPushRegistration.fingerprint(pairing), pushConfigured: configuration.configured,
                        pushConfigurationError: configuration.error)
                    snapshot.experiences = experiences.map(\.mobile)
                    snapshot.unavailable = unavailable
                    let data = try await MobileSnapshotBuilder.shared.encode(snapshot)
                    var changed: Set<String> = []
                    switch await writeSnapshotData(data, to: "work_activity.json", in: snapshotDir, lifecycleGeneration: generation, readRevision: Date().timeIntervalSince1970) {
                    case .changed: changed.insert("work_activity.json")
                    case .failed(let reason): syncError = "Work activity sync failed: \(reason)"
                    case .unchanged: break
                    }
                    await publishChangedSnapshots(changed, in: snapshotDir,
                        lifecycleGeneration: generation, scope: .standard)
                    guard !Task.isCancelled, generation == snapshotLifecycleGeneration, isActive else { return }
                    if configuration.usable {
                        let errors = await sync.relay.sendWorkActivities(rows, dataRoot: sync.dataRoot)
                        if !errors.isEmpty { syncError = "Live Activity push failed: \(errors.joined(separator: "; "))" }
                    }
                } while publishedVersion != workActivityVersion
            } catch is CancellationError {} catch {
                syncError = "Work activity sync failed: \(error.localizedDescription)"
            }
        }
    }
}
