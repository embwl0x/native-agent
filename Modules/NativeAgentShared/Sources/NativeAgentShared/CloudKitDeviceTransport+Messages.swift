#if canImport(CloudKit) && !os(Linux)
import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+Messages.swift` | Signed sends and serialized two-family drains |

extension CloudKitDeviceTransport {
    // MARK: send

    public func send(_ message: BridgeMessage) async throws {
        try await send(message, beforeDispatch: {})
    }

    public func send(_ message: BridgeMessage, beforeDispatch: @Sendable () async throws -> Void) async throws {
        try refuseUnlessHoldingPairing()
        let fields = try NAChatMessageCodec.encode(message)
        let recordType = Self.recordType(for: message)
        let usesAsset = NAChatMessageCodec.usesAsset(fields)
        var assetURL: URL?
        defer { if let assetURL { Self.removePreparedAsset(assetURL) } }
        if usesAsset {
            guard let secret = await loadAssetSecretProvider()?(), secret.count == 32 else {
                throw DeviceSyncError.underlying(message: "Pairing is required to encrypt this attachment.")
            }
            let box = try AES.GCM.seal(Data(fields.payloadJSON.utf8), using: Self.assetKey(secret),
                authenticating: Self.assetContext(recordName: fields.recordName, direction: fields.direction))
            guard let bytes = box.combined else { throw DeviceSyncError.underlying(message: "Attachment encryption failed.") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("nativeagent-chat-\(UUID().uuidString).sealed")
            assetURL = url
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let preparedAssetURL = assetURL
        try await withDeviceCKOperation("CloudKitDeviceTransport.send", onFailure: accountFailureReporter,
                                        beforeDispatch: beforeDispatch) {
            let ck = CKRecord(
                recordType: recordType,
                recordID: CKRecord.ID(recordName: fields.recordName)
            )
            ck["direction"] = fields.direction as CKRecordValue
            if let s = fields.sessionId { ck["sessionId"] = s as CKRecordValue }
            ck["text"] = fields.text as CKRecordValue
            if let preparedAssetURL { ck["payloadAsset"] = CKAsset(fileURL: preparedAssetURL) }
            if preparedAssetURL == nil { ck["payloadJSON"] = fields.payloadJSON as CKRecordValue }
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
                switch error {
                case .transient, .underlying, .conflict:
                    try await self.reconcileMessage(fields, recordType: recordType, saveError: error)
                default: throw error
                }
            } catch {
                try await self.reconcileMessage(fields, recordType: recordType, saveError: error)
            }
        }
    }

    /// The existing signed record proves acceptance of this identity; a different payload remains a conflict.
    private func reconcileMessage(_ fields: NAChatMessageFields, recordType: String, saveError: Error) async throws {
        let record: CKRecord
        let payload: String
        do {
            record = try await database.record(for: CKRecord.ID(recordName: fields.recordName))
            payload = try Self.payload(in: record, secret: await loadAssetSecretProvider()?())
        } catch {
            throw DeviceSyncSendOutcomeUnknown(message:
                "CloudKit save is unconfirmed (\(saveError.localizedDescription)); "
                    + "the existing record could not be read: \(error.localizedDescription)")
        }
        guard record.recordType == recordType, record["direction"] as? String == fields.direction,
              payload == fields.payloadJSON else { throw DeviceSyncError.conflict }
    }

    private static func removePreparedAsset(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { nativeLog("[ck-device] sealed attachment cleanup failed for \(url.lastPathComponent): \(error)") }
    }

    /// Event kind chooses the renderer before any transport runs. Keep the signed envelope unchanged; both record families reach the same reader.
    static func recordType(for message: BridgeMessage) -> String {
        message.metadata?["kind"] == "notification"
            && message.metadata?["userInfo.source"] != "requested_result"
            ? NADeviceSyncRecordType.notification
            : NADeviceSyncRecordType.chatMessage
    }

    // MARK: observeIncoming

    @discardableResult
    public func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async -> Bool {
        setIncomingHandler(onMessage)  // last registration wins (single forwarder)
        // Let the bridge record subscription failure before its initial drain.
        return await ensurePushSubscriptions()
    }

    public func ensurePushSubscriptions() async -> Bool {
        // Each family owns its registration and failure. A rejected alert subscription cannot prevent chat wakes from being registered. The return
        // value describes chat wakes, as observeIncoming's caller uses it to assess incoming chat push availability.
        let chatReady: Bool
        do {
            try await subscribeToChatChanges()
            chatReady = true
        } catch {
            devicePushLog.error("""
                Chat subscription failed id=\(DeviceCloudKitSubscriptionID.chat, privacy: .public) \
                role=\(self.role.rawValue, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            chatReady = false
        }
        do {
            try await subscribeToVisibleNotifications()
        } catch {
            devicePushLog.error("""
                Visible notification subscription failed id=\(DeviceCloudKitSubscriptionID.visibleNotifications, privacy: .public) \
                role=\(self.role.rawValue, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
        return chatReady
    }

    /// Pull incoming messages since the last cursor, decode, dispatch to the registered handler, and advance the cursor with a clock-skew overlap
    /// window. Idempotent per message id. Failed queries never report an empty success. Periodic callers use queueIfBusy: false: a busy owner already
    /// covers their wake, and repeated timer ticks must not keep that owner running.
    @discardableResult
    public func drainIncoming(queueIfBusy: Bool = true, recovery: DeviceSyncRecovery = .init()) async -> DeviceSyncDrainResult {
        guard recovery.isActive else { return .skipped(0) }
        guard holdsPairing else { return .skipped(0) }
        // Acquire the single drain slot under a synchronous lock, never across an await.
        guard beginDrainOrCoalesce(queueIfBusy: queueIfBusy) else {
            if !queueIfBusy { return .skipped(0) }
            return .skipped(await drainIncomingControls(recovery: recovery))
        }
        var total = 0
        var outcome: DeviceSyncDrainResult = .skipped(0)
        while true {
            outcome = await drainIncomingBody(recovery: recovery)
            total += outcome.dispatchedCount
            if endDrainOrContinue(recovery: recovery) { continue }
            break
        }
        if case .success = outcome { return .success(total) }
        if case .failure(let error, _) = outcome { return .failure(error, dispatched: total) }
        return .skipped(total)
    }

    /// Coalesce only callers requesting a re-run; periodic wakes must not extend an active drain.
    private func beginDrainOrCoalesce(queueIfBusy: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if drainInFlight {
            if queueIfBusy { drainAgain = true }
            return false
        }
        drainInFlight = true
        return true
    }

    private func endDrainOrContinue(recovery: DeviceSyncRecovery) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if drainAgain && recovery.isActive { drainAgain = false; return true }
        drainAgain = false
        drainInFlight = false
        return false
    }

    // Only the serialized drain calls this body; concurrent bodies can lose records.
    private func drainIncomingBody(recovery: DeviceSyncRecovery) async -> DeviceSyncDrainResult {
        let (handler, since) = loadHandlerAndCursor()
        guard handler != nil else { return .skipped(0) }
        let queryStartedAt = Date()

        let inbound = role.inboundDirection.rawValue
        let fetched: DeviceCKPullResult
        var earlyDelivery: DeviceSyncDrainResult = .success(0)
        do {
            var records = try await pull(
                recordType: NADeviceSyncRecordType.chatMessage,
                since: since,
                inboundDirection: inbound,
                recovery: recovery
            )
            if role == .ios {
                // Show words as soon as chat is fetched. The notification read may be slow or fail; it must not hold already-fetched words. Keep the
                // shared cursor pinned until both families were read.
                earlyDelivery = await deliverIncoming(records.records, since: since, queryStartedAt: queryStartedAt,
                                                        advanceCursor: false, recovery: recovery)
                let notifications = try await pull(
                    recordType: NADeviceSyncRecordType.notification,
                    since: since,
                    inboundDirection: inbound,
                    recovery: recovery
                )
                records.records = notifications.records
                records.payloadError = records.payloadError ?? notifications.payloadError
            }
            fetched = records
        } catch {
            nativeLog("[ck-device] drainIncoming pull failed: \(error)")
            return .failure(Self.mapError(error), dispatched: earlyDelivery.dispatchedCount)
        }

        let earlyAccepted: Bool = if case .success = earlyDelivery { true } else { false }
        let remainingDelivery = await deliverIncoming(fetched.records, since: since, queryStartedAt: queryStartedAt,
            advanceCursor: fetched.payloadError == nil && earlyAccepted, recovery: recovery)
        let dispatched = earlyDelivery.dispatchedCount + remainingDelivery.dispatchedCount
        if case .failure(let error, _) = earlyDelivery { return .failure(error, dispatched: dispatched) }
        if case .failure(let error, _) = remainingDelivery { return .failure(error, dispatched: dispatched) }
        if let error = fetched.payloadError { return .failure(error, dispatched: dispatched) }
        if case .skipped = earlyDelivery { return .skipped(dispatched) }
        if case .skipped = remainingDelivery { return .skipped(dispatched) }
        return .success(dispatched)
    }

    func deliverIncoming(_ fetched: [(fields: NAChatMessageFields, modDate: Date?)], since: Date?, queryStartedAt: Date,
                         advanceCursor: Bool = true, recovery: DeviceSyncRecovery) async -> DeviceSyncDrainResult {
        guard let handler = loadHandlerAndCursor().0 else { return .skipped(0) }
        let inbound = role.inboundDirection.rawValue
        // CloudKit query order is undefined; deliver in server chronology.
        let sorted = Self.orderedIncoming(fetched)

        // Controls in this batch must reach their owners before awaiting chat.
        var decoded: [Int: (id: String, message: Result<BridgeMessage, Error>?)] = [:]
        guard let controls = await deliverControls(sorted, decoded: &decoded, recovery: recovery) else { return .skipped(0) }
        var dispatched = controls
        // Pin the cursor before the first undelivered inbound record.
        var cursorAdvance: Date? = nil
        var halted = false
        var failure: DeviceSyncError?
        for (index, item) in sorted.enumerated() {
            // A concurrent cancellation has not yet earned acknowledgement. Never advance the ordinary cursor past its temporary claim.
            if isControlDrainInFlight() { halted = true; break }
            if !recovery.isActive { halted = true; break }
            if halted && role != .ios { break }
            let m = item.modDate
            guard item.fields.direction == inbound else {
                if !halted, let m { cursorAdvance = m }   // our own outbound / other — safe to pass
                continue
            }
            let id = decoded[index]?.id ?? Self.deliveryClaimKey(item.fields)
            guard let claimed = claimForSerialDrain(id) else { halted = true; break }
            guard claimed else {
                if !halted, let m { cursorAdvance = m }    // already delivered — safe to pass
                continue
            }
            let message: BridgeMessage
            do {
                message = try (decoded[index]?.message ?? Result { try NAChatMessageCodec.decode(item.fields) }).get()
            } catch {
                nativeLog("[ck-device] unreadable record \(id) remains pending: \(error)")
                releaseClaim(id)
                halted = true
                if failure == nil { failure = Self.mapError(error) }
                continue
            }
            if await handler(message) {
                dispatched += 1
                recovery.didApplyData?()
                if !halted, let m { cursorAdvance = m }
            } else {
                releaseClaim(id)                  // not delivered — retry next drain
                halted = true
                // iPhone replies are independent deliveries. Keep the failed row unclaimed and the cursor pinned, but deliver later replies.
            }
        }
        if isControlDrainInFlight() { halted = true }
        // Keep a sliding 30s overlap (matches the memory framework). An idle successful query must still move an established cursor forward;
        // otherwise a quiet bridge re-queries from the date of its last record forever. A halted delivery never advances past the rejected row.
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
        if let failure { return .failure(failure, dispatched: dispatched) }
        return halted ? .skipped(dispatched) : .success(dispatched)
    }

    private static func orderedIncoming(_ records: [(fields: NAChatMessageFields, modDate: Date?)]) -> [(fields: NAChatMessageFields, modDate: Date?)] {
        records.sorted { a, b in
            let am = a.modDate ?? .distantPast, bm = b.modDate ?? .distantPast
            if am != bm { return am < bm }
            if a.fields.createdAt != b.fields.createdAt { return a.fields.createdAt < b.fields.createdAt }
            return a.fields.recordName < b.fields.recordName
        }
    }

    /// Mac-only admission; the bridge authenticates phone actions and handoffs. Ordinary chat delivery and its terminal receipt retain their original
    /// owner.
    public func setControlAdmission(_ admission: @escaping @Sendable (BridgeMessage) async -> Bool) {
        lock.lock(); defer { lock.unlock() }
        controlAdmission = admission
    }

    @discardableResult
    public func drainIncomingControls(recovery: DeviceSyncRecovery = .init()) async -> Int {
        guard role == .mac, recovery.isActive, holdsPairing,
              loadControlAdmission() != nil, beginControlDrain() else { return 0 }
        defer { endControlDrain() }
        let (_, since) = loadHandlerAndCursor()
        do {
            let records = try await pull(recordType: NADeviceSyncRecordType.chatMessage,
                                         since: since, inboundDirection: role.inboundDirection.rawValue, recovery: recovery)
            if let error = records.payloadError { nativeLog("[ck-device] cancellation payload failed: %@", error.localizedDescription) }
            var decoded: [Int: (id: String, message: Result<BridgeMessage, Error>?)] = [:]
            return await deliverAdmittedControls(Self.orderedIncoming(records.records), decoded: &decoded, recovery: recovery)
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
                         decoded: inout [Int: (id: String, message: Result<BridgeMessage, Error>?)], recovery: DeviceSyncRecovery) async -> Int? {
        guard role == .mac, loadControlAdmission() != nil else { return 0 }
        guard beginControlDrain() else { return nil }
        defer { endControlDrain() }
        return await deliverAdmittedControls(records, decoded: &decoded, recovery: recovery)
    }

    private func deliverAdmittedControls(_ records: [(fields: NAChatMessageFields, modDate: Date?)],
                                         decoded: inout [Int: (id: String, message: Result<BridgeMessage, Error>?)],
                                             recovery: DeviceSyncRecovery) async -> Int {
        guard let admission = loadControlAdmission(),
              let handler = loadHandlerAndCursor().0 else { return 0 }
        var delivered = 0
        for (index, record) in records.enumerated() {
            guard recovery.isActive else { break }
            guard record.fields.direction == role.inboundDirection.rawValue else { continue }
            let id = Self.deliveryClaimKey(record.fields)
            let message = isSeen(id) ? nil : Result { try NAChatMessageCodec.decode(record.fields) }
            decoded[index] = (id, message)
            guard let result = message else { continue }
            let admitted: BridgeMessage
            do { admitted = try result.get() }
            catch {
                nativeLog("[ck-device] unreadable control record \(id) remains pending: \(error)")
                continue
            }
            guard await admission(admitted), claimIfUnseen(id) else { continue }
            if await handler(admitted) {
                delivered += 1
                recovery.didApplyData?()
            } else {
                releaseClaim(id)
            }
        }
        // This path never writes the cursor. The serial drain accounts for every intervening chat and any cancellation whose response failed.
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

        // On a first-ever empty pull, retain nil so the next attempt still performs a complete bootstrap read. Once a durable cursor exists (or this
        // pull saw a record), successful emptiness is an observed high watermark and can slide the overlap window forward safely.
        guard previousCursor != nil || safeRecordDate != nil else { return nil }
        let highWatermark = max(queryStartedAt, safeRecordDate ?? queryStartedAt)
        let candidate = highWatermark.addingTimeInterval(-overlap)
        guard let previousCursor else { return candidate }
        return max(previousCursor, candidate)
    }
}
#endif
