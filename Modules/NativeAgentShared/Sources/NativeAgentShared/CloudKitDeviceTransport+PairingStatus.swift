#if canImport(CloudKit) && !os(Linux)
import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+PairingStatus.swift` | Server-checked absent-slot pairing claims, deliberate pairing replacement, presence and serialized pairing-scoped status publication, acknowledgement and typed drain completion |

extension CloudKitDeviceTransport {
    // MARK: pairing

    private static func pairingSecret(in record: CKRecord) throws -> Data {
        guard let hex = record["secretHex"] as? String,
              let secret = data(fromHex: hex), secret.count == 32 else {
            throw DeviceSyncError.underlying(message: "The existing CloudKit pairing record has an unreadable key. Repair that pairing record before claiming this account; it has not been replaced.")
        }
        return secret
    }

    public func publishPairing(secret: Data) async throws {
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.publishPairing", onFailure: accountFailureReporter) {
                try await self.savePairing(secret: secret, policy: .changedKeys)
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit publishPairing timed out")
        }
        notePairingPublished()
    }

    private func savePairing(secret: Data, policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        guard secret.count == 32 else { throw DeviceSyncError.notConfigured }
        let recordType = NADeviceSyncRecordType.pairingDevice
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        let recordName = "pairing.\(role.rawValue)"
        let publishedAt = NativeTimestampFormat.fractionalZulu(Date())
        let ck = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: recordName)
        )
        ck["role"] = self.role.rawValue as CKRecordValue
        ck["secretHex"] = secretHex as CKRecordValue
        ck["publishedAt"] = publishedAt as CKRecordValue
        let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
        op.savePolicy = policy
        op.qualityOfService = .userInitiated
        try await self.performModifyRecords(op)
    }

    /// Every Mac on one Apple Account shares the account's Mac pairing record,
    /// and the phone follows whichever key it holds. A Mac takes the record
    /// only when it is free or already its own; another Mac's key stays until
    /// the person moves the phone, which is `publishPairing`. While another Mac
    /// holds it this transport neither reads the phone's records nor writes
    /// any: the phone is that Mac's. Returns whether this Mac holds the
    /// pairing, or nil when the record could not be read (nothing changes).
    @discardableResult
    public func claimPairing(secret: Data) async -> Bool? {
        guard role == .mac, secret.count == 32 else { return nil }
        let recordName = "pairing.\(role.rawValue)"
        let publications = pairingPublicationCount()
        let slot: PairingSlot? = await withDeviceCKTimeout("CloudKitDeviceTransport.claimPairing", onFailure: accountFailureReporter) {
            do {
                let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
                return .holds(try Self.pairingSecret(in: record))
            } catch let error as CKError where error.code == .unknownItem {
                return .empty
            }
        }
        switch slot {
        case nil:
            return nil
        case .holds(let held)?:
            return settleClaim(elsewhere: held != secret, since: publications)
        case .empty?:
            let owner: Data? = await withDeviceCKTimeout("CloudKitDeviceTransport.createPairingClaim", onFailure: accountFailureReporter) {
                do {
                    // A new record has no server change tag: this policy creates
                    // only an absent slot, never replaces a concurrent winner.
                    try await self.savePairing(secret: secret, policy: .ifServerRecordUnchanged)
                    nativeLog("[ck-device] pairing_claim created")
                    return secret
                } catch DeviceSyncError.conflict {
                    // Conflict is evidence of an owner, not permission to replace it.
                    let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
                    let owner = try Self.pairingSecret(in: record)
                    nativeLog("[ck-device] pairing_claim conflict_owner_read")
                    return owner
                }
            }
            guard let owner else { return nil }
            return settleClaim(elsewhere: owner != secret, since: publications)
        }
    }

    /// True while another Mac on this Apple Account holds the pairing.
    public var pairingHeldElsewhere: Bool {
        lock.lock(); defer { lock.unlock() }
        return pairingClaim == .elsewhere
    }

    /// Whether this transport may read and write the phone's records: always
    /// on the phone; on a Mac, only once it has read that it holds the pairing.
    public var holdsPairing: Bool {
        lock.lock(); defer { lock.unlock() }
        return role != .mac || pairingClaim == .held
    }

    private func notePairingPublished() {
        lock.lock(); defer { lock.unlock() }
        pairingPublications &+= 1
        pairingClaim = .held
    }

    private func pairingPublicationCount() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return pairingPublications
    }

    /// A publication that landed while the claim was reading is newer than
    /// what the read saw, and already decided the answer.
    private func settleClaim(elsewhere: Bool, since publications: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pairingPublications == publications { pairingClaim = elsewhere ? .elsewhere : .held }
        return pairingClaim == .held
    }

    func refuseUnlessHoldingPairing() throws {
        guard !holdsPairing else { return }
        throw pairingHeldElsewhere ? DeviceSyncError.pairedElsewhere
            : DeviceSyncError.transient(message: "This Mac has not read yet whether it holds the iPhone pairing.")
    }

    public func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async {
        setPairingHandler(onChange)  // last registration wins (single forwarder)
        // Register silent pushes, then drain any pairing material already published.
        do {
            try await subscribeToPairingChanges()
        } catch {
            nativeLog("[ck-device] observePairing: subscription registration FAILED (no live push): \(error)")
        }
        await drainPairing()
    }

    // Read the peer pairing secret without changing the pairing publication claim.
    public func peekPairingSecret() async -> Data? {
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        let recordName = "pairing.\(peerRole.rawValue)"
        return await withDeviceCKTimeout("CloudKitDeviceTransport.peekPairingSecret", onFailure: accountFailureReporter) {
            let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
            return try Self.pairingSecret(in: record)
        }
    }

    /// Pull the PEER's pairing singleton and offer it to the registered handler
    /// on every drain. The record is the truth: the handler compares it with
    /// the key it holds, so a key replaced by anything else is put back on the
    /// next drain, not only when the record's date advances. Returns true when
    /// the handler installed a different key.
    @discardableResult
    public func drainPairing() async -> Bool {
        guard NADeviceSyncRecoveryBudget.hasTime else { return false }
        guard let handler = loadPairingHandler(),
              let secret = await peekPairingSecret(),
              await handler(secret) else { return false }
        NADeviceSyncRecoveryBudget.didApplyData?()
        return true
    }

    // MARK: status

    private static func statusRecordName(role: NADeviceRole, key: String, pairingSecret: Data) -> String {
        let identity = HMAC<SHA256>.authenticationCode(for: Data("NativeAgent.status.identity.v1".utf8),
                                                     using: SymmetricKey(data: pairingSecret))
        return "status.\(role.rawValue)." + identity.map { String(format: "%02x", $0) }.joined() + ".\(key)"
    }

    /// One status record belongs to the authenticated pairing.
    public func setStatus(key: String, value: String, pairingSecret: Data) async throws {
        try refuseUnlessHoldingPairing()
        guard pairingSecret.count == 32 else { throw DeviceSyncError.notConfigured }
        let recordType = NADeviceSyncRecordType.status
        let recordName = Self.statusRecordName(role: role, key: key, pairingSecret: pairingSecret)
        let updatedAt = NativeTimestampFormat.fractionalZulu(Date())
        // The lane belongs to the actual CloudKit completion, not the caller's
        // bounded wait. A timed-out write must settle before a successor starts.
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.setStatus", seconds: 15, onFailure: accountFailureReporter) {
                try await self.enqueueStatusWrite(key: key) {
                    try self.refuseUnlessHoldingPairing()
                    let ck = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: recordName))
                    ck["key"] = key as CKRecordValue
                    ck["value"] = value as CKRecordValue
                    ck["role"] = self.role.rawValue as CKRecordValue
                    ck["updatedAt"] = updatedAt as CKRecordValue
                    let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
                    op.savePolicy = .changedKeys
                    // Utility permits discretionary deferral when the Mac app is
                    // backgrounded; phone status has a bounded publication deadline.
                    op.qualityOfService = .userInitiated
                    try await self.performModifyRecords(op)
                }
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit setStatus timed out")
        }
    }

    // MARK: presence

    /// One fixed record per pairing, updated in place. It rides the NANotification type
    /// without a `direction`: the visible subscription requires mac2ios, so
    /// neither creation nor an update alerts the phone. The incoming pull
    /// also requires a direction and never returns it, and it is modified
    /// every beat, so the retention sweep never reaches it. A type of its own
    /// would need a production schema deploy.
    private static func presenceRecordName(pairingSecret: Data) -> String {
        let identity = HMAC<SHA256>.authenticationCode(for: Data("NativeAgent.presence.identity.v1".utf8),
                                                     using: SymmetricKey(data: pairingSecret))
        return "presence.mac." + identity.map { String(format: "%02x", $0) }.joined()
    }

    public func setPresence(pairingSecret: Data) async throws {
        try refuseUnlessHoldingPairing()
        guard pairingSecret.count == 32 else { throw DeviceSyncError.notConfigured }
        let recordName = Self.presenceRecordName(pairingSecret: pairingSecret)
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.setPresence", seconds: 15, onFailure: accountFailureReporter) {
                try await self.enqueueStatusWrite(key: recordName) {
                    let timestamp = NativeTimestampFormat.fractionalZulu(Date())
                    let ck = CKRecord(
                        recordType: NADeviceSyncRecordType.notification,
                        recordID: CKRecord.ID(recordName: recordName)
                    )
                    ck["kind"] = "presence" as CKRecordValue
                    ck["createdAt"] = timestamp as CKRecordValue
                    let signature = HMAC<SHA256>.authenticationCode(for: Data("\(recordName):\(timestamp)".utf8),
                                                                  using: SymmetricKey(data: pairingSecret))
                    ck["payloadJSON"] = Data(signature).base64EncodedString() as CKRecordValue
                    let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
                    op.savePolicy = .changedKeys
                    // Presence is liveness, never deferrable: utility infers discretionary, which the system holds back after a network flap.
                    op.qualityOfService = .userInitiated
                    try await self.performModifyRecords(op)
                }
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit setPresence timed out")
        }
    }

    public func peerPresence(pairingSecret: Data) async -> Date? {
        guard pairingSecret.count == 32 else { return nil }
        let recordName = Self.presenceRecordName(pairingSecret: pairingSecret)
        return await withDeviceCKTimeout("CloudKitDeviceTransport.peerPresence", seconds: 3, onFailure: accountFailureReporter) {
            let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
            guard record["kind"] as? String == "presence",
                  let timestamp = record["createdAt"] as? String,
                  let encoded = record["payloadJSON"] as? String, let signature = Data(base64Encoded: encoded),
                  HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data("\(recordName):\(timestamp)".utf8),
                                                       using: SymmetricKey(data: pairingSecret)) else { return nil }
            // The signature authenticates the beat; CloudKit dates its freshness.
            return record.modificationDate
        } ?? nil
    }

    private func enqueueStatusWrite(
        key: String,
        work: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            lock.lock()
            defer { lock.unlock() }
            // Keep one operation and the latest replacement. Each caller owns
            // its result, including a value displaced before it reached the wire.
            pendingStatusWrites.removeValue(forKey: key)?.completion.resume(
                throwing: DeviceSyncError.transient(message: "CloudKit status write was superseded before sending."))
            pendingStatusWrites[key] = (work, completion)
            guard statusWrites[key] == nil else { return }
            statusWrites[key] = Task.detached(priority: .utility) {
                while let pending = self.nextStatusWrite(key: key) {
                    do { try await pending.work(); pending.completion.resume() }
                    catch { pending.completion.resume(throwing: error) }
                }
            }
        }
    }

    private func nextStatusWrite(key: String) -> (work: @Sendable () async throws -> Void, completion: CheckedContinuation<Void, Error>)? {
        lock.lock(); defer { lock.unlock() }
        let work = pendingStatusWrites.removeValue(forKey: key)
        if work == nil { statusWrites.removeValue(forKey: key) }
        return work
    }

    // Advance status acknowledgement only after the handler accepts its value.
    public func observeStatus(
        key: String,
        pairingSecret: @escaping @Sendable () async -> Data?,
        onApply: @escaping @Sendable (String, Date?, Data) async -> Bool
    ) {
        setStatusHandler(key: key, DeviceStatusObserver(pairingSecret: pairingSecret, apply: onApply))
    }

    /// Pull the PEER's current-pairing status. Dispatch each
    /// to its handler iff newer than the last dispatched value (LWW by server
    /// modificationDate, per key). Returns the number of new values accepted.
    @discardableResult
    public func drainStatus() async -> Int {
        (await drainStatusResult()).dispatchedCount
    }

    /// Success means every observed key was read and accepted (or already
    /// current). Missing data, failed handlers and skipped drains are not success.
    public func drainStatusResult() async -> DeviceSyncDrainResult {
        guard NADeviceSyncRecoveryBudget.hasTime, holdsPairing else { return .skipped(0) }
        // Serialize status drains so an older handler cannot overwrite a newer value.
        guard beginStatusDrainOrCoalesce() else { return .skipped(0) }
        var total = 0
        var failure: DeviceSyncError?
        var skipped = false
        while true {
            let result = await drainStatusBody()
            total += result.dispatchedCount
            switch result {
            case .success: break
            case .failure(let error, _): failure = failure ?? error
            case .skipped: skipped = true
            }
            if endStatusDrainOrContinue() { continue }
            break
        }
        if let failure { return .failure(failure, dispatched: total) }
        return skipped ? .skipped(total) : .success(total)
    }

    /// Acquire the single status-drain slot. Mirrors `beginDrainOrCoalesce`.
    private func beginStatusDrainOrCoalesce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if statusDrainInFlight { statusDrainAgain = true; return false }
        statusDrainInFlight = true
        return true
    }

    /// End a status-drain iteration. Mirrors `endDrainOrContinue`.
    private func endStatusDrainOrContinue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if statusDrainAgain && NADeviceSyncRecoveryBudget.hasTime { statusDrainAgain = false; return true }
        statusDrainAgain = false
        statusDrainInFlight = false
        return false
    }

    /// The status-drain body — always run serialized by `drainStatus`.
    private func drainStatusBody() async -> DeviceSyncDrainResult {
        let handlers = loadStatusHandlers()
        guard !handlers.isEmpty else { return .skipped(0) }
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        var dispatched = 0
        var failure: DeviceSyncError?
        for (key, handler) in handlers {
            guard NADeviceSyncRecoveryBudget.hasTime else { return .skipped(dispatched) }
            guard let secret = await handler.pairingSecret(), secret.count == 32 else {
                failure = failure ?? .notConfigured
                continue
            }
            let recordName = Self.statusRecordName(role: peerRole, key: key, pairingSecret: secret)
            let hit: PeerStatusHit
            do {
                hit = try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.drainStatus", seconds: 3, onFailure: accountFailureReporter) {
                    let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
                    guard record["key"] as? String == key,
                          record["role"] as? String == peerRole.rawValue,
                          let value = record["value"] as? String else {
                        throw DeviceSyncError.underlying(message: "CloudKit status \(key) has no readable value.")
                    }
                    return PeerStatusHit(value: value, modDate: record.modificationDate)
                }
            } catch {
                failure = failure ?? Self.mapError(error)
                continue
            }
            // Commit a status date only after its handler accepts the new value.
            let acknowledgement = recordName
            guard await handler.pairingSecret() == secret, holdsPairing else {
                failure = failure ?? .notConfigured
                continue
            }
            guard statusIsNewer(key: acknowledgement, hit.modDate) else { continue }
            guard await handler.apply(hit.value, hit.modDate, secret),
                  await handler.pairingSecret() == secret else {
                failure = failure ?? .transient(message: "CloudKit status \(key) could not be applied.")
                continue
            }
            commitStatusDate(key: acknowledgement, hit.modDate)
            dispatched += 1
            NADeviceSyncRecoveryBudget.didApplyData?()
        }
        guard NADeviceSyncRecoveryBudget.hasTime else { return .skipped(dispatched) }
        if let failure { return .failure(failure, dispatched: dispatched) }
        return .success(dispatched)
    }
}
#endif
