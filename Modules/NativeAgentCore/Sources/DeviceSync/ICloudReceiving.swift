import Foundation
import CryptoKit
import AppKit
import Cognition
import Combine
import NativeAgentShared
import DeviceSyncState
import Experiences
import NativeAgentCore
import ChatTurnRuntime
import PersistenceCore
import MacControl
import ProviderRouting
import OSLog
import Network
// Blueprint: | `ICloudReceiving.swift` | Retained chat drains; separate metadata reads cannot hold pickup. |

/// The device a phone chat answers to, read once at admission; the phone writes both fields on every chat (ChatRuntimeControls.metadata).
public struct ICloudPhoneRoute: Sendable, Equatable {
    /// iphone or iphone:<device name>; every reply's targetSourceKey, so no other paired phone takes it.
    let routeKey: String
    /// The phone's client surface; the reply route's replyTo.
    let replyTo: String
    /// The only client surface the phone writes.
    static let clientSurfaces: Set<String> = ["iphone"]
    static let repairOperation = "phone.chat.route"

    /// A field the phone always sends is missing or outside its set; `routeKey` is the device a refusal can still reach, nil when none can.
    struct Malformed: Error {
        let field: String
        let words: String
        let routeKey: String?
    }

    static func read(_ metadata: [String: String]?) throws(Malformed) -> ICloudPhoneRoute {
        guard let routeKey = metadata?["routeKey"] else {
            throw Malformed(field: "routeKey", words: "The iPhone message has no routeKey, so no device can be answered.", routeKey: nil)
        }
        guard AgentBridgeCompletionRoute.isValidIOSDeviceRouteKey(routeKey) else {
            throw Malformed(field: "routeKey", words: """
                The iPhone message's routeKey "\(routeKey.prefix(80))" names no device (accepted: iphone, iphone:<device name>), so none can be \
                answered.
                """, routeKey: nil)
        }
        guard let surface = metadata?["clientSurface"], clientSurfaces.contains(surface) else {
            let given = metadata?["clientSurface"].map { "clientSurface \"\($0.prefix(40))\" is unknown" } ?? "clientSurface is missing"
            throw Malformed(field: "clientSurface", words: """
                iPhone message refused: its \(given) (accepted: \(clientSurfaces.sorted().joined(separator: ", "))). It wasn't started; update the \
                iPhone app and send it again.
                """, routeKey: routeKey)
        }
        return ICloudPhoneRoute(routeKey: routeKey, replyTo: surface)
    }
}

extension iCloudBridge {
    public func observeIncomingMessages(onMessage: @escaping (BridgeMessage, ICloudPhoneRoute) async -> Bool) {
        // Bind the callback before draining so a late observer cannot appear connected without a delivery route.
        messageHandler = onMessage
        if let ck = deviceTransport {
            registerIncomingTransportObserver(ck)
            return
        }
        checkIosOutbox()
    }
    private func acceptsIncomingObserver(generation: UInt64) -> Bool {
        isSetUp && generation == incomingObserverGeneration && deviceTransport != nil
    }
    func registerIncomingTransportObserver(_ transport: CloudKitDeviceTransport) {
        incomingObserverGeneration &+= 1
        let observerGeneration = incomingObserverGeneration
        let previous = incomingObserverTask
        previous?.cancel()
        let taskID = UUID()
        incomingObserverTaskID = taskID
        transport.setControlAdmission { [weak self] message in
            guard let self else { return false }
            return await self.admitsPhoneControl(message, generation: observerGeneration)
        }
        incomingObserverTask = Task { [weak self] in
            defer {
                if self?.incomingObserverTaskID == taskID { self?.incomingObserverTask = nil }
            }
            // Registration is last-writer-wins; retire the old callback before installing another, including across suspension.
            await previous?.value
            guard !Task.isCancelled, let self,
                  self.acceptsIncomingObserver(generation: observerGeneration) else { return }
            let subscriptionsReady = await transport.observeIncoming { [weak self] message in
                guard let self,
                      await self.acceptsIncomingObserver(generation: observerGeneration)
                else { return false }
                let handled = await self.handleIncomingFromTransport(message, observerGeneration: observerGeneration)
                guard handled, message.metadata?["kind"] == PhonePlaceEvent.messageKind
                    || message.metadata?["kind"] == PhoneSenseEvent.messageKind
                    || message.metadata?["kind"] == PhoneRequestResult.messageKind else { return handled }
                guard message.sender == "ios", let encoded = try? PairingSecret.existingSecretBase64(),
                      let secret = Data(base64Encoded: encoded), message.verifySignature(secret: secret) else { return handled }
                // Deliveries without answers still need durable signed progress so the phone can observe acceptance.
                return (try? await self.sendChatMessage(text: "Mac received it", sessionID: message.sessionID,
                    correlationID: message.id, metadata: ["kind": "progress", "stage": "received"])) != nil
            }
            guard !Task.isCancelled, self.acceptsIncomingObserver(generation: observerGeneration)
            else { return }
            if !subscriptionsReady { self.recordCloudKitPushUnavailable() }
            if self.deviceDrainTask != nil {
                self.deviceDrainQueued = true
            } else {
                _ = self.startDeviceDrain(transport, trigger: .coalesced)
            }
        }
    }
    private func admitsPhoneControl(_ message: BridgeMessage, generation: UInt64) async -> Bool {
        guard acceptsIncomingObserver(generation: generation) else { return false }
        let admitted = await incomingVerifier.admitsControl(message)
        return admitted && acceptsIncomingObserver(generation: generation)
    }
    nonisolated static func isAuthenticatedControlAction(_ message: BridgeMessage, secret: Data) -> Bool {
        guard case .deliver = ICloudIncomingMessageDisposition.classify(message, secret: secret, now: Date()),
              message.metadata?["kind"] == "icloud_action",
              let data = message.text.data(using: .utf8),
              let action = try? JSONDecoder().decode(InboxAction.self, from: data),
              ["cancelChat", "steerChat"].contains(action.action),
              let ids = InboxActionFileBoundary.validatedIDs(for: action),
              ids.messageID == message.metadata?["actionId"],
              let signature = action.signature
        else { return false }
        return BridgeMessage.innerActionSignatureError(data: data, signature: signature, secret: { secret }) == nil
    }
    /// Only handled or permanently rejected messages advance the cursor; transient runtime unavailability must permit redelivery.
    @MainActor
    func handleIncomingFromTransport(_ msg: BridgeMessage, observerGeneration: UInt64? = nil) async -> Bool {
        // HMAC proves pairing, not direction; reject before an attacker-selected id can enter caches or dispatch.
        guard msg.sender == "ios" else {
            if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
            syncStatus = "Rejected iPhone message (CloudKit): sender_invalid"
            return true
        }
        if seenMessageIDs.contains(msg.id) { return true }
        let disposition: ICloudIncomingMessageDisposition
        let secret: Data
        do {
            (disposition, secret) = try await incomingVerifier.classify(msg)
        } catch {
            syncStatus = "iPhone pairing unavailable — repair the Mac pairing key"
            nativeLog("[iCloudBridge] deferring iOS→Mac CK msg %@: %@", msg.id, error.localizedDescription)
            return false
        }
        if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
        if disposition == .permanentlyRejected(reason: "signature_invalid") {
            // A phone signing with another Mac's key belongs there; its message is not an attack on this Mac.
            if !phonePairedElsewhere { await claimPhonePairing() }
            if phonePairedElsewhere { return true }
            // An old-key message older than accepted contact is not the phone's latest word.
            let rejectedAt = min(msg.timestamp, Date())
            if rejectedAt > (lastPhoneRejectedAt ?? .distantPast) { lastPhoneRejectedAt = rejectedAt }
            if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
            syncStatus = "Rejected iPhone message (CloudKit): signature_invalid"
            return true
        }
        // Authentication suspended; a concurrent cancellation may have completed.
        if seenMessageIDs.contains(msg.id) { return true }
        if !deviceDrainTriggeredByPush, let proof = cloudKitPushProofAt,
           msg.timestamp > proof, Date().timeIntervalSince(msg.timestamp) > 16 {
            recordCloudKitPushEvidence(received: false)
        }
        switch disposition {
        case .permanentlyRejected(let reason):
            if reason == "stale_timestamp" {
                if msg.metadata?["kind"] != PhonePlaceEvent.messageKind,
                   msg.metadata?["kind"] != PhoneSenseEvent.messageKind,
                   msg.metadata?["kind"] != PhoneRequestResult.messageKind {
                    // Chat and action ledgers may already own this expired request.
                    break
                }
                // Place, sense and request-result envelopes carry no device route; the phone matches their refusal by correlation.
                guard await sendIncomingRejection(msg, reason: Date() > msg.timestamp ? "request_expired" : "clock_ahead",
                                                  routeKey: nil) else { return false }
            }
            nativeLog("[iCloudBridge] dropping iOS→Mac CK msg %@: %@", msg.id, reason)
            // Do not reserve a rejected caller-selected id; a fresh authenticated envelope may reuse it.
            syncStatus = "Rejected iPhone message (CloudKit): \(reason)"
            return true  // permanently rejected: consume, never wedge transport
        case .deliver:
            break
        }
        // Every signed reply proves contact too; a phone that just answered is not silent.
        notePhoneContact(at: msg.timestamp)
        do {
            try await SignedPeerEvidenceStore.record(
                eventID: msg.id,
                channel: .chat,
                peerCreatedAt: msg.timestamp,
                dataRoot: PersistenceCore.defaultDataRoot()
            )
            if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
        } catch {
            nativeLog("[iCloudBridge] could not persist signed peer evidence for %@: %@",
                  msg.id, error.localizedDescription)
        }
        if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
        if msg.metadata?["kind"] == PhoneSenseEvent.messageKind {
            guard let event = try? JSONDecoder().decode(PhoneSenseEvent.self, from: Data(msg.text.utf8)),
                  event.id == msg.id, event.isValid else {
                nativeLog("[iCloudBridge] invalid phone sense event %@", msg.id)
                return true
            }
            do {
                let lastInput = (MacPersonInput.idle()?.seconds).map { Date().addingTimeInterval(-$0) }
                try PhoneSenseHistory.record(event, dataRoot: PersistenceCore.defaultDataRoot(), afterPersonInput: lastInput)
                recordSeenMessageID(msg.id)
                persistCKSeenIDs()
                return true
            } catch {
                syncStatus = "iPhone sense event could not be saved: \(error.localizedDescription)"
                return false
            }
        }
        if msg.metadata?["kind"] == PhonePlaceEvent.messageKind {
            guard let event = try? JSONDecoder().decode(PhonePlaceEvent.self, from: Data(msg.text.utf8)),
                  event.id == msg.id, event.isValid else {
                nativeLog("[iCloudBridge] dropping iOS→Mac CK msg %@: %@", msg.id, "invalid_place_event")
                return true
            }
            do {
                try PhonePlaceHistory.record(event, dataRoot: PersistenceCore.defaultDataRoot())
                recordSeenMessageID(msg.id)
                persistCKSeenIDs()
                return true
            } catch {
                syncStatus = "iPhone place event could not be saved: \(error.localizedDescription)"
                return false
            }
        }
        if msg.metadata?["kind"] == PhoneRequestResult.messageKind {
            phoneRequests.receive(msg)
            recordSeenMessageID(msg.id)
            persistCKSeenIDs()
            return true
        }
        if msg.metadata?["kind"] == "icloud_action" {
            let handled = await sync.engine.processCloudKitActionMessage(msg)
            if handled {
                recordSeenMessageID(msg.id)
                persistCKSeenIDs()
                lastSyncAt = Date()
                syncStatus = "Processed iPhone action (CloudKit)"
            }
            return handled
        }
        let delivery = await deliverIncomingChat(msg)
        if delivery != .deferred {
            if delivery == .delivered || delivery == .handled {
                guard await Self.appendInboundSuccessReceipt(
                    msg,
                    transport: "cloudkit",
                    secret: secret,
                    dataRoot: PersistenceCore.defaultDataRoot()
                ) else {
                    syncStatus = "iPhone request was handled; its required receipt remains owed. The original message remains pending."
                    return false
                }
            }
            if delivery != .rejected { recordSeenMessageID(msg.id) }
            // Persist consumed IDs on MainActor before returning so restart cannot redeliver them.
            if delivery != .rejected { persistCKSeenIDs() }
            lastSyncAt = Date()
            syncStatus = "Processed iPhone request (CloudKit)"
            return true
        }
        markMacRuntimeUnavailable()
        return false  // transient — retry next drain
    }
    /// A nil routeKey sends no targetSourceKey: only envelopes that never carry a device route are refused that way.
    private func sendIncomingRejection(_ message: BridgeMessage, reason: String, routeKey: String?) async -> Bool {
        let text: String
        switch reason {
        case "request_expired":
            text = "Your Mac received this after its request window expired. It wasn't started."
        case "clock_ahead":
            text = "iPhone message rejected: its timestamp is in the future. Check both devices' clocks and try again."
        case "message_id_collision":
            text = "This message ID already belongs to a different request. This request wasn't started."
        default:
            text = "Couldn't finish the reply."
        }
        do {
            let isOutcomeError = reason == "unknown_outcome" || reason == "message_id_collision"
            var metadata = ["kind": isOutcomeError ? "error" : "rejection", "reason": reason, "errorDetail": text]
            if let routeKey { metadata["targetSourceKey"] = routeKey }
            _ = try await sendChatMessage(text: text, sessionID: message.sessionID, correlationID: message.id, metadata: metadata)
            return true
        } catch {
            syncStatus = "iPhone response could not be sent — retaining request for retry"
            return false
        }
    }
    /// A chat missing a field the phone always sends never runs. Its refusal goes only to the device it names; with no device named, the
    /// Mac owes the repair instead of answering a guessed phone.
    private func refuseMalformedChat(_ message: BridgeMessage, _ malformed: ICloudPhoneRoute.Malformed,
                                     dataRoot: URL) async -> IncomingChatDelivery {
        nativeLog("[iCloudBridge] refusing iOS chat %@: malformed %@", message.id, malformed.field)
        guard let routeKey = malformed.routeKey else {
            RepairOwed.owe(dataRoot, id: "phone-chat-route:" + message.id, kind: .run,
                operation: ICloudPhoneRoute.repairOperation, owner: "iPhone chat",
                words: malformed.words + " Message \(message.id) was not run and nothing was sent back.",
                lever: "Update the iPhone app so each chat carries \(malformed.field), then send the message again.")
            return .rejected
        }
        do {
            _ = try await sendChatMessage(text: malformed.words, sessionID: message.sessionID, correlationID: message.id,
                metadata: ["kind": "error", "reason": "malformed_request", "errorDetail": malformed.words,
                           "targetSourceKey": routeKey])
            return .rejected
        } catch {
            syncStatus = "iPhone response could not be sent — retaining request for retry"
            return .deferred
        }
    }
    enum IncomingChatDelivery { case delivered, handled, rejected, deferred }
    func deliverIncomingChat(_ message: BridgeMessage) async -> IncomingChatDelivery {
        guard isSetUp, !inFlightIncomingMessageIDs.contains(message.id) else { return .deferred }
        let generation = setupGeneration
        inFlightIncomingMessageIDs.insert(message.id)
        defer {
            inFlightIncomingMessageIDs.remove(message.id)
        }
        let dataRoot = PersistenceCore.defaultDataRoot()
        let route: ICloudPhoneRoute
        do throws(ICloudPhoneRoute.Malformed) { route = try ICloudPhoneRoute.read(message.metadata) }
        catch { return await refuseMalformedChat(message, error, dataRoot: dataRoot) }
        RepairOwed.settle(dataRoot, operation: ICloudPhoneRoute.repairOperation, evidence: .init(source: "phone-chat", id: message.id))
        let reservation = await Self.reserveChat(message, dataRoot: dataRoot, canDispatch: messageHandler != nil)
        guard isSetUp, generation == setupGeneration else {
            await Self.releaseUndispatchedChat(reservation)
            return .deferred
        }
        switch reservation {
        case .cancelled:
            do {
                let record = try Self.readChat(message.id, dataRoot: dataRoot)
                let session = record.assistantSessionId ?? message.sessionID
                // A Stop arriving after execution cannot replace its saved words or ending.
                if let session, let answer = try await SwiftNativeChatOrchestrationClient.savedReply(
                    dataRoot: dataRoot, sessionId: session, runId: message.id) {
                    guard try await recoverReply(answer, route: AgentBridgeCompletionRoute(surface: "ios",
                        sessionId: session, sourceKey: route.routeKey, replyTo: route.replyTo,
                        correlationId: message.id)) != "owed" else { return .deferred }
                } else if let session, try SwiftNativeChatOrchestrationClient.hasReplyCheckpoint(
                    dataRoot: dataRoot, sessionId: session, runId: message.id) {
                    try await MacChatTurnRuntime(dataRoot: dataRoot).stop(sessionId: session, runId: message.id)
                    return .deferred
                } else {
                    _ = try await sendChatMessage(text: "Stopped.", sessionID: message.sessionID,
                        correlationID: message.id, metadata: ["kind": "cancelled",
                            "targetSourceKey": route.routeKey])
                }
                return await Self.finishChat(message, dataRoot: dataRoot, completed: true) ? .handled : .deferred
            } catch { return .deferred }
        case .completed:
            return .handled
        case .collision:
            return await sendIncomingRejection(message, reason: "message_id_collision", routeKey: route.routeKey) ? .rejected : .deferred
        case .stale:
            return await sendIncomingRejection(message, reason: Date() > message.timestamp ? "request_expired" : "clock_ahead",
                                               routeKey: route.routeKey) ? .rejected : .deferred
        case .unavailable:
            syncStatus = "iPhone request record unavailable — retaining request for retry"
            return .deferred
        case .interrupted:
            if let resent = await resendSavedReply(message, route: route, dataRoot: dataRoot) { return resent ? .handled : .deferred }
            // The checkpoint owns unfinished work; the reservation owns its saved answer.
            do {
                let record = try Self.readChat(message.id, dataRoot: dataRoot)
                let session = record.assistantSessionId ?? message.sessionID
                guard let session else { return .deferred }
                guard let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: session, runId: message.id) else {
                    syncStatus = "iPhone reply outcome is unknown — retained request awaits the run owner's terminal evidence."
                    return .deferred
                }
                guard try await recoverReply(response,
                    route: AgentBridgeCompletionRoute(surface: "ios", sessionId: session,
                        sourceKey: route.routeKey, replyTo: route.replyTo, correlationId: message.id)) != "owed" else { return .deferred }
                return .handled
            } catch { return .deferred }
        case .unreadable:
            // Unknown authority stays byte-preserved and never authorizes dispatch.
            return await sendIncomingRejection(message, reason: "unknown_outcome", routeKey: route.routeKey) ? .handled : .deferred
        case .reserved:
            break
        }
        if let resent = await resendSavedReply(message, route: route, dataRoot: dataRoot) { return resent ? .handled : .deferred }
        guard isSetUp, generation == setupGeneration else {
            await Self.releaseUndispatchedChat(reservation)
            return .deferred
        }
        // After handler entry, retirement must keep its outcome record.
        let delivered = await messageHandler?(message, route) ?? false
        if !delivered {
            guard await sendIncomingRejection(message, reason: "unknown_outcome", routeKey: route.routeKey) else { return .deferred }
        }
        guard await Self.finishChat(message, dataRoot: dataRoot, completed: delivered) else { return .deferred }
        return delivered ? .delivered : .handled
    }
    func markMacRuntimeUnavailable() {
        syncStatus = "iPhone message waiting — Mac runtime unavailable"
    }
    // CloudKit drain triggers coalesce into one active pass and one queued pass.
    @discardableResult
    public func repairReceive() async {
        _ = await drainDeviceTransport(trigger: .repair)
    }
    func drainDeviceTransport(trigger: DrainTrigger) async -> Bool {
        guard isSetUp, let ck = deviceTransport else { return false }
        if deviceDrainTask != nil {
            Self.pushLog.info("Drain coalesced trigger=\(trigger.rawValue, privacy: .public)")
            deviceDrainQueued = true
            guard deviceDrainGeneration == setupGeneration else { return false }
            let dispatched = await ck.drainIncomingControls()
            Self.pushLog.info("Cancellation drain trigger=\(trigger.rawValue, privacy: .public) dispatched=\(dispatched)")
            return dispatched > 0
        }
        return await startDeviceDrain(ck, trigger: trigger).value
    }
    /// This handle owns the event-driven drain and awaited human turn, retaining exclusion through teardown.
    private func startDeviceDrain(_ ck: CloudKitDeviceTransport, trigger: DrainTrigger) -> Task<Bool, Never> {
        let generation = setupGeneration
        deviceDrainGeneration = generation
        deviceDrainTriggeredByPush = trigger == .cloudKitPush
        let task = Task {
            defer {
                deviceDrainTriggeredByPush = false
                deviceDrainTask = nil
                deviceDrainGeneration = nil
                if isSetUp, deviceDrainQueued, let current = deviceTransport {
                    deviceDrainQueued = false
                    _ = startDeviceDrain(current, trigger: .coalesced)
                }
                if isSetUp, generation == setupGeneration {
                    startDeviceRetentionSweepIfIdle(ck)
                }
            }
            return await runDeviceDrain(ck, trigger: trigger, generation: generation)
        }
        deviceDrainTask = task
        return task
    }
    private func runDeviceDrain(_ ck: CloudKitDeviceTransport, trigger: DrainTrigger, generation: Int) async -> Bool {
        guard isSetUp, generation == setupGeneration else { return false }
        Self.pushLog.info("Drain started trigger=\(trigger.rawValue, privacy: .public)")
        // Each receive event rechecks a claim or key publication that is still owed.
        if !phonePairingSettled || UserDefaults.standard.bool(forKey: pairingPublicationOwedKey) {
            await claimPhonePairing()
        }
        guard isSetUp, generation == setupGeneration else { return false }
        let accountGeneration = accountFailureGeneration
        let doctorGeneration = setupGeneration
        startDeviceMetadataDrainIfIdle(ck)
        let result = await ck.drainIncoming()
        guard isSetUp, generation == setupGeneration else { return false }
        // The claim may have found another Mac while this drain was reading.
        guard !phonePairedElsewhere else { return false }
        if doctorGeneration == setupGeneration {
            switch result {
            case .success(let count):
                doctorTransportHealth = .available
                onTransportSucceeded?()
                let note = ["\(count) drained", deviceReceiveNote].filter { !$0.isEmpty }.joined(separator: "; ")
                OrganPulse.record("icloud_drain", found: count, note: note, cadence: nil)
            case .skipped: OrganPulse.record("icloud_drain", .held, note: deviceReceiveNote, cadence: nil)
            // No pulse: a drain that keeps failing goes overdue.
            case .failure(let error, _): doctorTransportHealth = Self.transportHealth(error)
            }
        }
        Self.pushLog.info("Incoming drain completed trigger=\(trigger.rawValue, privacy: .public) dispatched=\(result.dispatchedCount)")
        if case .failure(.account(let failure), _) = result {
            await recordAccountFailure(failure)
        }
        guard isSetUp, generation == setupGeneration else { return false }
        if case .success = result, accountGeneration == accountFailureGeneration {
            await clearAccountFailure()
        }
        return result.dispatchedCount > 0
    }
    /// Separate serialized metadata reads from chat exclusion so slow status cannot hold the inbox.
    func startDeviceMetadataDrainIfIdle(_ ck: CloudKitDeviceTransport, force: Bool = false) {
        guard isSetUp, deviceMetadataDrainTask == nil,
              force || Date() >= nextDeviceMetadataDrainAt else { return }
        let generation = setupGeneration
        nextDeviceMetadataDrainAt = Date().addingTimeInterval(NAPhoneForegroundPresence.beat)
        deviceMetadataDrainTask = Task {
            defer { deviceMetadataDrainTask = nil }
            await ck.drainPairing()
            guard !Task.isCancelled, isSetUp, generation == setupGeneration else { return }
            await ck.drainStatus()
            guard !Task.isCancelled, isSetUp, generation == setupGeneration else { return }
            await retryOwedControlPublication()
        }
    }
    func recordAccountFailure(_ failure: DeviceSyncAccountFailure) async {
        accountFailureGeneration &+= 1
        let changed = accountFailure != failure
        accountFailure = failure
        accountFailureReadError = nil
        syncStatus = DeviceSyncAccountFailure.macMessage
        let url = ICloudSyncStatePaths.accountFailure(dataRoot: sync.dataRoot)
        await sync.storage.perform {
            guard changed || !FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(failure), to: url)
            } catch { nativeLog("[iCloudBridge] could not persist account failure: %@", error.localizedDescription) }
        }
    }
    func clearAccountFailure() async {
        accountFailureGeneration &+= 1
        let generation = accountFailureGeneration
        let url = ICloudSyncStatePaths.accountFailure(dataRoot: sync.dataRoot)
        let cleared = await sync.storage.perform {
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch {
                    nativeLog("[iCloudBridge] could not clear account failure: %@", error.localizedDescription)
                    return false
                }
            }
            return true
        }
        guard cleared, generation == accountFailureGeneration,
              accountFailure != nil || accountFailureReadError != nil else { return }
        accountFailure = nil
        accountFailureReadError = nil
        syncStatus = "CloudKit account fault cleared"
    }
    /// The Mac owns bounded CloudKit retention in a separate single-flight task that never blocks drains.
    private func startDeviceRetentionSweepIfIdle(_ ck: CloudKitDeviceTransport) {
        guard isSetUp, deviceRetentionSweepTask == nil else { return }
        deviceRetentionSweepTask = Task(priority: .utility) { [weak self] in
            await ck.sweepExpiredRecords()
            self?.deviceRetentionSweepTask = nil
        }
    }
}
