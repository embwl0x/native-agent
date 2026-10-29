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
// Blueprint: | `iCloudBridge+ReplyDelivery.swift` | Correlated reply recovery, delivery and terminal receipts |

extension iCloudBridge {
    // MARK: - Send chat message (Drive for payload + KVS trigger)

    nonisolated public static func failedReplyClaims(dataRoot: URL, changedPath: URL? = nil) throws -> [(path: URL, at: String)] {
        let directory = dataRoot.appendingPathComponent("icloud/chat_transactions", isDirectory: true)
        if let changedPath, changedPath.deletingLastPathComponent().standardizedFileURL != directory.standardizedFileURL { return [] }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        if let changedPath, !FileManager.default.fileExists(atPath: changedPath.path) { return [] }
        let paths = try changedPath.map { [$0] } ?? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try paths.filter { $0.pathExtension == "json" }.compactMap { path in
            let record = try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: path))
            guard record.state == "failed_before_answer" else { return nil }
            let id = record.msgId
            guard !id.isEmpty, let at = record.updatedAt, record.action == "chat",
                  path.deletingPathExtension().lastPathComponent == MacSyncSnapshotIntegrity.digest(Data(id.utf8)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (path: path, at: at)
        }
    }

    public func recoverReply(_ response: ChatResponse, route: AgentBridgeCompletionRoute, priorVerdict: String? = nil) async throws -> String {
        guard let answerSession = response.sessionId, let sourceKey = route.sourceKey,
              AgentBridgeCompletionRoute.isValidIOSDeviceRouteKey(sourceKey) else {
            throw BridgeError.containerUnavailable
        }
        let session = route.sessionId ?? answerSession
        let correlation = route.correlationId ?? response.runId
        let transportID = "reply-" + MacSyncSnapshotIntegrity.digest(Data("\(answerSession)\n\(response.runId)".utf8))
        let root = sync.dataRoot
        if TurnQuietHoursWindow.holdsResidentWake(session: answerSession, dataRoot: root) { return "owed" }
        let reservation = try Self.replyReservation(correlation, session: session, sourceKey: sourceKey, dataRoot: root)
        let verdict = try await Self.replyVerdict(correlationID: correlation, runID: response.runId, dataRoot: root)
        if verdict == nil {
            var metadata = ["transport": "icloud", "source": "mac", "assistantRunId": response.runId, "replyTo": route.replyTo ?? "iphone",
                            "targetSourceKey": route.sourceKey ?? "", "canonicalAnswerRunId": response.runId,
                            "canonicalAnswerSessionId": answerSession]
            if response.terminalState == .failed {
                metadata["kind"] = "rejection"
                metadata["reason"] = "failed_before_answer"
                metadata["errorDetail"] = response.output
            }
            if let run = reservation.resendRunId { metadata["canonicalAnswerRunId"] = run }
            if let session = reservation.resendSessionId { metadata["canonicalAnswerSessionId"] = session }
            let attachments = try ICloudIncomingTurnForwarder.bridgeAttachments(from: response.attachments ?? [],
                text: response.output, sessionID: session, correlationID: correlation, metadata: metadata)
            if let priorVerdict {
                let secret = try PairingSecret.loadOrGenerateSecret()
                let message = try BridgeMessage.make(id: transportID, sender: "mac", text: response.output,
                    sessionID: session, correlationID: correlation, metadata: metadata, attachments: attachments).signed(with: secret)
                guard await Self.appendChatDeliveryReceipt(message, direction: "mac_to_ios", transport: "legacy_completion",
                    status: priorVerdict == "completed" ? .acceptedByTransport : .queuedForICloudSync,
                    secret: secret, dataRoot: root) else { throw CocoaError(.fileWriteUnknown) }
            } else {
                do {
                    _ = try await sendChatMessage(text: response.output, sessionID: session, correlationID: correlation,
                        metadata: metadata, attachments: attachments, messageID: transportID)
                } catch {
                    if error as? ChatOrchestrationError == .replyHeldForQuietHours { return "owed" }
                    guard try await Self.replyVerdict(correlationID: correlation, runID: response.runId, dataRoot: root) != nil else { throw error }
                }
            }
        }
        guard let settled = try await Self.replyVerdict(correlationID: correlation, runID: response.runId, dataRoot: root) else {
            return "owed"
        }
        try await Self.settleReply(correlation, session: session, sourceKey: sourceKey, state: settled, dataRoot: root)
        // CloudKit took it; the phone has not said it holds it, so it stays owed there.
        try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: root, sessionId: answerSession,
                                                                           runId: response.runId, verdict: "accepted_by_transport")
        return settled
    }

    nonisolated private static func replyReceipts(dataRoot: URL) async throws -> [[String: JSONValue]] {
        let path = chatDeliveryReceiptsURL(dataRoot: dataRoot)
        return try await SwiftNativePersistenceCore.withFileLock(path) { try loadChatDeliveryReceiptRows(path: path) }
    }

    nonisolated static func replyVerdict(correlationID: String, runID: String, dataRoot: URL) async throws -> String? {
        let rows = try await replyReceipts(dataRoot: dataRoot)
        return replyVerdict(rows: rows, correlationID: correlationID, runID: runID)
    }

    nonisolated private static func replyVerdict(rows: [[String: JSONValue]], correlationID: String, runID: String) -> String? {
        let statuses = rows.compactMap { fields -> String? in
            guard fields["direction"] == .string("mac_to_ios"),
                  fields["correlationId"] == .string(correlationID),
                  [JSONValue.string("reply"), .string("codex_completion")].contains(fields["kind"] ?? .null)
                    || fields["kind"] == .string("rejection") && fields["canonicalAnswerRunId"] != nil,
                  (fields["assistantRunId"] ?? fields["correlationId"]) == .string(runID)
                    || fields["kind"] == .string("codex_completion") && fields["assistantRunId"] == .string(correlationID),
                  case .string(let status)? = fields["status"] else { return nil }
            return status
        }
        if statuses.contains("accepted_by_transport") || statuses.contains("confirmed_by_peer") { return "completed" }
        return statuses.contains("queued_for_icloud_sync") ? "sent_unconfirmed" : nil
    }

    func resendSavedReply(_ message: BridgeMessage, dataRoot: URL) async -> Bool? {
        guard message.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/retry resend" else { return nil }
        do {
            guard let session = message.sessionID, NativeAgentChatSessionID.normalizedPathComponent(session) == session else { return false }
            let source = message.metadata?["routeKey"] ?? message.metadata?["deviceSourceKey"] ?? message.metadata?["sourceKey"] ?? "app"
            let route = AgentBridgeCompletionRoute(surface: "ios", sessionId: session, sourceKey: source,
                replyTo: message.metadata?["clientSurface"], correlationId: message.id)
            if try await Self.replyVerdict(correlationID: message.id, runID: message.id, dataRoot: dataRoot) != nil {
                _ = try await recoverReply(ChatResponse(runId: message.id, model: "", output: "", sessionId: session), route: route)
                return true
            }
            let record = try Self.readChat(message.id, dataRoot: dataRoot)
            var originalRun: String?
            var originalSession = session
            if let saved = record.resendSessionId { originalSession = saved }
            if let saved = record.resendRunId { originalRun = saved }
            else {
                let receipts = try await Self.replyReceipts(dataRoot: dataRoot)
                for receipt in receipts.reversed() {
                    guard receipt["direction"] == .string("mac_to_ios"),
                          receipt["kind"] == .string("reply"), receipt["sessionId"] == .string(session),
                          receipt["targetSourceKey"] == .string(source),
                          case .string(let correlation)? = receipt["correlationId"],
                          case .string(let run) = receipt["assistantRunId"] ?? receipt["correlationId"] ?? .null,
                          Self.replyVerdict(rows: receipts, correlationID: correlation, runID: run) == "sent_unconfirmed" else { continue }
                    if case .string(let canonical)? = receipt["canonicalAnswerRunId"] { originalRun = canonical }
                    else { originalRun = run }
                    if case .string(let canonical)? = receipt["canonicalAnswerSessionId"] { originalSession = canonical }
                    break
                }
            }
            var response = ChatResponse(runId: message.id, model: "", output: "There's no saved answer waiting to be delivered.", sessionId: session)
            if let originalRun, !originalRun.isEmpty {
                guard let saved = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: originalSession, runId: originalRun) else { return false }
                response = saved
                response.runId = message.id
            }
            try await Self.bindReplySession(message, sessionID: session, dataRoot: dataRoot,
                resendRunID: originalRun ?? "", resendSessionID: originalSession)
            return try await recoverReply(response, route: route) != "owed"
        } catch { return false }
    }

    public func sendChatMessage(
        text: String,
        sessionID: String? = nil,
        correlationID: String? = nil,
        metadata: [String: String]? = nil,
        attachments: [NativeAgentShared.MultimodalAttachment] = [],
        messageID: String = UUID().uuidString,
        timestamp: Date? = nil
    ) async throws -> BridgeMessage {
        let root = sync.dataRoot
        let finalReply = correlationID != nil && (metadata?["kind"] == nil
            || ["reply", "codex_completion"].contains(metadata?["kind"] ?? "")
            || metadata?["kind"] == "rejection" && metadata?["canonicalAnswerRunId"] != nil)
        func requireDeliveryAdmission() throws {
            guard finalReply || metadata?["kind"] == "text_delta" else { return }
            guard try CodexCompletionReadout.permitsDelivery(
                sessionId: metadata?["canonicalAnswerSessionId"] ?? sessionID,
                runId: metadata?["canonicalAnswerRunId"] ?? metadata?["assistantRunId"] ?? correlationID,
                configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: root), dataRoot: root) else {
                throw CocoaError(.userCancelled)
            }
        }
        try requireDeliveryAdmission()
        if (finalReply || metadata?["kind"] == "text_delta"),
           TurnQuietHoursWindow.holdsResidentWake(session: metadata?["canonicalAnswerSessionId"] ?? sessionID, dataRoot: root) {
            throw ChatOrchestrationError.replyHeldForQuietHours
        }
        let unsigned = BridgeMessage.make(
            id: messageID,
            sender: "mac",
            text: text,
            sessionID: sessionID,
            correlationID: correlationID,
            metadata: metadata,
            attachments: attachments.isEmpty ? nil : attachments,
            timestamp: timestamp ?? Date()
        )
        // Sign every outgoing envelope with the pairing secret.
        let (secret, msg) = try await sync.storage.perform {
            let secret = try PairingSecret.loadOrGenerateSecret()
            return (secret, try unsigned.signed(with: secret))
        }
        let runID = metadata?["assistantRunId"] ?? correlationID ?? messageID
        if finalReply, !inFlightReplyIDs.insert(runID).inserted { throw BridgeError.containerUnavailable }
        defer { if finalReply { inFlightReplyIDs.remove(runID) } }
        if finalReply, let correlationID {
            if try await Self.replyVerdict(correlationID: correlationID, runID: runID, dataRoot: root) != nil { return msg }
        }
        let operation: String
        if let correlationID {
            operation = "chat turn \(correlationID)" + (metadata?["kind"] == "text_delta" ? " delta" : "")
        } else {
            operation = "message \(msg.id)"
        }

        // CK-3b: CloudKit transport path. The signed BridgeMessage rides verbatim
        // in the record's payloadJSON (lossless — signature preserved), so iOS
        // verifies with the same secret exactly as on the Drive path. The shared
        // codec rejects an oversized encoded record before CloudKit sees it,
        // producing a clear user-facing error instead of an opaque server failure.
        if let ck = deviceTransport {
            do {
                try requireDeliveryAdmission()
                try await ck.send(msg) {
                    if finalReply {
                        guard await Self.appendChatDeliveryReceipt(msg, direction: "mac_to_ios", transport: "cloudkit",
                            status: .queuedForICloudSync, secret: secret, dataRoot: root) else { throw CocoaError(.fileWriteUnknown) }
                    }
                }
                if metadata?["kind"] != "text_delta", let correlationID {
                    doctorSendFailures["chat turn \(correlationID) delta"] = nil
                }
                await recordSendResult(operation: operation)
            } catch {
                syncStatus = "CloudKit did not accept message: \(error.localizedDescription)"
                await recordSendResult(operation: operation, error: error)
                if finalReply, let correlationID,
                   try await Self.replyVerdict(correlationID: correlationID, runID: runID, dataRoot: root) == "sent_unconfirmed" {
                    guard await Self.appendChatDeliveryReceipt(msg, direction: "mac_to_ios", transport: "cloudkit",
                        status: .queuedForICloudSync, secret: secret, dataRoot: root,
                        detail: error.localizedDescription) else { throw CocoaError(.fileWriteUnknown) }
                }
                throw error
            }
            await recordChatDeliveryReceipt(
                msg,
                transport: "cloudkit",
                status: .acceptedByTransport,
                secret: secret
            )
            if finalReply, let sessionID, let correlationID,
               try await Self.replyVerdict(correlationID: correlationID, runID: runID, dataRoot: root) == "completed" {
                try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: root, sessionId: sessionID,
                                                                                   runId: runID, verdict: "accepted_by_transport")
            }
            // A foreground wake is optional; CloudKit has already accepted the
            // envelope. One conflated worker nudges without holding its caller.
            enqueueMessageNudge(msg.id)
            noteOutboundToPeer(correlationID: correlationID, metadata: metadata)
            lastSyncAt = Date()
            syncStatus = "CloudKit accepted message — waiting for iOS"
            return msg
        }

        // Explicit/fail-safe legacy KVS/ubiquity path.
        guard let docsURL = driveURL else {
            throw BridgeError.containerUnavailable
        }
        let outboxURL = docsURL
            .appendingPathComponent(DriveFolder.outboxMac)
            .appendingPathComponent("\(msg.id).json")
        let data = try await sync.storage.perform {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(msg)
        }
        if finalReply {
            guard await Self.appendChatDeliveryReceipt(msg, direction: "mac_to_ios", transport: "icloud_drive",
                status: .queuedForICloudSync, secret: secret, dataRoot: root) else { throw CocoaError(.fileWriteUnknown) }
        }
        do {
            try requireDeliveryAdmission()
            try await VolumeIO.run { [data, outboxURL] in
                try FileManager.default.createDirectory(at: outboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: outboxURL, options: .atomic)
            }
        } catch {
            syncStatus = "Could not queue iCloud message: \(error.localizedDescription)"
            if finalReply {
                let exists = await VolumeIO.run { FileManager.default.fileExists(atPath: outboxURL.path) }
                guard await Self.appendChatDeliveryReceipt(msg, direction: "mac_to_ios", transport: "icloud_drive",
                    status: exists ? .queuedForICloudSync : .failedBeforeDispatch,
                    secret: secret, dataRoot: root, detail: error.localizedDescription) else { throw CocoaError(.fileWriteUnknown) }
            }
            throw error
        }
        await recordChatDeliveryReceipt(
            msg,
            transport: "icloud_drive",
            status: .queuedForICloudSync,
            secret: secret
        )

        // KVS trigger: notify iOS side that a new file is waiting in Drive
        enqueueMessageNudge(msg.id)
        if metadata?["kind"] != "text_delta" {
            await scheduleDeliveryNudges(for: msg.id)
        }

        noteOutboundToPeer(correlationID: correlationID, metadata: metadata)
        lastSyncAt = Date()
        syncStatus = "Queued for iCloud sync — waiting for iOS"
        return msg
    }

    /// E3: a delivered outbound message settles the drain cadence. Only a
    /// terminal message retires the correlation — a text_delta or progress
    /// frame proves the turn is still running, so it refreshes peer activity
    /// instead of declaring the reply sent.
    private func noteOutboundToPeer(correlationID: String?, metadata: [String: String]?) {
        defer { scheduleNextDeviceDrainFallback() }
        let now = Date()
        guard let correlationID, !correlationID.isEmpty else {
            drainPolicy.notePeerActivity(at: now)
            return
        }
        switch metadata?["kind"] {
        case "text_delta", "progress":
            drainPolicy.notePeerActivity(at: now)
        default:
            drainPolicy.resolve(correlationID, at: now)
        }
    }

    func cloudKitActionResponseMessage(_ response: [String: String], correlationID: String) throws -> BridgeMessage {
        let unsigned = BridgeMessage.make(
            sender: "mac",
            text: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
            correlationID: correlationID,
            metadata: ["kind": "icloud_action_response"]
        )
        let secret = try PairingSecret.loadOrGenerateSecret()
        return try unsigned.signed(with: secret)
    }

    /// Return the existing MacSyncEngine-signed action response over CloudKit.
    /// Trust/dispatch/receipt ownership stays in MacSyncEngine; BridgeMessage
    /// contributes transport HMAC, correlation, ordering, and retry semantics.
    func sendCloudKitActionResponse(
        _ response: [String: String],
        correlationID: String
    ) async throws {
        guard let deviceTransport else {
            throw BridgeError.containerUnavailable
        }
        do {
            let signed = try cloudKitActionResponseMessage(response, correlationID: correlationID)
            try await deviceTransport.send(signed)
            await recordSendResult(operation: "action response \(correlationID)")
            await Self.appendActionResponseDeliveryReceipt(
                response: response,
                correlationID: correlationID,
                transport: "cloudkit",
                status: .acceptedByTransport,
                dataRoot: PersistenceCore.defaultDataRoot()
            )
            drainPolicy.resolve(correlationID, at: Date())
            scheduleNextDeviceDrainFallback()
            lastSyncAt = Date()
            syncStatus = "Sent action response via CloudKit"
        } catch {
            // Do not leave a prior green send painted as current health. The
            // durable response remains available to MacSync for a restart-safe
            // resend, but the bridge state must say that this attempt failed.
            syncStatus = "CloudKit action response waiting to resend: \(error.localizedDescription)"
            await recordSendResult(operation: "action response \(correlationID)", error: error)
            throw error
        }
    }

    private func recordChatDeliveryReceipt(
        _ message: BridgeMessage,
        transport: String,
        status: ChatDeliveryReceiptStatus,
        secret: Data,
        direction: String = "mac_to_ios"
    ) async {
        await Self.appendChatDeliveryReceipt(
            message,
            direction: direction,
            transport: transport,
            status: status,
            secret: secret,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    private func enqueueMessageNudge(_ messageID: String) {
        let sender: ICloudConflatedSender
        if let messageNudgeSender { sender = messageNudgeSender }
        else {
            sender = ICloudConflatedSender()
            messageNudgeSender = sender
        }
        let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(messageID)"
        sender.submit(key: KVSKey.newMessageInDrive) {
            _ = await withCKTimeout("iCloudBridge.messageNudge", seconds: 3) {
                let kvs = NSUbiquitousKeyValueStore.default
                kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
                return kvs.synchronize()
            }
        }
    }

    private func scheduleDeliveryNudges(for messageID: String) async {
        let queue: ICloudDeliveryNudgeQueue
        if let deliveryNudgeQueue {
            queue = deliveryNudgeQueue
        } else {
            queue = ICloudDeliveryNudgeQueue(
                isAvailable: { [weak self] in
                    await self?.available ?? false
                },
                sendNudge: { messageID in
                    let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(messageID)"
                    return await withCKTimeout(
                        "iCloudBridge.deliveryNudge.kvsTrigger",
                        seconds: 3
                    ) {
                        let kvs = NSUbiquitousKeyValueStore.default
                        kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
                        return kvs.synchronize()
                    } ?? false
                },
                observeOutcome: { [weak self] outcome in
                    await self?.recordDeliveryNudgeOutcome(outcome)
                }
            )
            deliveryNudgeQueue = queue
        }
        await queue.schedule(for: messageID)
    }

    private func recordDeliveryNudgeOutcome(_ outcome: ICloudDeliveryNudgeOutcome) {
        switch outcome.disposition {
        case .synchronized:
            break
        case .unavailable:
            syncStatus = "iCloud delivery nudge skipped: iCloud unavailable"
        case .synchronizeFailed:
            syncStatus = "iCloud delivery nudge failed: iOS will retry on its next sync"
        }
    }
}
