import Foundation
import NativeAgentShared
import PersistenceCore
import Experiences
import TurnTrace
// Blueprint: | `MacSyncEngine+WorkActivity.swift` | `MacSyncEngine`, `startWorkActivityObservation`, `requestWorkActivityPublication` |

extension MacSyncEngine {
    func startWorkActivityObservation() {
        workActivityObservationTask?.cancel()
        let generation = snapshotLifecycleGeneration
        workActivityObservationTask = Task {
            for await _ in await ExperienceStore.at(sync.dataRoot).changes() {
                guard !Task.isCancelled, generation == snapshotLifecycleGeneration, isActive else { return }
                await writeSnapshots()
            }
        }
    }

    nonisolated static func activity(_ experience: Experience) -> MobileWorkActivity? {
        // Only the person's conversations reach their phone; worker answers belong to the requesting caller.
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
                status: status, updatedAt: DeskActivityState.movementDate(experience.updatedAt) ?? started, sequence: experience.sequence))
    }

    nonisolated static func workActivity(_ id: String, dataRoot: URL) async throws -> MobileWorkActivity {
        let store = ExperienceStore.at(dataRoot)
        await store.drained()
        guard id.hasPrefix("turn:"),
              let experience = try await store.experience(String(id.dropFirst(5))),
              let row = activity(experience) else {
            throw DeviceSyncError.underlying(message: "Work state is unavailable for \(id); its activity remains unresolved.")
        }
        return row
    }

    func requestWorkActivityPublication() {
        guard isActive else { return }
        if snapshotWriteInFlight {
            snapshotWriteQueuedScope = SnapshotWriteScope.workActivity.including(snapshotWriteQueuedScope)
            return
        }
        guard workActivityPublicationTask == nil else { return }
        let generation = snapshotLifecycleGeneration
        workActivityPublicationTask = Task {
            defer { workActivityPublicationTask = nil }
            guard !Task.isCancelled, generation == snapshotLifecycleGeneration, isActive else { return }
            await writeSnapshots(scope: .workActivity)
        }
    }

    func writeWorkActivitySnapshots(in snapshotDir: URL, lifecycleGeneration generation: UInt64) async {
        do {
            let experiences: [Experience]
            let unavailable: String?
            do {
                experiences = try await ExperienceStore.at(sync.dataRoot).projection()
                unavailable = nil
            } catch {
                experiences = []
                unavailable = error.localizedDescription
            }
            let rows = await MobileSnapshotBuilder.shared.build {
                Array(experiences.compactMap(Self.activity).sorted {
                    if $0.content.updatedAt != $1.content.updatedAt { return $0.content.updatedAt > $1.content.updatedAt }
                    return $0.id < $1.id
                }.prefix(64))
            }
            // A failed read has a reason, not a synthetic activity with invented source dates.
            guard let pairing = try await sync.storage.perform({ try PairingSecret.existingSecretBase64() }) else { return }
            let configuration = await sync.apns.workActivityConfiguration(dataRoot: sync.dataRoot)
            var snapshot = MobileWorkActivitySnapshot(activities: rows,
                pairingFingerprint: WorkActivityPushRegistration.fingerprint(pairing), pushConfigured: configuration.configured,
                pushConfigurationError: configuration.error)
            snapshot.experiences = await MobileSnapshotBuilder.shared.build { experiences.map(\.mobile) }
            snapshot.unavailable = unavailable
            snapshot.turnSessions = await sync.host.turnSessionsFace()
            var changed: [String: Data] = [:]
            var skipped: [String: String] = [:]
            var attempted = Set<String>()
            let revision = Date().timeIntervalSince1970
            await writeSnapshot(snapshot, to: "work_activity.json", in: snapshotDir,
                lifecycleGeneration: generation, readRevision: revision,
                changed: &changed, skipped: &skipped, attempted: &attempted)
            await commitSnapshots(changed, skipped: skipped, attempted: attempted, in: snapshotDir,
                lifecycleGeneration: generation, readRevision: revision)
            guard !Task.isCancelled, generation == snapshotLifecycleGeneration, isActive else { return }
            if configuration.usable, unavailable == nil {
                let errors = await sync.relay.sendWorkActivities(rows, dataRoot: sync.dataRoot)
                if !errors.isEmpty { syncError = "Live Activity push failed: \(errors.joined(separator: "; "))" }
            }
        } catch {
            syncError = "Work activity sync failed: \(error.localizedDescription)"
        }
    }
}
