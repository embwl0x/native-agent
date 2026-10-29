#if canImport(CloudKit) && !os(Linux)
import Foundation
import CloudKit
import CryptoKit
import OSLog
import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+Messages.swift` | Signed message delivery, serialized drains and delivery cursor admission |

extension CloudKitDeviceTransport {
    // MARK: send

    public func send(_ message: BridgeMessage) async throws {
        try await send(message, beforeDispatch: {})
    }

    public func send(_ message: BridgeMessage, beforeDispatch: @Sendable () async throws -> Void) async throws {
        try refuseWhilePairedElsewhere()
        let fields = try NAChatMessageCodec.encode(message)
        let recordType = Self.recordType(for: fields)
        let usesAsset = NAChatMessageCodec.usesAsset(fields)
        var assetURL: URL?
        var legacyFields: NAChatMessageFields?
        if usesAsset {
            guard let secret = await loadAssetSecretProvider()?(), secret.count == 32 else {
                throw DeviceSyncError.underlying(message: "Pairing is required to encrypt this attachment.")
            }
            // 0.5.1 reads only payloadJSON, then claims the record. Give that
            // phone a signed reading copy while newer peers decrypt the asset.
            if fields.direction == NAChatDirection.mac2ios.rawValue {
                var text = message.text
                while true {
                    let notice = "\n\nThe image is on the Mac."
                        + (text == message.text ? "" : "\nThe rest of the reply is on the Mac.")
                    let preview = try BridgeMessage.make(id: message.id, sender: message.sender,
                        text: text + notice, sessionID: message.sessionID, correlationID: message.correlationID,
                        metadata: message.metadata, timestamp: message.timestamp).signed(with: secret)
                    do {
                        legacyFields = try NAChatMessageCodec.encode(preview)
                        break
                    } catch DeviceSyncError.payloadTooLarge(_, _) where !text.isEmpty {
                        text = String(text.prefix(text.count / 2))
                    }
                }
            }
            let box = try AES.GCM.seal(Data(fields.payloadJSON.utf8), using: Self.assetKey(secret),
                authenticating: Self.assetContext(recordName: fields.recordName, direction: fields.direction))
            guard let bytes = box.combined else { throw DeviceSyncError.underlying(message: "Attachment encryption failed.") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("nativeagent-chat-\(UUID().uuidString).sealed")
            do {
                try bytes.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            assetURL = url
        }
        let preparedAssetURL = assetURL
        let preparedLegacyFields = legacyFields
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.send", onFailure: accountFailureReporter,
                                                  beforeDispatch: {
                do { try await beforeDispatch() }
                catch {
                    if let preparedAssetURL { try? FileManager.default.removeItem(at: preparedAssetURL) }
                    throw error
                }
            }) {
                defer { if let preparedAssetURL { try? FileManager.default.removeItem(at: preparedAssetURL) } }
                let ck = CKRecord(
                    recordType: recordType,
                    recordID: CKRecord.ID(recordName: fields.recordName)
                )
                ck["direction"] = fields.direction as CKRecordValue
                if let s = fields.sessionId { ck["sessionId"] = s as CKRecordValue }
                ck["text"] = (preparedLegacyFields?.text ?? fields.text) as CKRecordValue
                if let preparedAssetURL { ck["payloadAsset"] = CKAsset(fileURL: preparedAssetURL) }
                if let preparedLegacyFields { ck["payloadJSON"] = preparedLegacyFields.payloadJSON as CKRecordValue }
                else if preparedAssetURL == nil { ck["payloadJSON"] = fields.payloadJSON as CKRecordValue }
                ck["createdAt"] = fields.createdAt as CKRecordValue
                ck["senderDevice"] = fields.senderDevice as CKRecordValue
                if let k = fields.kind { ck["kind"] = k as CKRecordValue }
                if let title = fields.notificationTitle {
                    ck["notificationTitle"] = title as CKRecordValue
                }
                if let screen = fields.notificationScreen {
                    ck["notificationScreen"] = screen as CKRecordValue
                }
                if let eventID = fields.notificationEventID {
                    ck["notificationEventId"] = eventID as CKRecordValue
                }

                let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
                op.savePolicy = .ifServerRecordUnchanged
                op.qualityOfService = .userInitiated
                do { try await self.performModifyRecords(op) }
                catch let error as DeviceSyncError {
                    if case .conflict = error, await self.existingMessageRecordMatches(fields) {
                        do { try await self.resignalMessage(named: fields.recordName) }
                        catch { throw DeviceSyncSendOutcomeUnknown(message: error.localizedDescription) }
                        return
                    }
                    switch error {
                    case .transient, .underlying, .conflict:
                        throw DeviceSyncSendOutcomeUnknown(message: error.localizedDescription)
                    default: throw error
                    }
                } catch {
                    throw DeviceSyncSendOutcomeUnknown(message: error.localizedDescription)
                }
            }
        } catch is DeviceCKLandmineTimeout {
            if await existingMessageRecordMatches(fields) {
                return
            }
            throw DeviceSyncSendOutcomeUnknown(message: "CloudKit send timed out; server acceptance is unknown")
        } catch is CancellationError {
            if let preparedAssetURL { try? FileManager.default.removeItem(at: preparedAssetURL) }
            throw CancellationError()
        }
    }

    /// Renew the original delivery, never mint a second request. A changed
    /// query clock makes it eligible for an update push; the signed payload keeps
    /// its original timestamp and identity. Uses the existing CloudKit schema.
    public func resignalMessage(named recordName: String) async throws {
        try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.resignal", onFailure: accountFailureReporter) {
            let id = CKRecord.ID(recordName: recordName)
            let records = try await self.database.records(for: [id], desiredKeys: ["direction", "createdAt"])
            guard let fetched = records[id] else { throw CKError(.unknownItem) }
            let record = try fetched.get()
            let direction: NAChatDirection = self.role == .mac ? .mac2ios : .ios2mac
            guard record["direction"] as? String == direction.rawValue else {
                throw DeviceSyncError.underlying(message: "Cannot re-signal another device's message.")
            }
            record["createdAt"] = ISO8601DateFormatter().string(from: Date()) as CKRecordValue
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.savePolicy = .changedKeys
            op.qualityOfService = .userInitiated
            try await self.performModifyRecords(op)
        }
    }

    /// Resolves timeout-after-commit and stable-id retries without weakening
    /// conflict handling. Only exact payloadJSON + direction equality converts
    /// the ambiguous write into success.
    static func recordType(for fields: NAChatMessageFields) -> String {
        fields.kind == "notification"
            ? NADeviceSyncRecordType.notification
            : NADeviceSyncRecordType.chatMessage
    }

    private func existingMessageRecordMatches(_ fields: NAChatMessageFields) async -> Bool {
        let secret = await loadAssetSecretProvider()?()
        return await withDeviceCKTimeout("CloudKitDeviceTransport.sendReplayProof", onFailure: accountFailureReporter) {
            let record = try await self.database.record(
                for: CKRecord.ID(recordName: fields.recordName)
            )
            return NAChatMessageCodec.isExactIdempotentReplay(
                existingPayloadJSON: try Self.payload(in: record, secret: secret),
                existingDirection: record["direction"] as? String,
                intended: fields
            )
        } ?? false
    }

    // MARK: observeIncoming

    @discardableResult
    public func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async -> Bool {
        setIncomingHandler(onMessage)  // last registration wins (single forwarder)
        // Let the bridge record subscription failure before its initial drain.
        return await ensurePushSubscriptions()
    }

    public func ensurePushSubscriptions() async -> Bool {
        do {
            try await subscribeToChanges()
            return true
        } catch {
            // Fail loud (no-silent-fallbacks): a failed subscription means no
            // live push wakeups — the drain still works when polled, but callers
            // must not describe the visual route as eligible.
            devicePushLog.error("Chat subscription failed (no live push) role=\(self.role.rawValue, privacy: .public): \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// Pull incoming messages since the last cursor, decode, dispatch to the
    /// registered handler, and advance the cursor with a clock-skew overlap
    /// window. Idempotent per message id. Failed queries never report an empty success.
    @discardableResult
    public func drainIncoming() async -> DeviceSyncDrainResult {
        guard NADeviceSyncRecoveryBudget.hasTime else { return .skipped(0) }
        guard !pairingHeldElsewhere else { return .skipped(0) }
        // Acquire the single drain slot under a synchronous lock, never across an await.
        guard beginDrainOrCoalesce() else { return .skipped(await drainIncomingControls()) }
        var total = 0
        var outcome: DeviceSyncDrainResult = .skipped(0)
        while true {
            outcome = await drainIncomingBody()
            total += outcome.dispatchedCount
            if endDrainOrContinue() { continue }  // a concurrent caller requested a re-run
            break
        }
        if case .success = outcome { return .success(total) }
        if case .failure(let error, _) = outcome { return .failure(error, dispatched: total) }
        return .skipped(total)
    }

    /// Acquire the single drain slot. Returns true if acquired; false if a drain
    /// is already running (then flags a re-run so the active loop services us).
    private func beginDrainOrCoalesce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if drainInFlight { drainAgain = true; return false }
        drainInFlight = true
        return true
    }

    /// End a drain iteration. Returns true if a re-run is needed (clearing the
    /// request); false if the slot is now free.
    private func endDrainOrContinue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if drainAgain && NADeviceSyncRecoveryBudget.hasTime { drainAgain = false; return true }
        drainAgain = false
        drainInFlight = false
        return false
    }

    // Only the serialized drain calls this body; concurrent bodies can lose records.
    private func drainIncomingBody() async -> DeviceSyncDrainResult {
        let (handler, since) = loadHandlerAndCursor()
        guard handler != nil else { return .skipped(0) }
        let queryStartedAt = Date()

        let inbound = role.inboundDirection.rawValue
        let fetched: DeviceCKPullResult
        do {
            var records = try await pull(
                recordType: NADeviceSyncRecordType.chatMessage,
                since: since,
                inboundDirection: inbound
            )
            if role == .ios {
                let notifications = try await pull(
                    recordType: NADeviceSyncRecordType.notification,
                    since: since,
                    inboundDirection: inbound
                )
                records.records += notifications.records
                records.payloadError = records.payloadError ?? notifications.payloadError
            }
            fetched = records
        } catch {
            nativeLog("[ck-device] drainIncoming pull failed: \(error)")
            return .failure(Self.mapError(error))
        }

        let dispatched = await deliverIncoming(fetched.records, since: since, queryStartedAt: queryStartedAt,
                                               advanceCursor: fetched.payloadError == nil)
        if let error = fetched.payloadError { return .failure(error, dispatched: dispatched) }
        return .success(dispatched)
    }

    func deliverIncoming(_ fetched: [(fields: NAChatMessageFields, modDate: Date?)], since: Date?, queryStartedAt: Date,
                         advanceCursor: Bool = true) async -> Int {
        guard let handler = loadHandlerAndCursor().0 else { return 0 }
        let inbound = role.inboundDirection.rawValue
        // CloudKit query order is undefined; deliver in server chronology.
        let sorted = Self.orderedIncoming(fetched)

        // Controls in this batch must reach their owners before awaiting chat.
        var decoded: [Int: (id: String, message: Result<BridgeMessage, Error>?)] = [:]
        guard let controls = await deliverControls(sorted, decoded: &decoded) else { return 0 }
        var dispatched = controls
        // Pin the cursor before the first undelivered inbound record.
        var cursorAdvance: Date? = nil
        var halted = false
        for (index, item) in sorted.enumerated() {
            // A concurrent cancellation has not yet earned acknowledgement.
            // Never advance the ordinary cursor past its temporary claim.
            if isControlDrainInFlight() { halted = true; break }
            if !NADeviceSyncRecoveryBudget.hasTime { halted = true; break }
            if halted && role != .ios { break }
            let m = item.modDate
            guard item.fields.direction == inbound else {
                if !halted, let m { cursorAdvance = m }   // our own outbound / other — safe to pass
                continue
            }
            let id = decoded[index]?.id ?? Self.deliveryClaimKey(item.fields)
            // Fresh atomic claims exclude concurrent drains.
            guard let claimed = claimForSerialDrain(id) else { halted = true; break }
            guard claimed else {
                if !halted, let m { cursorAdvance = m }    // already delivered — safe to pass
                continue
            }
            guard let message = try? (decoded[index]?.message ?? Result { try NAChatMessageCodec.decode(item.fields) }).get() else {
                nativeLog("[ck-device] drainIncoming: undecodable payload for \(id)")
                if !halted, let m { cursorAdvance = m }    // poison — keep it claimed, pass
                continue
            }
            if await handler(message) {
                dispatched += 1
                NADeviceSyncRecoveryBudget.didApplyData?()
                if !halted, let m { cursorAdvance = m }
            } else {
                releaseClaim(id)                  // not delivered — retry next drain
                halted = true                     // do not advance past this record
                // iPhone replies are independent deliveries. Keep the failed
                // row unclaimed and the cursor pinned, but deliver later replies.
            }
        }
        if isControlDrainInFlight() { halted = true }
        // Keep a sliding 30s overlap (matches the memory framework). An idle
        // successful query must still move an established cursor forward;
        // otherwise a quiet bridge re-queries from the date of its last record
        // forever. A halted delivery never advances past the rejected row.
        if advanceCursor, let nextCursor = Self.nextPullCursor(
            previousCursor: since,
            queryStartedAt: queryStartedAt,
            safeRecordDate: cursorAdvance,
            halted: halted
        ) {
            setLastPullDate(
                nextCursor,
                persistImmediately: cursorAdvance != nil || halted
            )
        }
        return dispatched
    }

    private static func orderedIncoming(_ records: [(fields: NAChatMessageFields, modDate: Date?)]) -> [(fields: NAChatMessageFields, modDate: Date?)] {
        records.sorted { a, b in
            let am = a.modDate ?? .distantPast, bm = b.modDate ?? .distantPast
            if am != bm { return am < bm }
            if a.fields.createdAt != b.fields.createdAt { return a.fields.createdAt < b.fields.createdAt }
            return a.fields.recordName < b.fields.recordName
        }
    }

    /// Mac-only admission; the bridge authenticates phone actions and handoffs.
    /// Ordinary chat delivery and its terminal receipt retain their original owner.
    public func setControlAdmission(_ admission: @escaping @Sendable (BridgeMessage) async -> Bool) {
        lock.lock(); defer { lock.unlock() }
        controlAdmission = admission
    }

    @discardableResult
    public func drainIncomingControls() async -> Int {
        guard role == .mac, NADeviceSyncRecoveryBudget.hasTime, !pairingHeldElsewhere,
              loadControlAdmission() != nil, beginControlDrain() else { return 0 }
        defer { endControlDrain() }
        let (_, since) = loadHandlerAndCursor()
        do {
            let records = try await pull(recordType: NADeviceSyncRecordType.chatMessage,
                                         since: since, inboundDirection: role.inboundDirection.rawValue)
            if let error = records.payloadError { nativeLog("[ck-device] cancellation payload failed: %@", error.localizedDescription) }
            var decoded: [Int: (id: String, message: Result<BridgeMessage, Error>?)] = [:]
            return await deliverAdmittedControls(Self.orderedIncoming(records.records), decoded: &decoded)
        } catch {
            nativeLog("[ck-device] cancellation pull failed: \(error)")
            return 0
        }
    }

    private func isControlDrainInFlight() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return controlDrainInFlight
    }

    private func beginControlDrain() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !controlDrainInFlight else { return false }
        controlDrainInFlight = true
        return true
    }

    private func endControlDrain() {
        lock.lock(); defer { lock.unlock() }
        controlDrainInFlight = false
    }

    private func loadControlAdmission() -> (@Sendable (BridgeMessage) async -> Bool)? {
        lock.lock(); defer { lock.unlock() }
        return controlAdmission
    }

    func deliverControls(_ records: [(fields: NAChatMessageFields, modDate: Date?)],
                         decoded: inout [Int: (id: String, message: Result<BridgeMessage, Error>?)]) async -> Int? {
        guard role == .mac, loadControlAdmission() != nil else { return 0 }
        guard beginControlDrain() else { return nil }
        defer { endControlDrain() }
        return await deliverAdmittedControls(records, decoded: &decoded)
    }

    private func deliverAdmittedControls(_ records: [(fields: NAChatMessageFields, modDate: Date?)],
                                         decoded: inout [Int: (id: String, message: Result<BridgeMessage, Error>?)]) async -> Int {
        guard let admission = loadControlAdmission(),
              let handler = loadHandlerAndCursor().0 else { return 0 }
        var delivered = 0
        for (index, record) in records.enumerated() {
            guard NADeviceSyncRecoveryBudget.hasTime else { break }
            // Seen control records bypass decoding and signature checks on every drain.
            guard record.fields.direction == role.inboundDirection.rawValue else { continue }
            let id = Self.deliveryClaimKey(record.fields)
            let message = isSeen(id) ? nil : Result { try NAChatMessageCodec.decode(record.fields) }
            decoded[index] = (id, message)
            guard let message = try? message?.get(), await admission(message), claimIfUnseen(id) else { continue }
            if await handler(message) {
                delivered += 1
                NADeviceSyncRecoveryBudget.didApplyData?()
            } else {
                releaseClaim(id)
            }
        }
        // This path never writes the cursor. The serial drain accounts for
        // every intervening chat and any cancellation whose response failed.
        return delivered
    }

    static func nextPullCursor(
        previousCursor: Date?,
        queryStartedAt: Date,
        safeRecordDate: Date?,
        halted: Bool
    ) -> Date? {
        let overlap: TimeInterval = 30

        if halted {
            guard let safeRecordDate else { return previousCursor }
            let candidate = safeRecordDate.addingTimeInterval(-overlap)
            guard let previousCursor else { return candidate }
            return max(previousCursor, candidate)
        }

        // On a first-ever empty pull, retain nil so the next attempt still
        // performs a complete bootstrap read. Once a durable cursor exists (or
        // this pull saw a record), successful emptiness is an observed high
        // watermark and can slide the overlap window forward safely.
        guard previousCursor != nil || safeRecordDate != nil else { return nil }
        let highWatermark = max(queryStartedAt, safeRecordDate ?? queryStartedAt)
        let candidate = highWatermark.addingTimeInterval(-overlap)
        guard let previousCursor else { return candidate }
        return max(previousCursor, candidate)
    }
}
#endif
