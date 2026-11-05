import Foundation
import MemoryV2
import ApprovalInbox
import Experiences
import AuthoredCapabilities
import ChatTurnRuntime
import CognitiveSubstrate
import Context
import ContextFlow
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting
import TurnTrace
import Transcripts
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
            dataRoot: dataRoot,
            now: now,
            configured: mobileConfigured,
            staleAfter: staleAfter,
            phoneDeliveryPrediction: phoneDeliveryPrediction
        )
        let memoryIntegrityReading = await makeMemoryIntegrityReading(dataRoot: dataRoot, now: now)
        let dreamIntegrityReading = makeDreamIntegrityReading(dataRoot: dataRoot, now: now)
        let toolCapabilityReading = await makeToolCapabilityReading(dataRoot: dataRoot, now: now)
        let approvalPathReading = makeApprovalPathReading(dataRoot: dataRoot, now: now)
        let resourcePressureReading = currentResourcePressureReading(dataRoot: dataRoot, now: now)

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
            approvalPathReading: approvalPathReading,
            resourcePressureReading: resourcePressureReading
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
        dataRoot: URL,
        now: Date,
        configured: Bool?,
        staleAfter: TimeInterval,
        phoneDeliveryPrediction: OrganismPrediction?
    ) -> NotificationDeliveryBelief {
        guard configured != nil else {
            let cause = bodySourceFailure(
                PersistenceCoreError.ioFailure("Phone notification target inventory is unavailable; inspect its repair obligation."),
                source: "phone notification targets", dataRoot: dataRoot)
            return NotificationDeliveryBelief(generatedAt: now, transportConfigured: configured == true,
                sourceUnavailable: cause)
        }
        // The kernel owns keyless publication and signed receipt evidence; optional APNS diagnostics cannot establish delivery.
        var evidence: [BodyEvidenceReference] = []
        var deviceReceived = false
        var deviceFailed = false
        if let latest = phoneDeliveryPrediction, latest.kind == .phoneDelivery {
            deviceReceived = latest.status == .satisfied
            deviceFailed = latest.status == .violated
            if latest.status == .satisfied || latest.status == .violated {
                evidence.append(BodyEvidenceReference(
                    id: "phone-delivery:\(latest.id):\(latest.status.rawValue)",
                    evidenceClass: latest.status == .satisfied
                        ? .deviceProcessReceipt
                        : .deviceProcessFailure,
                    observedAt: latest.lastUpdatedAt,
                    receivedAt: latest.lastUpdatedAt
                ))
            }
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
            // The newest successful dispatch receipt is a reading kept in memory; the turn never queries the record for it.
            liveReceipt = try await TurnTracePersistLane(dataRootOverride: dataRoot).newestSuccessfulReceipt(kind: "tool.dispatch")
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
    private nonisolated static func currentResourcePressureReading(
        dataRoot: URL,
        now: Date
    ) -> ResourcePressureReading {
        let sensesHost = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let thermal: OrganismResourcePressure
        switch sensesHost ? ProcessInfo.processInfo.thermalState : .nominal {
        case .nominal:
            thermal = .nominal
        case .fair:
            thermal = .elevated
        case .serious:
            thermal = .high
        case .critical:
            thermal = .critical
        @unknown default:
            thermal = .elevated
        }
        // Low Power Mode never changes what the agent does.
        return ResourcePressureReading(
            generatedAt: now,
            thermalPressure: thermal,
            evidence: [
                BodyEvidenceReference(
                    id: "thermal:\(thermal.rawValue):\(now.timeIntervalSince1970)",
                    evidenceClass: .processThermalState,
                    observedAt: now,
                    receivedAt: now
                ),
            ]
        )
    }

    nonisolated static func hasReadableContent(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 2
    }

    nonisolated static func bodySourceFailure(_ error: Error, source: String, dataRoot: URL) -> String {
        let cause = source + ": " + error.localizedDescription
        RepairOwed.owe(dataRoot, id: "body-source:" + UUID().uuidString, kind: .run,
            operation: "cognition.body:" + source, owner: source,
            words: "Body evidence is unavailable: " + cause,
            tap: "Repair the named source, preserving its bytes, then refresh the inner life.")
        return cause
    }

    func checkedPhoneNotificationConfiguration() async -> Bool? {
        do { return try await host.phoneNotificationTargetCount(dataRoot: dataRoot) > 0 }
        catch {
            _ = Self.bodySourceFailure(error, source: "phone notification targets", dataRoot: dataRoot)
            return nil
        }
    }

}
