import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import ChatSessionWork
import Context
import DoctorChecks
import PersistenceCore
import TurnTrace
import ApprovalInbox
import NotificationInbox
import MemoryV2
import DreamREMCycle
import AgentWorkspace
import Desk
import AttentionRouting
import Privacy
import ProviderRouting
import Experiences
import ToolRegistry
import Cognition
import PersonaEngine
// Blueprint: | `OffDiskBackupRunner.swift` | `MaintenanceBackgroundWork.makeOffDiskBackupLoop`; Native metadata, root protection and copying |

extension MaintenanceBackgroundWork {
    public func makeOffDiskBackupLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        OffDiskBackupRunner(port: port, period: 24 * 60 * 60, dataRoot: dataRoot)
    }
}

let backupCadenceRepairStep = "Repair or restore the backup-cadence part."

/// The part selects timing; native code owns metadata, root protection and copying.
/// Identity-file events supplement the daily backup rhythm.
/// Unavailable iCloud is a warning skip, cancellation is not a defect, and actual failures remain failed outcomes.
private struct OffDiskBackupRunner: EventDeadlineLoopRunner {
    let port: any MaintenanceBackgroundWorkPort
    let period: TimeInterval
    var wake: OrganWake { .every(period) }
    let dataRoot: URL

    var loopId: String { "offdisk_backup" }
    var tickTimeoutOverride: TimeInterval? { 15 * 60 }

    func physiologyEvents() -> AsyncStream<Void> {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return EventDeadlinePhysiology.storeAndFileEvents(paths: [])
        }
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        let identityFiles: [URL]
        do {
            identityFiles = try FileManager.default.contentsOfDirectory(
                at: personaRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { !$0.lastPathComponent.hasSuffix(".lock") }
        } catch {
            let cause = """
                Off-disk backup source watches are incompletely armed at \(personaRoot.path): \(error.localizedDescription). Repair persona directory access \
                and reopen NativeAgent to rearm its child watches; the parent watch remains active.
                """
            Task { await BackgroundLoopLifetimes.shared.recordOutOfBandOutcome(loopId: loopId, outcome: .failed(error: cause)) }
            identityFiles = []
        }
        // The onboarding sentinel and its transaction folder are what onboarded() reads, so completing setup mid-run wakes the first pass.
        return EventDeadlinePhysiology.storeAndFileEvents(
            paths: [personaRoot, dataRoot.appendingPathComponent("memory/profile.json"), dataRoot.appendingPathComponent(".onboarded"),
                dataRoot.appendingPathComponent("onboarding", isDirectory: true)] + identityFiles,
            loopId: loopId
        )
    }

    /// iCloud Drive is first read after setup completes, so its access prompt never comes before the person has a screen.
    private var onboarded: Bool { NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot) }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL, onboarded else { return nil }
        let parent = port.offDiskBackupParent()
        let port = port
        do {
            let newest = try await VolumeIO.run { try port.offDiskAutomaticBackups(in: parent).first?.date }
            return try await port.backupDeadline(dataRoot: dataRoot, input: .object([
                "kind": .string("deadline"), "now": .double(now.timeIntervalSince1970),
                "newest": newest.map { .double($0.timeIntervalSince1970) } ?? .null, "interval": .double(period)
            ])).map { Date(timeIntervalSince1970: $0) }
        } catch where Task.isCancelled || error is CancellationError {
            return nil
        } catch let error as PartCallError {
            await recordDeadlineFailure(cadenceFailure(error, operation: "deadline"))
            return nil
        } catch {
            nativeLog("offdisk_backup: deadline unavailable: %@", error.localizedDescription)
            await recordDeadlineFailure(.failed(error: "off-disk backup failed: \(error.localizedDescription)"))
            return nil
        }
    }

    /// Deadline reads occur outside ticks; use the same failure receipt so nil cannot erase a fault.
    private func recordDeadlineFailure(_ outcome: LoopTickOutcome) async {
        await settle {
            await BackgroundLoops.BackgroundLoopLifetimes.shared.recordOutOfBandOutcome(loopId: loopId, outcome: outcome)
        }
    }

    private func cadenceFailure(_ error: any Error, operation: String) -> LoopTickOutcome {
        let cause = "off-disk backup failed: backup-cadence part failed (\(operation)). "
            + backupCadenceRepairStep + " Error: \(error.localizedDescription)"
        nativeLog("offdisk_backup: %@", cause)
        return .failed(error: cause)
    }

    func tickOutcome() async -> LoopTickOutcome {
        // Only the live root may write or prune the person’s iCloud backup folder.
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return .skipped(reason: "alternate data root")
        }
        guard onboarded else { return .skipped(reason: "setup is not complete; the first backup runs when it is") }
        let parent = port.offDiskBackupParent()
        let port = port
        do {
            // iCloud Drive reads block on dataless folders: off the pool.
            let drive = try await VolumeIO.run { () -> (available: Bool, newest: Date?) in
                guard FileManager.default.fileExists(atPath: parent.deletingLastPathComponent().path) else { return (false, nil) }
                return (true, try port.offDiskAutomaticBackups(in: parent).first?.date)
            }
            guard !Task.isCancelled else { return .skipped(reason: "canceled") }
            guard drive.available else {
                return .skipped(reason: port.unavailableSkipPrefix + "iCloud Drive is off — no off-disk backup")
            }
            let now = Date()
            let newest = drive.newest
            let identity: JSONValue
            do {
                identity = .object(["status": .string("available"),
                    "changedAt": try identityChangedAt().map { .double($0.timeIntervalSince1970) } ?? .null])
            } catch {
                identity = .object(["status": .string("unavailable"), "error": .string(error.localizedDescription)])
            }
            let selected = try await port.backupTrigger(dataRoot: dataRoot, input: .object([
                "kind": .string("trigger"), "now": .double(now.timeIntervalSince1970),
                "newest": newest.map { .double($0.timeIntervalSince1970) } ?? .null, "identity": identity
            ]))
            if selected == .current {
                return .skipped(reason: "newest off-disk backup is current")
            }
            let trigger = selected.rawValue
            let folder = try await port.createOffDiskBackup(
                reason: "automatic off-disk backup (\(trigger))",
                dataRoot: dataRoot,
                parent: parent,
                now: now
            )
            nativeLog("offdisk_backup: wrote %@ (%@)", folder.path, trigger)
            return .completed(result: "off-disk backup \(folder.lastPathComponent) (\(trigger))")
        } catch where Task.isCancelled || error is CancellationError {
            return .skipped(reason: "canceled")
        } catch let error as PartCallError {
            return cadenceFailure(error, operation: "trigger")
        } catch {
            nativeLog("offdisk_backup: FAILED — Agent has no fresh off-disk copy: %@", String(describing: error))
            return .failed(error: "off-disk backup failed: \(error.localizedDescription)")
        }
    }

    /// Identity lives in persona-root files and the personality profile; observe both for backup freshness.
    private func identityChangedAt() throws -> Date? {
        let fm = FileManager.default
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        guard fm.fileExists(atPath: personaRoot.appendingPathComponent("SOUL.md").path) else {
            throw NSError(domain: "NativeAgentBackup", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Live persona root has no SOUL.md: \(personaRoot.path)",
            ])
        }
        var files = try fm.contentsOfDirectory(
            at: personaRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { !$0.lastPathComponent.hasSuffix(".lock") }
        let profile = dataRoot.appendingPathComponent("memory/profile.json")
        if fm.fileExists(atPath: profile.path) { files.append(profile) }
        return try files.compactMap { url -> Date? in
            let values = try url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            return values.isRegularFile == true ? values.contentModificationDate : nil
        }.max()
    }
}
