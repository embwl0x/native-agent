import Foundation
import CryptoKit
import AppKit
import Cognition
import Combine
import NativeAgentShared
import DeviceSyncState
import NativeAgentCore
import ChatTurnRuntime
import PersistenceCore
import ProviderRouting
import OSLog
import Network
// Blueprint: | `ICloudReceiving.swift` | Observer-bound receiving and CloudKit drain settlement |
extension iCloudBridge {
    public func observeIncomingMessages(onMessage: @escaping (BridgeMessage) async -> Bool) {
        // One forwarder registration replaces the previous handler.
        messageHandler = onMessage
        // Keep the transport callback bound to this bridge as well as draining
        // records that arrived before the app-side forwarder. The production
        // setup path already installs this same callback, but registering here
        // is idempotent (the transport is last-registration-wins) and prevents
        // a late/recovered observer from becoming a green bridge with no route.
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
        incomingObserverInstalled = false
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
            // Subscription registration is last-writer-wins. Retire the old
            // registration before installing its replacement, even across await.
            await previous?.value
            guard !Task.isCancelled, let self,
                  self.acceptsIncomingObserver(generation: observerGeneration) else { return }
            let subscriptionsReady = await transport.observeIncoming { [weak self] message in
                guard let self,
                      await self.acceptsIncomingObserver(generation: observerGeneration)
                else { return false }
                let handled = await self.handleIncomingFromTransport(message, observerGeneration: observerGeneration)
                guard handled, message.metadata?["kind"] == PhonePlaceEvent.messageKind
                    || message.metadata?["kind"] == PhoneRequestResult.messageKind else { return handled }
                guard message.sender == "ios", let encoded = try? PairingSecret.existingSecretBase64(),
                      let secret = Data(base64Encoded: encoded), message.verifySignature(secret: secret) else { return handled }
                // These deliveries have no answer of their own. Use the same
                // signed progress channel as chat acceptance, durably over CK.
                return (try? await self.sendChatMessage(text: "Mac received it", sessionID: message.sessionID,
                    correlationID: message.id, metadata: ["kind": "progress", "stage": "received"])) != nil
            }
            guard !Task.isCancelled, self.acceptsIncomingObserver(generation: observerGeneration)
            else { return }
            if !subscriptionsReady { self.recordCloudKitPushUnavailable() }
            self.incomingObserverInstalled = true
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
    /// CK-3b: validate + forward a message pulled from the CloudKit transport,
    /// mirroring `scanIosOutboxFiles`' checks. Returns true when the message is
    /// HANDLED (delivered OR permanently rejected) so the transport advances its
    /// cursor; false only when transiently undeliverable (runtime unavailable) so
    /// the transport re-delivers next drain (the halt-on-undelivered contract).
    @MainActor
    func handleIncomingFromTransport(_ msg: BridgeMessage, observerGeneration: UInt64? = nil) async -> Bool {
        // A shared HMAC key proves pairing, not direction. Reject before the
        // ID cache or action dispatcher can claim an attacker-selected ID.
        guard msg.sender == "ios" else {
            if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
            syncStatus = "Rejected iPhone message (CloudKit): sender_invalid"
            return true
        }
        // Already handled (persistent seen-set; the transport also dedups by id).
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
            // A phone that now signs with another Mac's key was moved there:
            // its messages are that Mac's, not an attack on this one.
            if !phonePairedElsewhere { await claimPhonePairing() }
            if phonePairedElsewhere { return true }
            // The phone's clock, like contact: an old-key message sent before
            // newer accepted ones is not the latest word.
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
            scheduleNextDeviceDrainFallback()
        }
        switch disposition {
        case .permanentlyRejected(let reason):
            if reason == "stale_timestamp" {
                if msg.metadata?["kind"] != PhonePlaceEvent.messageKind,
                   msg.metadata?["kind"] != PhoneRequestResult.messageKind {
                    // Chat and action ledgers may already own this expired request.
                    break
                }
                guard await sendIncomingRejection(msg, reason: Date() > msg.timestamp ? "request_expired" : "clock_ahead") else { return false }
            }
            nativeLog("[iCloudBridge] dropping iOS→Mac CK msg %@: %@", msg.id, reason)
            // Do not reserve the rejected envelope's caller-selected ID:
            // a fresh authenticated envelope may reuse it.
            syncStatus = "Rejected iPhone message (CloudKit): \(reason)"
            return true  // permanently rejected: consume, never wedge transport
        case .deliver:
            break
        }
        // Every signed message is the phone's contact, its answers to our
        // requests included: a phone that just answered is not silent.
        drainPolicy.notePeerActivity(at: Date())
        scheduleNextDeviceDrainFallback()
        do {
            try await SignedPeerEvidenceStore.record(
                eventID: msg.id,
                channel: .chat,
                peerCreatedAt: msg.timestamp,
                dataRoot: PersistenceCore.defaultDataRoot()
            )
            if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
            notePhoneContact(at: msg.timestamp)
        } catch {
            nativeLog("[iCloudBridge] could not persist signed peer evidence for %@: %@",
                  msg.id, error.localizedDescription)
        }
        if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
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
            let correlation = msg.metadata?["actionId"] ?? msg.id
            drainPolicy.noteOutstanding(correlation, at: Date())
            scheduleNextDeviceDrainFallback()
            defer {
                drainPolicy.resolve(correlation, at: Date())
                scheduleNextDeviceDrainFallback()
            }
            let handled = await sync.engine.processCloudKitActionMessage(msg)
            if handled {
                recordSeenMessageID(msg.id)
                persistCKSeenIDs()
                lastSyncAt = Date()
                syncStatus = "Processed iPhone action (CloudKit)"
            }
            return handled
        }
        activeCloudKitChats += 1
        defer {
            activeCloudKitChats -= 1
            scheduleNextDeviceDrainFallback()
        }
        drainPolicy.notePeerActivity(at: Date())
        scheduleNextDeviceDrainFallback()
        let delivery = await deliverIncomingChat(msg)
        if delivery != .deferred {
            if delivery == .delivered {
                await Self.appendInboundSuccessReceipt(
                    msg,
                    transport: "cloudkit",
                    secret: secret,
                    dataRoot: PersistenceCore.defaultDataRoot()
                )
            }
            if delivery != .rejected { recordSeenMessageID(msg.id) }
            // Persist consumed IDs synchronously on MainActor to prevent redelivery after restart.
            if delivery != .rejected { persistCKSeenIDs() }
            lastSyncAt = Date()
            syncStatus = "Processed iPhone request (CloudKit)"
            return true
        }
        markMacRuntimeUnavailable()
        return false  // transient — retry next drain
    }
    private func sendIncomingRejection(_ message: BridgeMessage, reason: String) async -> Bool {
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
            _ = try await sendChatMessage(text: text, sessionID: message.sessionID, correlationID: message.id,
                                          metadata: ["kind": isOutcomeError ? "error" : "rejection", "reason": reason,
                                                     "errorDetail": text,
                                                     "targetSourceKey": message.metadata?["routeKey"]
                                                        ?? message.metadata?["deviceSourceKey"]
                                                        ?? message.metadata?["sourceKey"] ?? ""])
            return true
        } catch {
            syncStatus = "iPhone response could not be sent — retaining request for retry"
            return false
        }
    }
    enum IncomingChatDelivery { case delivered, handled, rejected, deferred }
    func deliverIncomingChat(_ message: BridgeMessage) async -> IncomingChatDelivery {
        guard isSetUp, !inFlightIncomingMessageIDs.contains(message.id) else { return .deferred }
        let generation = setupGeneration
        inFlightIncomingMessageIDs.insert(message.id)
        defer {
            inFlightIncomingMessageIDs.remove(message.id)
            if generation == setupGeneration, isSetUp {
                drainPolicy.resolve(message.id, at: Date())
                scheduleNextDeviceDrainFallback()
            }
        }
        let dataRoot = PersistenceCore.defaultDataRoot()
        let reservation = await Self.reserveChat(message, dataRoot: dataRoot, canDispatch: messageHandler != nil)
        guard isSetUp, generation == setupGeneration else {
            await Self.releaseUndispatchedChat(reservation)
            return .deferred
        }
        switch reservation {
        case .completed:
            return .handled
        case .collision:
            return await sendIncomingRejection(message, reason: "message_id_collision") ? .rejected : .deferred
        case .stale:
            return await sendIncomingRejection(message, reason: Date() > message.timestamp ? "request_expired" : "clock_ahead") ? .rejected : .deferred
        case .unavailable:
            syncStatus = "iPhone request record unavailable — retaining request for retry"
            return .deferred
        case .interrupted:
            if let resent = await resendSavedReply(message, dataRoot: dataRoot) { return resent ? .handled : .deferred }
            // The checkpoint owns unfinished work; the reservation owns its saved answer.
            do {
                let record = try Self.readChat(message.id, dataRoot: dataRoot)
                let session = record.assistantSessionId ?? message.sessionID
                guard let session else { return .deferred }
                let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: session, runId: message.id)
                if response == nil, try SwiftNativeChatOrchestrationClient.hasReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: message.id) {
                    return .deferred
                }
                guard try await recoverReply(response ?? ChatResponse(runId: message.id, model: "",
                    output: "Couldn't finish the reply.", sessionId: session, terminalState: .failed),
                    route: AgentBridgeCompletionRoute(surface: "ios", sessionId: session,
                        sourceKey: message.metadata?["routeKey"] ?? message.metadata?["deviceSourceKey"] ?? message.metadata?["sourceKey"],
                        replyTo: message.metadata?["clientSurface"], correlationId: message.id)) != "owed" else { return .deferred }
                if response == nil {
                    try await Self.settleReply(message.id, session: session, sourceKey: message.metadata?["routeKey"] ?? message.metadata?["deviceSourceKey"] ?? message.metadata?["sourceKey"] ?? "",
                        state: "failed_before_answer", dataRoot: dataRoot)
                    StoreChangeBus.shared.emit(StoreChange(store: .replyDelivery, path: Self.chatURL(message.id, dataRoot: dataRoot)))
                }
                return .handled
            } catch { return .deferred }
        case .unreadable:
            // Unknown authority stays byte-preserved and never authorizes dispatch.
            return await sendIncomingRejection(message, reason: "unknown_outcome") ? .handled : .deferred
        case .reserved:
            break
        }
        drainPolicy.noteOutstanding(message.id, at: Date())
        scheduleNextDeviceDrainFallback()
        if let resent = await resendSavedReply(message, dataRoot: dataRoot) { return resent ? .handled : .deferred }
        guard isSetUp, generation == setupGeneration else {
            await Self.releaseUndispatchedChat(reservation)
            return .deferred
        }
        // After handler entry, retirement must keep its outcome record.
        let delivered = await messageHandler?(message) ?? false
        if !delivered {
            guard await sendIncomingRejection(message, reason: "unknown_outcome") else { return .deferred }
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
            lastDeviceDrainAt = Date()
            defer { scheduleNextDeviceDrainFallback() }
            let dispatched = await ck.drainIncomingControls()
            Self.pushLog.info("Cancellation drain trigger=\(trigger.rawValue, privacy: .public) dispatched=\(dispatched)")
            return dispatched > 0
        }
        return await startDeviceDrain(ck, trigger: trigger).value
    }
    /// The timer owns sleep; this handle owns the drain and awaited human turn, retaining exclusion through teardown.
    private func startDeviceDrain(_ ck: CloudKitDeviceTransport, trigger: DrainTrigger) -> Task<Bool, Never> {
        let generation = setupGeneration
        deviceDrainGeneration = generation
        lastDeviceDrainAt = Date()
        deviceDrainTriggeredByPush = trigger == .cloudKitPush
        let task = Task {
            defer {
                deviceDrainTriggeredByPush = false
                deviceDrainTask = nil
                deviceDrainGeneration = nil
                if isSetUp, deviceDrainQueued, let current = deviceTransport {
                    deviceDrainQueued = false
                    _ = startDeviceDrain(current, trigger: .coalesced)
                } else {
                    scheduleNextDeviceDrainFallback()
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
        // Keep missed-push recovery alive even when the stream emits no deltas.
        scheduleNextDeviceDrainFallback()
        // An unsettled claim, or a key change iCloud has not taken yet, is
        // retried on the drain's own cadence until it lands.
        if !phonePairingSettled || UserDefaults.standard.bool(forKey: pairingPublicationOwedKey) {
            await claimPhonePairing()
        }
        guard isSetUp, generation == setupGeneration else { return false }
        let accountGeneration = accountFailureGeneration
        let doctorGeneration = setupGeneration
        let result = await ck.drainIncoming()
        guard isSetUp, generation == setupGeneration else { return false }
        // The claim may have found another Mac while this drain was reading.
        guard !phonePairedElsewhere else { return false }
        if doctorGeneration == setupGeneration {
            switch result {
            case .success(let count):
                doctorTransportHealth = .available
                onTransportSucceeded?()
                let note = ["\(count) drained", devicePollingNote].filter { !$0.isEmpty }.joined(separator: "; ")
                OrganPulse.record("icloud_drain", found: count, note: note, cadence: deviceReceiveCadence)
            case .skipped: OrganPulse.record("icloud_drain", .skipped, note: devicePollingNote, cadence: deviceReceiveCadence)
            // No pulse: a drain that keeps failing goes overdue.
            case .failure(let error, _): doctorTransportHealth = Self.transportHealth(error)
            }
        }
        Self.pushLog.info("Incoming drain completed trigger=\(trigger.rawValue, privacy: .public) dispatched=\(result.dispatchedCount)")
        if case .failure(.account(let failure), _) = result {
            await recordAccountFailure(failure)
        }
        guard isSetUp, generation == setupGeneration else { return false }
        await ck.drainPairing()
        guard isSetUp, generation == setupGeneration else { return false }
        await ck.drainStatus()
        guard isSetUp, generation == setupGeneration else { return false }
        if case .success = result, accountGeneration == accountFailureGeneration {
            await clearAccountFailure()
        }
        return result.dispatchedCount > 0
    }
    func recordAccountFailure(_ failure: DeviceSyncAccountFailure) async {
        accountFailureGeneration &+= 1
        let changed = accountFailure != failure
        accountFailure = failure
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
        guard cleared, generation == accountFailureGeneration, accountFailure != nil else { return }
        accountFailure = nil
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
