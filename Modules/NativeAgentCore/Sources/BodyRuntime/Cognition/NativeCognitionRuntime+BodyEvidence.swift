import Foundation
import os
import MindCore
import MacNerves
import SenseCore
import NativeAgentCore
import DeskCore
import PersistenceCore
import ProviderRouting
import NativeAgentShared
// Blueprint: | `NativeCognitionRuntime+BodyEvidence.swift` | `NativeCognitionRuntime`. |

extension NativeCognitionRuntime {
    nonisolated static func makeOrganismBodyRead(
        dataRoot: URL,
        mobileConfigured: Bool?,
        now: Date = Date(),
        phoneDeliveryPrediction: OrganismPrediction? = nil
    ) async -> OrganismBodyRead {
        let signedPeer: SignedPeerEvidence?
        var peerReadFailure: String?
        do { signedPeer = try SignedPeerEvidenceStore.load(dataRoot: dataRoot) }
        catch {
            signedPeer = nil
            peerReadFailure = bodySourceFailure(error, source: "mobile/signed_peer_evidence.json", dataRoot: dataRoot)
        }
        let staleAfter: TimeInterval = 60 * 60 * 36
        let peerPresenceBelief = PeerPresenceBelief(
            generatedAt: now,
            evidence: signedPeer.map {
                [BodyEvidenceReference(
                    id: "signed-peer:\($0.eventID)",
                    evidenceClass: .signedPeerContact,
                    observedAt: $0.peerCreatedAt,
                    // Bound authenticated phone timestamps by receipt time before judging freshness.
                    receivedAt: $0.contactAt
                )]
            } ?? [],
            staleAfter: staleAfter, sourceUnavailable: peerReadFailure
        )
        let notificationDeliveryBelief = notificationDeliveryReading(
            now: now,
            configured: mobileConfigured,
            staleAfter: staleAfter,
            phoneDeliveryPrediction: phoneDeliveryPrediction
        )
        settleStoppedBodyReads(dataRoot: dataRoot)
        let memoryIntegrityReading = await makeMemoryIntegrityReading(dataRoot: dataRoot, now: now)
        let dreamIntegrityReading = makeDreamIntegrityReading(dataRoot: dataRoot, now: now)
        let toolCapabilityReading = await makeToolCapabilityReading(dataRoot: dataRoot, now: now)
        let approvalPathReading = makeApprovalPathReading(dataRoot: dataRoot, now: now)

        let providersAvailable = SwiftNativeProviderRouting(dataRoot: dataRoot).hasUsableCredentials()
        return OrganismBodyRead(
            macAwake: true,
            iPhoneStaleAfter: staleAfter,
            providersAvailable: providersAvailable,
            peerPresenceBelief: peerPresenceBelief,
            notificationDeliveryBelief: notificationDeliveryBelief,
            memoryIntegrityReading: memoryIntegrityReading,
            dreamIntegrityReading: dreamIntegrityReading,
            toolCapabilityReading: toolCapabilityReading,
            approvalPathReading: approvalPathReading
        )
    }

    nonisolated static func simulatedOrganismBodyRead(
        base: OrganismBodyRead,
        scenario: OrganismDebugBodyScenario,
        now: Date = Date()
    ) -> OrganismBodyRead {
        var read = base
        switch scenario {
        case .providerBrittle:
            read.providerPathBelief = ProviderPathEstimate(
                generatedAt: now,
                estimate: 0.05,
                freshness: 1,
                uncertainty: 0,
                evidenceCount: 1,
                newestEvidenceAt: now
            )
            read.toolCapabilityReading = ToolCapabilityReading(
                generatedAt: now,
                configured: false,
                liveCapabilityObserved: false,
                evidence: []
            )
        case .stalePhone:
            let staleAt = now.addingTimeInterval(-(read.iPhoneStaleAfter + 60))
            read.peerPresenceBelief = PeerPresenceBelief(
                generatedAt: now,
                evidence: [BodyEvidenceReference(
                    id: "debug-stale-peer",
                    evidenceClass: .signedPeerContact,
                    observedAt: staleAt,
                    receivedAt: staleAt
                )],
                staleAfter: read.iPhoneStaleAfter
            )
            read.notificationDeliveryBelief = NotificationDeliveryBelief(
                generatedAt: now,
                transportConfigured: true,
                transportFailed: true,
                evidence: [BodyEvidenceReference(
                    id: "debug-notification-failure",
                    evidenceClass: .notificationTransportFailure,
                    observedAt: now,
                    receivedAt: now
                )]
            )
        case .resourceTight:
            read.resourcePressureReading = ResourcePressureReading(
                generatedAt: now,
                thermalPressure: .critical,
                evidence: [BodyEvidenceReference(
                    id: "debug-resource-critical",
                    evidenceClass: .processThermalState,
                    observedAt: now,
                    receivedAt: now
                )]
            )
        case .memoryBrittle:
            read.memoryIntegrityReading = MemoryIntegrityReading(
                generatedAt: now,
                storeAvailable: true,
                maintenanceSucceeded: false,
                evidence: [BodyEvidenceReference(
                    id: "debug-memory-maintenance-failure",
                    evidenceClass: .maintenanceReceipt,
                    observedAt: now,
                    receivedAt: now
                )]
            )
        case .approvalClosed:
            read.approvalPathReading = ApprovalPathReading(
                generatedAt: now,
                writable: false,
                evidence: [BodyEvidenceReference(
                    id: "debug-approval-closed",
                    evidenceClass: .approvalStore,
                    observedAt: now,
                    receivedAt: now
                )]
            )
        }
        return read
    }

    private nonisolated static func notificationDeliveryReading(
        now: Date,
        configured: Bool?,
        staleAfter: TimeInterval,
        phoneDeliveryPrediction: OrganismPrediction?
    ) -> NotificationDeliveryBelief {
        guard configured != nil else {
            return NotificationDeliveryBelief(generatedAt: now, transportConfigured: false,
                sourceUnavailable: "Phone notification target inventory is unavailable.")
        }
        // The kernel owns keyless publication and signed receipt evidence; optional APNS diagnostics cannot establish delivery.
        var evidence: [BodyEvidenceReference] = []
        var deviceReceived = false
        var deviceFailed = false
        if let latest = phoneDeliveryPrediction, latest.kind == .phoneDelivery {
            deviceReceived = latest.status == .satisfied
            deviceFailed = latest.status == .violated
            let evidenceClass: BodyEvidenceClass
            let at: Date
            switch latest.status {
            case .satisfied: (evidenceClass, at) = (.deviceProcessReceipt, latest.lastUpdatedAt)
            case .violated: (evidenceClass, at) = (.deviceProcessFailure, latest.lastUpdatedAt)
            case .pending, .expired: (evidenceClass, at) = (.deliveryAttempt, latest.createdAt)
            }
            evidence.append(BodyEvidenceReference(
                id: "phone-delivery:\(latest.id):\(latest.status.rawValue)",
                evidenceClass: evidenceClass,
                observedAt: at,
                receivedAt: at
            ))
        }
        return NotificationDeliveryBelief(
            generatedAt: now,
            transportConfigured: configured == true,
            deviceReceived: deviceReceived,
            // Without canonical display/read receipts, process receipt or APNS acceptance cannot prove either.
            displayed: false,
            userSeen: false,
            transportFailed: deviceFailed,
            evidence: evidence,
            staleAfter: staleAfter
        )
    }

    private nonisolated static func makeMemoryIntegrityReading(
        dataRoot: URL,
        now: Date
    ) async -> MemoryIntegrityReading {
        let path = dataRoot.appendingPathComponent("memory/memory.sqlite")
        var readable = false
        // Health reads cannot create a missing store; read existing SQLite through MemoryV2's canonical owner.
        if FileManager.default.isReadableFile(atPath: path.path) {
            do {
                let store = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
                _ = try await store.statusCounts()
                readable = true
            } catch {
                readable = false
            }
        }
        return MemoryIntegrityReading(
            generatedAt: now,
            storeAvailable: readable,
            maintenanceSucceeded: nil,
            evidence: [BodyEvidenceReference(
                id: "memory-read:\(readable):\(now.timeIntervalSince1970)",
                evidenceClass: .localStoreRead,
                observedAt: now, receivedAt: now
            )]
        )
    }

    private nonisolated static func makeDreamIntegrityReading(
        dataRoot: URL,
        now: Date
    ) -> DreamIntegrityReading {
        let latest: Date?
        do { latest = try ConversationHistory.dreamConsolidationMark(dataRoot: dataRoot) }
        catch {
            _ = bodySourceFailure(error, source: "dream_diary/.dream_state.json", dataRoot: dataRoot)
            return DreamIntegrityReading(generatedAt: now, storeAvailable: false, completionEvidence: [])
        }
        let evidence: [BodyEvidenceReference] = latest.map {
            [BodyEvidenceReference(
                id: "dream-completion:\($0.timeIntervalSince1970)",
                evidenceClass: .dreamCompletion,
                observedAt: $0,
                receivedAt: $0
            )]
        } ?? []
        return DreamIntegrityReading(
            generatedAt: now,
            storeAvailable: true,
            completionEvidence: evidence
        )
    }

    private nonisolated static func makeToolCapabilityReading(
        dataRoot: URL,
        now: Date
    ) async -> ToolCapabilityReading {
        // Enabled abilities establish configuration; missing or stale runs remain unproven rather than unavailable.
        let abilities = AbilityStore(dataRoot: dataRoot)
        let configured: Bool
        let liveReceipt: (id: String, at: Date)?
        let configurationDate: Date?
        do {
            configured = try abilities.files(kind: .part, includeProposals: false)
                .contains { $0.record["status"] == .string("active") }
            if configured {
                guard let date = try FileManager.default.attributesOfItem(atPath: abilities.root.path)[.modificationDate] as? Date else {
                    throw PersistenceCoreError.ioFailure("Ability configuration modification time is unavailable.")
                }
                configurationDate = date
            } else { configurationDate = nil }
            liveReceipt = try await TurnTracePersistLane(dataRootOverride: dataRoot).newestSuccessfulDispatch()
        } catch {
            let cause = bodySourceFailure(error, source: "abilities and the life record", dataRoot: dataRoot)
            return ToolCapabilityReading(generatedAt: now, configured: false, liveCapabilityObserved: false,
                evidence: [], sourceUnavailable: cause)
        }
        let live = liveReceipt.map(\.at).map {
            $0.timeIntervalSince(now) <= 5 && now.timeIntervalSince($0) <= 6 * 60 * 60
        } == true
        var evidence: [BodyEvidenceReference] = []
        if let date = configurationDate {
            evidence.append(BodyEvidenceReference(
                id: "ability-catalog:\(date.timeIntervalSince1970)",
                evidenceClass: .toolConfiguration,
                observedAt: date,
                receivedAt: date
            ))
        }
        if live, let liveReceipt {
            evidence.append(BodyEvidenceReference(
                id: "tool-live:\(liveReceipt.id):\(liveReceipt.at.timeIntervalSince1970)",
                evidenceClass: .liveToolCapability,
                observedAt: liveReceipt.at,
                receivedAt: liveReceipt.at
            ))
        }
        return ToolCapabilityReading(
            generatedAt: now,
            configured: configured || live,
            liveCapabilityObserved: live,
            evidence: evidence
        )
    }

    private nonisolated static func makeApprovalPathReading(
        dataRoot: URL,
        now: Date
    ) -> ApprovalPathReading {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let path = inbox.approvalsPath
        let directory = path.deletingLastPathComponent()
        let fm = FileManager.default
        let writable: Bool?
        do {
            _ = try inbox.recordsUnlocked()
            if fm.fileExists(atPath: directory.path) {
                writable = fm.isWritableFile(atPath: directory.path)
                    && (!fm.fileExists(atPath: path.path) || fm.isWritableFile(atPath: path.path))
            } else {
                // A missing approval directory cannot demonstrate a write path.
                writable = nil
            }
        } catch {
            writable = false
        }
        return ApprovalPathReading(
            generatedAt: now,
            writable: writable,
            evidence: [BodyEvidenceReference(
                id: "approval-path:\(writable.map(String.init) ?? "unknown"):\(now.timeIntervalSince1970)",
                evidenceClass: .approvalStore,
                observedAt: now,
                receivedAt: now
            )]
        )
    }

    /// Only the live body senses host heat; other roots use nominal evidence. Resource pressure never gates quiet repair.
    func resourcePressureSample() async -> (reading: ResourcePressureReading?, fixedAt: Date) {
        let sensesHost = usesLiveAppBody
        let sample: (pressure: OrganismResourcePressure, observedAt: Date)?
        if sensesHost, let engine = try? rootEngine(), let field = engine.bodyField {
            sample = await field.currentThermalPressure(in: dataRoot)
        } else {
            sample = nil
        }
        let fixedAt = now()
        if sensesHost, sample == nil { return (nil, fixedAt) }
        let (thermal, observedAt) = sample ?? (.nominal, fixedAt)
        // Low Power Mode never changes what the agent does.
        let reading = ResourcePressureReading(
            generatedAt: fixedAt,
            thermalPressure: thermal,
            evidence: [
                BodyEvidenceReference(
                    id: "thermal:\(thermal.rawValue):\(observedAt.timeIntervalSince1970)",
                    evidenceClass: .processThermalState,
                    observedAt: observedAt,
                    receivedAt: observedAt
                ),
            ]
        )
        return (reading, fixedAt)
    }

    /// A body read that was stopped was never a failed source. Rows filed for one, before a stop was told apart from a failure, are
    /// settled once a launch; a source that truly failed keeps its row.
    private static let stoppedReadsSettled = OSAllocatedUnfairLock(initialState: false)
    nonisolated static func settleStoppedBodyReads(dataRoot: URL) {
        guard stoppedReadsSettled.withLock({ done in defer { done = true }; return !done }) else { return }
        _ = ExperienceStore.record(dataRoot, "repair:cognition.body") { store in
            for owed in try await store.open() where owed.owes["repair"]?.phase.isSettled == false
                && RepairDebt(owed).operation?.hasPrefix("cognition.body:") == true
                && owed.face?.words.contains("CancellationError") == true {
                try await store.append([.obligation(key: "repair", phase: .accepted, evidence: .init(source: "stop", id: owed.id))], to: owed.id)
            }
        }
    }

    nonisolated static func bodySourceFailure(_ error: Error, source: String, dataRoot: URL) -> String {
        let cause = source + ": " + error.localizedDescription
        if error is CancellationError { return cause }
        RepairOwed.owe(dataRoot, id: "body-source:" + UUID().uuidString, kind: .run,
            operation: "cognition.body:" + source, owner: source,
            words: "Body evidence is unavailable: " + cause,
            tap: "Repair the named source, preserving its bytes, then refresh the inner life.")
        return cause
    }

    func checkedPhoneNotificationConfiguration() async -> Bool? {
        do { return try await SwiftNativeAPNSSender().deliverableTargetCount(dataRoot: dataRoot) > 0 }
        catch {
            _ = Self.bodySourceFailure(error, source: "phone notification targets", dataRoot: dataRoot)
            return nil
        }
    }

}
