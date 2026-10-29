#if canImport(CloudKit) && !os(Linux)
import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+PairingStatus.swift` | Pairing, presence and serialized status publication |

extension CloudKitDeviceTransport {
    // MARK: pairing

    public func publishPairing(secret: Data) async throws {
        let recordType = NADeviceSyncRecordType.pairingDevice
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        let recordName = "pairing.\(role.rawValue)"
        let publishedAt = NativeTimestampFormat.fractionalZulu(Date())
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.publishPairing", onFailure: accountFailureReporter) {
                let ck = CKRecord(
                    recordType: recordType,
                    recordID: CKRecord.ID(recordName: recordName)
                )
                ck["role"] = self.role.rawValue as CKRecordValue
                ck["secretHex"] = secretHex as CKRecordValue
                ck["publishedAt"] = publishedAt as CKRecordValue
                let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
                // Pairing is a mutable singleton per device — overwrite freely.
                op.savePolicy = .changedKeys
                op.qualityOfService = .userInitiated
                try await self.performModifyRecords(op)
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit publishPairing timed out")
        }
        notePairingPublished()
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
                return (record["secretHex"] as? String).flatMap(Self.data(fromHex:)).map(PairingSlot.holds) ?? .empty
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
            do { try await publishPairing(secret: secret) } catch { return nil }
            return true
        }
    }

    /// True while another Mac on this Apple Account holds the pairing.
    public var pairingHeldElsewhere: Bool {
        lock.lock(); defer { lock.unlock() }
        return heldElsewhere
    }

    private func notePairingPublished() {
        lock.lock(); defer { lock.unlock() }
        pairingPublications &+= 1
        heldElsewhere = false
    }

    private func pairingPublicationCount() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return pairingPublications
    }

    /// A publication that landed while the claim was reading is newer than
    /// what the read saw, and already decided the answer.
    private func settleClaim(elsewhere: Bool, since publications: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pairingPublications == publications { heldElsewhere = elsewhere }
        return !heldElsewhere
    }

    func refuseWhilePairedElsewhere() throws {
        if pairingHeldElsewhere { throw DeviceSyncError.pairedElsewhere }
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
            guard let hex = record["secretHex"] as? String else { return nil }
            return Self.data(fromHex: hex)
        } ?? nil
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

    public func setStatus(key: String, value: String) async throws {
        try refuseWhilePairedElsewhere()
        let recordType = NADeviceSyncRecordType.status
        let recordName = "status.\(role.rawValue).\(key)"
        let updatedAt = NativeTimestampFormat.fractionalZulu(Date())
        // The lane belongs to the actual CloudKit completion, not the caller's
        // bounded wait. A timed-out write must settle before a successor starts.
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.setStatus", seconds: 15, onFailure: accountFailureReporter) {
                try await self.enqueueStatusWrite(key: key) {
                    let ck = CKRecord(
                        recordType: recordType,
                        recordID: CKRecord.ID(recordName: recordName)
                    )
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
    /// because that type's subscription fires on CREATION only: an update
    /// wakes nobody, so the beat costs the phone no push. It has no
    /// `direction`, so the incoming pull never returns it, and it is modified
    /// every beat, so the retention sweep never reaches it. A type of its own
    /// would need a production schema deploy.
    private static func presenceRecordName(pairingSecret: Data) -> String {
        let identity = HMAC<SHA256>.authenticationCode(for: Data("NativeAgent.presence.identity.v1".utf8),
                                                     using: SymmetricKey(data: pairingSecret))
        return "presence.mac." + identity.map { String(format: "%02x", $0) }.joined()
    }

    public func setPresence(pairingSecret: Data) async throws {
        try refuseWhilePairedElsewhere()
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
                    op.qualityOfService = .utility
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
    public func observeStatus(key: String, onApply: @escaping @Sendable (String, Date?) async -> Bool) {
        setStatusHandler(key: key, onApply)
    }

    /// Pull the PEER's status singleton for every observed key and dispatch each
    /// to its handler iff newer than the last dispatched value (LWW by server
    /// modificationDate, per key). Returns the number of handlers invoked.
    @discardableResult
    public func drainStatus() async -> Int {
        guard NADeviceSyncRecoveryBudget.hasTime else { return 0 }
        guard !pairingHeldElsewhere else { return 0 }
        // Serialize status drains so an older handler cannot overwrite a newer value.
        guard beginStatusDrainOrCoalesce() else { return 0 }
        var total = 0
        while true {
            total += await drainStatusBody()
            if endStatusDrainOrContinue() { continue }
            break
        }
        return total
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
    private func drainStatusBody() async -> Int {
        let handlers = loadStatusHandlers()
        guard !handlers.isEmpty else { return 0 }
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        var dispatched = 0
        for (key, handler) in handlers {
            guard NADeviceSyncRecoveryBudget.hasTime else { break }
            let recordName = "status.\(peerRole.rawValue).\(key)"
            let hit: PeerStatusHit? = await withDeviceCKTimeout("CloudKitDeviceTransport.drainStatus", seconds: 3, onFailure: accountFailureReporter) {
                let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
                guard let value = record["value"] as? String else { return nil }
                return PeerStatusHit(value: value, modDate: record.modificationDate)
            } ?? nil
            guard let hit else { continue }
            // Commit a status date only after its handler accepts the new value.
            guard statusIsNewer(key: key, hit.modDate) else { continue }
            guard await handler(hit.value, hit.modDate) else { continue }
            commitStatusDate(key: key, hit.modDate)
            dispatched += 1
            NADeviceSyncRecoveryBudget.didApplyData?()
        }
        return dispatched
    }
}
#endif
