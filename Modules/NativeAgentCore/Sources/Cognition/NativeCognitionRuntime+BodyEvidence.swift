import Foundation
import MemoryV2
import ApprovalInbox
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
import NativeAgentShared
// Blueprint: | `NativeCognitionRuntime+BodyEvidence.swift` | `NativeCognitionRuntime` body evidence: phone, notification, memory, dream, tool, approval and thermal readings with debug projections |

extension NativeCognitionRuntime {
    nonisolated static func makeOrganismBodyRead(
        dataRoot: URL,
        mobileConfigured: Bool,
        now: Date = Date(),
        phoneDeliveryPrediction: OrganismPrediction? = nil
    ) async -> OrganismBodyRead {
        let signedPeer = SignedPeerEvidenceStore.load(dataRoot: dataRoot)
        let staleAfter: TimeInterval = 60 * 60 * 36
        let peerPresenceBelief = PeerPresenceBelief(
            generatedAt: now,
            evidence: signedPeer.map {
                [BodyEvidenceReference(
                    id: "signed-peer:\($0.eventID)",
                    evidenceClass: .signedPeerContact,
                    observedAt: $0.peerCreatedAt,
                    // The phone's own time, bounded by this authenticated receipt, controls freshness.
                    receivedAt: $0.contactAt
                )]
            } ?? [],
            staleAfter: staleAfter
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
        configured: Bool,
        staleAfter: TimeInterval,
        phoneDeliveryPrediction: OrganismPrediction?
    ) -> NotificationDeliveryBelief {
        let apnsPath = dataRoot
            .appendingPathComponent("mobile_push", isDirectory: true)
            .appendingPathComponent("apns_outcomes.jsonl")
        let apns = lastJSONObjectInJSONL(at: apnsPath)
        let apnsDate = (apns?["at"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        let eventID = (apns?["eventId"] as? String) ?? "apns-unknown"
        let receipts = (apns?["receipts"] as? [[String: Any]]) ?? []
        let targets = (apns?["targets"] as? NSNumber)?.intValue ?? 0
        let acceptedCount = (apns?["accepted"] as? NSNumber)?.intValue ?? 0
        var evidence: [BodyEvidenceReference] = []
        var accepted = false
        var failed = targets > acceptedCount || !(apns?["errors"] as? [String] ?? []).isEmpty
        if let apnsDate {
            for receipt in receipts {
                let status = (receipt["status"] as? String)?.lowercased()
                let httpStatus = (receipt["httpStatus"] as? NSNumber)?.intValue
                let success = status == "ok" && httpStatus.map { (200..<300).contains($0) } == true
                accepted = accepted || success
                failed = failed || !success
                let deviceID = (receipt["deviceId"] as? String) ?? "unknown"
                let apnsID = (receipt["apnsId"] as? String) ?? "unknown"
                evidence.append(BodyEvidenceReference(
                    id: "apns:\(eventID):\(deviceID):\(apnsID):\(status ?? "unknown")",
                    evidenceClass: success ? .apnsAcceptance : .notificationTransportFailure,
                    observedAt: apnsDate, receivedAt: apnsDate
                ))
            }
            // A deadline or fan-out error can leave a target without a receipt.
            if targets > receipts.count || !(apns?["errors"] as? [String] ?? []).isEmpty {
                evidence.append(BodyEvidenceReference(
                    id: "apns:\(eventID):fan-out-failed",
                    evidenceClass: .notificationTransportFailure,
                    observedAt: apnsDate, receivedAt: apnsDate
                ))
            }
        }

        var deviceReceived = false
        var deviceFailed = false
        var deviceOutcomeAt: Date?
        var deviceEvidence: BodyEvidenceReference?
        if let latest = phoneDeliveryPrediction, latest.kind == .phoneDelivery {
            deviceReceived = latest.status == .satisfied
            deviceFailed = latest.status == .violated
            deviceOutcomeAt = latest.lastUpdatedAt
            if latest.status == .satisfied || latest.status == .violated {
                deviceEvidence = BodyEvidenceReference(
                    id: "phone-delivery:\(latest.id):\(latest.status.rawValue)",
                    evidenceClass: latest.status == .satisfied
                        ? .deviceProcessReceipt
                        : .deviceProcessFailure,
                    observedAt: latest.lastUpdatedAt,
                    receivedAt: latest.lastUpdatedAt
                )
            }
        }

        if let deviceEvidence { evidence.append(deviceEvidence) }
        let latestSuccessAt = [accepted ? apnsDate : nil, deviceReceived ? deviceOutcomeAt : nil]
            .compactMap { $0 }
            .max()
        let latestFailureAt = [failed ? apnsDate : nil, deviceFailed ? deviceOutcomeAt : nil]
            .compactMap { $0 }
            .max()
        let currentlyFailed = latestFailureAt.map { failureAt in
            latestSuccessAt.map { failureAt >= $0 } ?? true
        } ?? false
        return NotificationDeliveryBelief(
            generatedAt: now,
            transportConfigured: configured,
            transportAccepted: accepted,
            deviceReceived: deviceReceived,
            // No canonical display/read receipt exists. Never promote process
            // receipt or APNS acceptance into those stronger claims.
            displayed: false,
            userSeen: false,
            transportFailed: currentlyFailed,
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
        // Do not create a missing store to answer a health read. Existing
        // SQLite is read through MemoryV2's canonical owner, never legacy JSON.
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
        let dreamRoot = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        let statePath = dreamRoot.appendingPathComponent(".dream_state.json")
        let stateDate = latestDateValue(inJSONAt: statePath, keys: ["lastdreamedat", "last_dreamed_at"])
        let newestEntryDate = newestFileModificationDate(in: dreamRoot, suffix: ".md")
        let latest = [stateDate, newestEntryDate].compactMap { $0 }.max()
        let evidence: [BodyEvidenceReference] = latest.map {
            [BodyEvidenceReference(
                id: "dream-completion:\($0.timeIntervalSince1970)",
                evidenceClass: .dreamCompletion,
                observedAt: $0,
                receivedAt: $0
            )]
        } ?? []
        let fm = FileManager.default
        let storeAvailable = fm.fileExists(atPath: dreamRoot.path)
            || fm.isWritableFile(atPath: dataRoot.path)
        return DreamIntegrityReading(
            generatedAt: now,
            storeAvailable: storeAvailable,
            completionEvidence: evidence
        )
    }

    private nonisolated static func makeToolCapabilityReading(
        dataRoot: URL,
        now: Date
    ) async -> ToolCapabilityReading {
        // Her hands are her abilities as they stand now: any one on means
        // configured; a missing or stale run leaves them unproven, never unavailable.
        let abilities = AbilityStore(dataRoot: dataRoot)
        let configured = ((try? abilities.files(kind: .part, includeProposals: false)) ?? [])
            .contains { $0.record["status"] == .string("active") }
        let rows = try? await TurnTraceRecentReader(dataRootOverride: dataRoot)
            .traceEvidence(now: now, maximumReadBytes: 128 * 1_024).rows
        let liveReceipt = rows?.reversed().compactMap { row -> [String: JSONValue]? in
            guard case .object(let object) = row, object["kind"] == .string("tool.dispatch"),
                  object["status"] == .string("ok") else { return nil }
            return object
        }.first
        let liveReceiptAt: Date? = if case .string(let raw)? = liveReceipt?["createdAt"] {
            TurnTraceEvent.parseISO8601(raw)
        } else { nil }
        let live = liveReceiptAt.map {
            $0.timeIntervalSince(now) <= 5 && now.timeIntervalSince($0) <= 6 * 60 * 60
        } == true
        var evidence: [BodyEvidenceReference] = []
        if configured {
            let date = modificationDate(abilities.root) ?? now
            evidence.append(BodyEvidenceReference(
                id: "ability-catalog:\(date.timeIntervalSince1970)",
                evidenceClass: .toolConfiguration,
                observedAt: date,
                receivedAt: date
            ))
        }
        if live, let liveReceiptAt {
            let receiptID = if case .string(let id)? = liveReceipt?["id"] { id } else { "tool-success" }
            evidence.append(BodyEvidenceReference(
                id: "tool-live:\(receiptID):\(liveReceiptAt.timeIntervalSince1970)",
                evidenceClass: .liveToolCapability,
                observedAt: liveReceiptAt,
                receivedAt: liveReceiptAt
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
                // A missing approval directory has not demonstrated a write path.
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

    /// Only the live app body senses host heat; other roots read nominal with
    /// the same evidence shape. Resource pressure never gates quiet repair.
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
        // Low Power Mode never changes what she does.
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

    private nonisolated static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Reads only a bounded tail and returns the newest complete JSON object.
    /// Receipt files can live for months; a body read must not ingest the full
    /// ledger merely to rebuild one transient delivery belief.
    private nonisolated static func lastJSONObjectInJSONL(at url: URL) -> [String: Any]? {
        let maximumBytes = 128 * 1_024
        guard let read = try? SwiftNativePersistenceCore.tailPhysicalLines(
            url, limit: maximumBytes, maxBytes: maximumBytes) else { return nil }
        let lines = read.lines.dropFirst(read.leadingFragment ? 1 : 0)
        guard lines.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) else { return nil }
        // Invalid UTF-8 makes the window unreadable; malformed JSON rows are skipped.
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            return object
        }
        return nil
    }

    private nonisolated static func latestDateValue(inJSONAt url: URL, keys: Set<String>) -> Date? {
        guard let object = jsonObject(at: url) else { return nil }
        return latestDateValue(in: object, keys: keys)
    }

    private nonisolated static func latestDateValue(in object: Any, keys: Set<String>) -> Date? {
        if let array = object as? [Any] {
            return array.compactMap { latestDateValue(in: $0, keys: keys) }.max()
        }
        guard let dictionary = object as? [String: Any] else { return nil }
        var dates: [Date] = []
        for (key, value) in dictionary {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if keys.contains(normalized),
               let string = value as? String,
               let date = parseISODate(string) {
                dates.append(date)
            }
            if let nested = latestDateValue(in: value, keys: keys) {
                dates.append(nested)
            }
        }
        return dates.max()
    }

    private nonisolated static func jsonObject(at url: URL) -> Any? {
        guard hasReadableContent(url),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private nonisolated static func parseISODate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return NativeTimestampFormat.parseISO8601FractionalFirst(trimmed)
    }

    private nonisolated static func newestFileModificationDate(in directory: URL, suffix: String) -> Date? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return urls
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }
}
