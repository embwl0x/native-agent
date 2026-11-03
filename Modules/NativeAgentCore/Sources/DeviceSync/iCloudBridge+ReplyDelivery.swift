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
// Blueprint: | `iCloudBridge+ReplyDelivery.swift` | Correlated reply recovery accepts only observed transport acceptance; retained signed publications reconcile by original identity with checked receipts; fair event-driven steering outcome redelivery and stable action response identities; canonical terminal kinds and continuation run correlation |

extension iCloudBridge {
    /// Re-signal one retained control outcome per existing receive/repair event.
    /// No event means it remains owed on disk; no timer or new identity is minted.
    func retryOwedControlPublication() async {
        let root = sync.dataRoot
        let directory = root.appendingPathComponent("icloud/chat_transactions", isDirectory: true)
        do {
            let pending: ([BridgeMessage], [String]) = try await sync.storage.perform {
                let files: [URL]
                do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { return ([], []) }
                var gaps: [String] = []
                var messages: [BridgeMessage] = []
                for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
                    do {
                        let row = try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: file))
                        guard row.direction == "mac_to_ios", row.state != "completed", let saved = row.outboundMessage,
                              ["steered", "steer_returned"].contains(saved.metadata?["kind"] ?? "") else { continue }
                        guard Self.chatURL(saved.id, dataRoot: root) == file, row.msgId == saved.id else { throw CocoaError(.fileReadCorruptFile) }
                        messages.append(saved)
                    } catch { gaps.append("\(file.lastPathComponent): \(error.localizedDescription)") }
                }
                return (messages, gaps)
            }
            if !pending.1.isEmpty { syncStatus = "Retained phone publications are unreadable: " + pending.1.joined(separator: "; ") }
            // Persisted rows own their bytes; memory holds only not-yet-filed outcomes.
            let candidates = (pending.0 + Array(pendingControlPublications.values)).sorted { $0.id < $1.id }
            guard let message = candidates.first(where: { $0.id > controlPublicationCursor }) ?? candidates.first else { return }
            controlPublicationCursor = message.id
            _ = try await sendChatMessage(text: message.text, sessionID: message.sessionID,
                correlationID: message.correlationID, metadata: message.metadata,
                attachments: message.attachments ?? [], messageID: message.id, timestamp: message.timestamp)
        } catch {
            syncStatus = "Phone steering outcome delivery remains owed: \(error.localizedDescription)"
        }
    }

    /// Send admission, receipt validation and recovery agree about which
    /// envelopes settle a canonical answer, including live failure/Stop.
    nonisolated static func isRetainedChatReply(kind: String?, canonicalRun: String?) -> Bool {
        kind == nil || ["reply", "final", "codex_completion"].contains(kind ?? "")
            || canonicalRun != nil && ["rejection", "error", "cancelled", "incomplete"].contains(kind ?? "")
    }
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

    public func recoverReply(_ response: ChatResponse, route: AgentBridgeCompletionRoute, priorVerdict: String? = nil,
                             liveTurn: Bool = false) async throws -> String {
        guard let answerSession = response.sessionId, let sourceKey = route.sourceKey,
              AgentBridgeCompletionRoute.isValidIOSDeviceRouteKey(sourceKey) else {
            throw BridgeError.containerUnavailable
        }
        let session = route.sessionId ?? answerSession
        // A new turn after a phone request has settled is a live turn in that
        // conversation. Its snapshots and terminal must resolve the same run.
        let liveContinuation = liveTurn || route.correlationId != response.runId
        let correlation = liveContinuation ? response.runId : route.correlationId ?? response.runId
        let transportID = "reply-" + MacSyncSnapshotIntegrity.digest(Data("\(answerSession)\n\(response.runId)".utf8))
        let root = sync.dataRoot
        if TurnQuietHoursWindow.holdsResidentWake(session: answerSession, dataRoot: root) { return "owed" }
        let reservation = try Self.replyReservation(correlation, session: session, sourceKey: sourceKey, dataRoot: root)
        let verdict = try await Self.replyVerdict(correlationID: correlation, runID: response.runId, dataRoot: root)
        if verdict != "completed" {
            var metadata = ["transport": "icloud", "source": "mac", "assistantRunId": response.runId, "replyTo": route.replyTo ?? "iphone",
                            "targetSourceKey": route.sourceKey ?? "", "canonicalAnswerRunId": response.runId,
                            "canonicalAnswerSessionId": answerSession]
            if liveContinuation { metadata["live"] = "true" }
            // Canonical ending is independent of the transport correlation.
            switch response.terminalState {
            case .failed:
                metadata["kind"] = "error"
                metadata["errorDetail"] = response.statusDetail ?? "The reply could not be completed."
            case .stopped: metadata["kind"] = "cancelled"
            case .waiting, .interrupted:
                metadata["kind"] = "incomplete"
                metadata["status"] = response.statusDetail ?? response.terminalState?.rawValue
            case .completed: metadata["kind"] = "final"
            case nil:
                metadata["kind"] = "incomplete"
                metadata["status"] = "The saved reply has no terminal state."
            }
            if response.terminalState != .completed, !response.output.isEmpty { metadata["partialReply"] = "true" }
            if let run = reservation.resendRunId { metadata["canonicalAnswerRunId"] = run }
            if let session = reservation.resendSessionId { metadata["canonicalAnswerSessionId"] = session }
            if let priorVerdict {
                guard priorVerdict == "completed" else { return "owed" }
                let attachments = try ICloudIncomingTurnForwarder.bridgeAttachments(from: response.attachments ?? [],
                    text: response.output, sessionID: session, correlationID: correlation, metadata: metadata)
                let secret = try PairingSecret.loadOrGenerateSecret()
                let message = try BridgeMessage.make(id: transportID, sender: "mac", text: response.output,
                    sessionID: session, correlationID: correlation, metadata: metadata, attachments: attachments).signed(with: secret)
                guard await Self.appendChatDeliveryReceipt(message, direction: "mac_to_ios", transport: "legacy_completion",
                    status: .acceptedByTransport,
                    secret: secret, dataRoot: root) else { throw CocoaError(.fileWriteUnknown) }
            } else {
                do {
                    if let saved = try await sync.storage.perform({
                        try Self.retainedReplyPublication(correlationID: correlation, runID: response.runId, dataRoot: root)
                    }) {
                        guard saved.sessionID == session else { throw DeviceSyncError.conflict }
                        if let target = saved.metadata?["targetSourceKey"], target != sourceKey { throw DeviceSyncError.conflict }
                        _ = try await sendChatMessage(text: saved.text, sessionID: saved.sessionID, correlationID: saved.correlationID,
                            metadata: saved.metadata, attachments: saved.attachments ?? [], messageID: saved.id, timestamp: saved.timestamp)
                    } else {
                        let attachments = try ICloudIncomingTurnForwarder.bridgeAttachments(from: response.attachments ?? [],
                            text: response.output, sessionID: session, correlationID: correlation, metadata: metadata)
                        _ = try await sendChatMessage(text: response.output, sessionID: session, correlationID: correlation,
                            metadata: metadata, attachments: attachments, messageID: transportID)
                    }
                } catch {
                    if error as? ChatOrchestrationError == .replyHeldForQuietHours { return "owed" }
                    guard try await Self.replyVerdict(correlationID: correlation, runID: response.runId, dataRoot: root) == "completed" else { throw error }
                }
            }
        }
        guard let settled = try await Self.replyVerdict(correlationID: correlation, runID: response.runId, dataRoot: root), settled == "completed" else {
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
                  isRetainedChatReply(kind: fields["kind"]?.stringValue, canonicalRun: fields["canonicalAnswerRunId"]?.stringValue),
                  (fields["assistantRunId"] ?? fields["correlationId"]) == .string(runID)
                    || fields["kind"] == .string("codex_completion") && fields["assistantRunId"] == .string(correlationID),
                  case .string(let status)? = fields["status"] else { return nil }
            return status
        }
        if statuses.contains("accepted_by_transport") || statuses.contains("confirmed_by_peer") { return "completed" }
        // An unverified commit is unknown, not sent: it stays owed, so recovery
        // resends it (the phone keeps one reply per correlation).
        if statuses.contains("queued_for_icloud_sync") || statuses.contains("submission_unknown") || statuses.contains("commit_unverified") { return "sent_unconfirmed" }
        return statuses.contains("dispatch_reserved") ? "reserved" : nil
    }

    func resendSavedReply(_ message: BridgeMessage, dataRoot: URL) async -> Bool? {
        guard message.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/retry resend" else { return nil }
        do {
            guard let session = message.sessionID, NativeAgentChatSessionID.normalizedPathComponent(session) == session else { return false }
            let source = message.metadata?["routeKey"] ?? message.metadata?["deviceSourceKey"] ?? message.metadata?["sourceKey"] ?? "app"
            let route = AgentBridgeCompletionRoute(surface: "ios", sessionId: session, sourceKey: source,
                replyTo: message.metadata?["clientSurface"], correlationId: message.id)
            if try await Self.replyVerdict(correlationID: message.id, runID: message.id, dataRoot: dataRoot) == "completed" {
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
                          Self.isRetainedChatReply(kind: receipt["kind"]?.stringValue, canonicalRun: receipt["canonicalAnswerRunId"]?.stringValue),
                          receipt["sessionId"] == .string(session),
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
            var response = ChatResponse(runId: message.id, model: "", output: "There's no saved answer waiting to be delivered.", sessionId: session, terminalState: .completed)
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
        let finalReply = correlationID != nil && Self.isRetainedChatReply(
            kind: metadata?["kind"], canonicalRun: metadata?["canonicalAnswerRunId"])
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
        let (secret, signed) = try await sync.storage.perform {
            let secret = try PairingSecret.loadOrGenerateSecret()
            return (secret, try unsigned.signed(with: secret))
        }
        let runID = metadata?["assistantRunId"] ?? correlationID ?? messageID
        if finalReply, !inFlightReplyIDs.insert(runID).inserted { throw BridgeError.containerUnavailable }
        defer { if finalReply { inFlightReplyIDs.remove(runID) } }
        let retainedPublication = finalReply || ["steered", "steer_returned"].contains(metadata?["kind"] ?? "")
        let controlPublication = ["steered", "steer_returned"].contains(metadata?["kind"] ?? "")
        if controlPublication, pendingControlPublications[messageID] == nil { pendingControlPublications[messageID] = signed }
        if finalReply, let correlationID {
            let verdict = try await Self.replyVerdict(correlationID: correlationID, runID: runID, dataRoot: root)
            if verdict == "completed" { return signed }
            if verdict != nil, !FileManager.default.fileExists(atPath: Self.chatURL(messageID, dataRoot: root).path) {
                throw DeviceSyncSendOutcomeUnknown(message: "The retained reply has no original signed envelope; reconcile its server/phone evidence before resubmission. Its checkpoint remains owed.")
            }
        }
        let msg: BridgeMessage
        if retainedPublication {
            msg = try await Self.retainPublication(pendingControlPublications[messageID] ?? signed, secret: secret, dataRoot: root)
            if controlPublication { pendingControlPublications[messageID] = nil }
        }
        else { msg = signed }
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
                            status: .dispatchReserved, secret: secret, dataRoot: root) else { throw CocoaError(.fileWriteUnknown) }
                    }
                }
                if metadata?["kind"] != "text_delta", let correlationID {
                    doctorSendFailures["chat turn \(correlationID) delta"] = nil
                }
                await recordSendResult(operation: operation)
            } catch {
                syncStatus = "CloudKit message submission is unconfirmed: \(error.localizedDescription)"
                await recordSendResult(operation: operation, error: error)
                if retainedPublication {
                    guard await Self.appendChatDeliveryReceipt(msg, direction: "mac_to_ios", transport: "cloudkit",
                        status: .submissionUnknown, secret: secret, dataRoot: root,
                        detail: error.localizedDescription) else { throw CocoaError(.fileWriteUnknown) }
                }
                throw error
            }
            do {
                try await recordChatDeliveryReceipt(
                    msg,
                    transport: "cloudkit",
                    status: .acceptedByTransport,
                    secret: secret
                )
                if retainedPublication { try await Self.completePublication(msg.id, dataRoot: root) }
                if controlPublication { pendingControlPublications[messageID] = nil }
                if finalReply, let sessionID, let correlationID,
                   try await Self.replyVerdict(correlationID: correlationID, runID: runID, dataRoot: root) == "completed" {
                    try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: root, sessionId: sessionID,
                                                                                       runId: runID, verdict: "accepted_by_transport")
                }
            } catch {
                throw DeviceSyncSendOutcomeUnknown(message: "CloudKit accepted the message, but local settlement failed: " + error.localizedDescription)
            }
            // A foreground wake is optional; CloudKit has already accepted the
            // envelope. One conflated worker nudges without holding its caller.
            enqueueMessageNudge(msg.id)
                lastSyncAt = Date()
            syncStatus = "CloudKit accepted message — waiting for iOS"
            return msg
        }

        // Ordinary alerts belong to CloudKit's visible subscription. A Drive
        // publication cannot produce that alert and must not claim it was queued.
        if metadata?["kind"] == "notification", metadata?["userInfo.source"] != "requested_result" {
            throw DeviceSyncError.notConfigured
        }

        // Retained Drive messages use their existing signed reader.
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
                status: .commitUnverified, secret: secret, dataRoot: root) else { throw CocoaError(.fileWriteUnknown) }
        }
        try requireDeliveryAdmission()
        try await VolumeIO.run { [outboxURL] in
            try FileManager.default.createDirectory(at: outboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        do {
            try await VolumeIO.run { [data, outboxURL] in
                try data.write(to: outboxURL, options: .atomic)
            }
        } catch {
            syncStatus = "Could not queue iCloud message: \(error.localizedDescription)"
            if finalReply {
                guard await Self.appendChatDeliveryReceipt(msg, direction: "mac_to_ios", transport: "icloud_drive",
                    status: .commitUnverified,
                    secret: secret, dataRoot: root, detail: error.localizedDescription) else {
                    throw DeviceSyncSendOutcomeUnknown(message: "iCloud file commit and diagnostic receipt are unconfirmed: " + error.localizedDescription)
                }
            }
            throw DeviceSyncSendOutcomeUnknown(message: "iCloud file commit is unconfirmed: " + error.localizedDescription)
        }
        do {
            try await recordChatDeliveryReceipt(
                msg,
                transport: "icloud_drive",
                status: .queuedForICloudSync,
                secret: secret
            )
        } catch {
            throw DeviceSyncSendOutcomeUnknown(message: "The iCloud file was committed, but its local receipt failed: " + error.localizedDescription)
        }

        // KVS trigger: notify iOS side that a new file is waiting in Drive
        enqueueMessageNudge(msg.id)
        if metadata?["kind"] != "text_delta" {
            await scheduleDeliveryNudges(for: msg.id)
        }

        lastSyncAt = Date()
        syncStatus = "Queued for iCloud sync — waiting for iOS"
        return msg
    }

    func cloudKitActionResponseMessage(_ response: [String: String], correlationID: String) throws -> BridgeMessage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(response)
        let unsigned = BridgeMessage.make(
            id: "action-response-" + MacSyncSnapshotIntegrity.digest(Data(correlationID.utf8) + bytes),
            sender: "mac",
            text: String(decoding: bytes, as: UTF8.self),
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
            let secret = try PairingSecret.loadOrGenerateSecret()
            let signed = try await Self.retainPublication(cloudKitActionResponseMessage(response, correlationID: correlationID),
                secret: secret, dataRoot: sync.dataRoot)
            try await deviceTransport.send(signed)
            await recordSendResult(operation: "action response \(correlationID)")
            guard await Self.appendActionResponseDeliveryReceipt(
                response: response,
                correlationID: correlationID,
                transport: "cloudkit",
                status: .acceptedByTransport,
                dataRoot: PersistenceCore.defaultDataRoot()
            ) else { throw CocoaError(.fileWriteUnknown) }
            try await Self.completePublication(signed.id, dataRoot: sync.dataRoot)
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
    ) async throws {
        guard await Self.appendChatDeliveryReceipt(
            message,
            direction: direction,
            transport: transport,
            status: status,
            secret: secret,
            dataRoot: PersistenceCore.defaultDataRoot()
        ) else {
            syncStatus = "Message accepted; its delivery receipt remains owed in icloud/chat_delivery_receipts.jsonl."
            throw CocoaError(.fileWriteUnknown)
        }
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
