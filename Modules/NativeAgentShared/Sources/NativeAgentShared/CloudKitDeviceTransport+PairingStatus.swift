#if canImport(CloudKit) && !os(Linux)
import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+PairingStatus.swift` | Account-slot claims, pairing, presence and serialized status delivery |

extension CloudKitDeviceTransport {
    // MARK: pairing

    private static func pairingSecret(in record: CKRecord) throws -> Data {
        guard let hex = record["secretHex"] as? String,
              let secret = data(fromHex: hex), secret.count == 32 else {
            throw DeviceSyncError.underlying(message: """
                The existing CloudKit pairing record has an unreadable key. Repair that pairing record before claiming this account; \
                it has not been replaced.
                """)
        }
        return secret
    }

    public func publishPairing(secret: Data) async throws {
        try await withDeviceCKOperation("CloudKitDeviceTransport.publishPairing", onFailure: accountFailureReporter) {
            try await self.savePairing(secret: secret, policy: .changedKeys)
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

    /// The account has one Mac pairing slot: claim only an absent or self-owned record. Another Mac keeps the phone until the person moves it with
    /// `publishPairing`; an unreadable claim changes nothing.
    @discardableResult
    public func claimPairing(secret: Data) async throws -> Bool {
        guard role == .mac, secret.count == 32 else { throw DeviceSyncError.notConfigured }
        let recordName = "pairing.\(role.rawValue)"
        let publications = pairingPublicationCount()
        let slot: PairingSlot = try await withDeviceCKOperation("CloudKitDeviceTransport.claimPairing", onFailure: accountFailureReporter) {
            do {
                let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
                return .holds(try Self.pairingSecret(in: record))
            } catch let error as CKError where error.code == .unknownItem {
                return .empty
            }
        }
        switch slot {
        case .holds(let held):
            return settleClaim(elsewhere: held != secret, since: publications)
        case .empty:
            let owner: Data = try await withDeviceCKOperation("CloudKitDeviceTransport.createPairingClaim", onFailure: accountFailureReporter) {
                do {
                    // A new record has no server change tag: this policy creates only an absent slot, never replaces a concurrent winner.
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
            return settleClaim(elsewhere: owner != secret, since: publications)
        }
    }

    public var pairingHeldElsewhere: Bool {
        lock.lock(); defer { lock.unlock() }
        return pairingClaim == .elsewhere
    }

    /// Whether this transport may read and write the phone's records: always on the phone; on a Mac, only once it has read that it holds the pairing.
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

    /// A publication that landed while the claim was reading is newer than what the read saw, and already decided the answer.
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
        // Register pushes before draining so pairing changes cannot fall between the two.
        do {
            try await subscribeToPairingChanges()
        } catch {
            nativeLog("[ck-device] observePairing: subscription registration FAILED (no live push): \(error)")
        }
        do { try await drainPairing() }
        catch { nativeLog("[ck-device] observePairing: initial read failed: \(error)") }
    }

    // Reading the peer secret must not change this Mac's publication claim.
    public func peekPairingSecret(recovery: DeviceSyncRecovery = .init()) async throws -> Data {
        guard recovery.isActive else { throw CancellationError() }
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        let recordName = "pairing.\(peerRole.rawValue)"
        return try await withDeviceCKOperation("CloudKitDeviceTransport.peekPairingSecret", onFailure: accountFailureReporter) {
            let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
            return try Self.pairingSecret(in: record)
        }
    }

    /// Compare the peer record on every drain, regardless of its date, so a replaced local key is repaired. Return whether the handler installed a
    /// different key.
    @discardableResult
    public func drainPairing(recovery: DeviceSyncRecovery = .init()) async throws -> Bool {
        guard recovery.isActive else { throw CancellationError() }
        guard let handler = loadPairingHandler() else { return false }
        let secret = try await peekPairingSecret(recovery: recovery)
        guard await handler(secret) else { return false }
        recovery.didApplyData?()
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
        // Publication retains its slot until CloudKit completes.
        try await withDeviceCKOperation("CloudKitDeviceTransport.setStatus", onFailure: accountFailureReporter) {
            try await self.enqueueStatusWrite(key: key) {
                try self.refuseUnlessHoldingPairing()
                let ck = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: recordName))
                ck["key"] = key as CKRecordValue
                ck["value"] = value as CKRecordValue
                ck["role"] = self.role.rawValue as CKRecordValue
                ck["updatedAt"] = updatedAt as CKRecordValue
                let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
                op.savePolicy = .changedKeys
                // Phone status needs nondiscretionary transport while the app is backgrounded.
                op.qualityOfService = .userInitiated
                try await self.performModifyRecords(op)
            }
        }
    }

    // MARK: presence

    /// Reuse the deployed notification schema without alerts: presence has no direction, so subscriptions and incoming pulls exclude it. Each beat
    /// keeps it younger than the retention cutoff.
    private static func presenceRecordName(pairingSecret: Data) -> String {
        let identity = HMAC<SHA256>.authenticationCode(for: Data("NativeAgent.presence.identity.v1".utf8),
                                                     using: SymmetricKey(data: pairingSecret))
        return "presence.mac." + identity.map { String(format: "%02x", $0) }.joined()
    }

    public func setPresence(pairingSecret: Data) async throws {
        try refuseUnlessHoldingPairing()
        guard pairingSecret.count == 32 else { throw DeviceSyncError.notConfigured }
        let recordName = Self.presenceRecordName(pairingSecret: pairingSecret)
        try await withDeviceCKOperation("CloudKitDeviceTransport.setPresence", onFailure: accountFailureReporter) {
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
                // Liveness cannot be discretionary: utility priority permits network recovery deferral.
                op.qualityOfService = .userInitiated
                try await self.performModifyRecords(op)
            }
        }
    }

    public func peerPresence(pairingSecret: Data) async throws -> Date {
        guard pairingSecret.count == 32 else { throw DeviceSyncError.notConfigured }
        let recordName = Self.presenceRecordName(pairingSecret: pairingSecret)
        return try await withDeviceCKOperation("CloudKitDeviceTransport.peerPresence", onFailure: accountFailureReporter) {
            let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
            guard record["kind"] as? String == "presence",
                  let timestamp = record["createdAt"] as? String,
                  let encoded = record["payloadJSON"] as? String, let signature = Data(base64Encoded: encoded),
                  HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data("\(recordName):\(timestamp)".utf8),
                                                       using: SymmetricKey(data: pairingSecret)) else {
                throw DeviceSyncError.underlying(message: "The Mac presence record has no verified signature.")
            }
            // The signature authenticates the beat; CloudKit dates its freshness.
            guard let date = record.modificationDate else {
                throw DeviceSyncError.underlying(message: "The Mac presence record has no server date.")
            }
            return date
        }
    }

    private func enqueueStatusWrite(
        key: String,
        work: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            lock.lock()
            defer { lock.unlock() }
            // Keep one operation and the latest replacement. Each caller owns its result, including a value displaced before it reached the wire.
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
        onApply: @escaping @Sendable (String, Date?, Data, DeviceSyncRecovery) async -> Bool
    ) {
        setStatusHandler(key: key, DeviceStatusObserver(pairingSecret: pairingSecret, apply: onApply))
    }

    /// Server modification dates determine per-key freshness; dispatch only values newer than the last accepted value.
    @discardableResult
    public func drainStatus(recovery: DeviceSyncRecovery = .init()) async -> Int {
        (await drainStatusResult(recovery: recovery)).dispatchedCount
    }

    /// Success means every observed key was read and accepted (or already current). Missing data, failed handlers and skipped drains are not success.
    public func drainStatusResult(recovery: DeviceSyncRecovery = .init()) async -> DeviceSyncDrainResult {
        guard recovery.isActive, holdsPairing else { return .skipped(0) }
        // Serialize status drains so an older handler cannot overwrite a newer value.
        guard beginStatusDrainOrCoalesce() else { return .skipped(0) }
        var total = 0
        var failure: DeviceSyncError?
        var skipped = false
        while true {
            let result = await drainStatusBody(recovery: recovery)
            total += result.dispatchedCount
            switch result {
            case .success: break
            case .failure(let error, _): failure = failure ?? error
            case .skipped: skipped = true
            }
            if endStatusDrainOrContinue(recovery: recovery) { continue }
            break
        }
        if let failure { return .failure(failure, dispatched: total) }
        return skipped ? .skipped(total) : .success(total)
    }

    private func beginStatusDrainOrCoalesce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if statusDrainInFlight { statusDrainAgain = true; return false }
        statusDrainInFlight = true
        return true
    }

    private func endStatusDrainOrContinue(recovery: DeviceSyncRecovery) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if statusDrainAgain && recovery.isActive { statusDrainAgain = false; return true }
        statusDrainAgain = false
        statusDrainInFlight = false
        return false
    }

    /// Only the serialized status drain may run this body.
    private func drainStatusBody(recovery: DeviceSyncRecovery) async -> DeviceSyncDrainResult {
        let handlers = loadStatusHandlers()
        guard !handlers.isEmpty else { return .skipped(0) }
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        var dispatched = 0
        var failure: DeviceSyncError?
        for (key, handler) in handlers {
            guard recovery.isActive else { return .skipped(dispatched) }
            guard let secret = await handler.pairingSecret(), secret.count == 32 else {
                failure = failure ?? .notConfigured
                continue
            }
            let recordName = Self.statusRecordName(role: peerRole, key: key, pairingSecret: secret)
            let hit: PeerStatusHit
            do {
                hit = try await withDeviceCKOperation("CloudKitDeviceTransport.drainStatus",
                    onFailure: accountFailureReporter) {
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
            guard await handler.apply(hit.value, hit.modDate, secret, recovery),
                  await handler.pairingSecret() == secret else {
                failure = failure ?? .transient(message: "CloudKit status \(key) could not be applied.")
                continue
            }
            commitStatusDate(key: acknowledgement, hit.modDate)
            dispatched += 1
            recovery.didApplyData?()
        }
        guard recovery.isActive else { return .skipped(dispatched) }
        if let failure { return .failure(failure, dispatched: dispatched) }
        return .success(dispatched)
    }
}
#endif
