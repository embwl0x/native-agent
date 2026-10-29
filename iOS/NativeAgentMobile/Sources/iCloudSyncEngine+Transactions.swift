import Darwin
import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `iCloudSyncEngine+Transactions.swift` | Pending signed envelopes, pairing reconciliation, response mailbox recovery and deadline-bound transaction persistence with striped locking and exact-byte readback |

extension iCloudSyncEngine {
    nonisolated static func reconcileActionsForConnectionRepair(
        transactions: URL?, responses: URL?, inbox: URL?, currentSecret: Data? = nil
    ) async throws {
        try await VolumeIO.run {
            let manager = FileManager.default
            func files(in directory: URL?) throws -> [URL] {
                guard let directory, manager.fileExists(atPath: directory.path) else { return [] }
                return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
            }
            func removeIfPresent(_ file: URL?) throws {
                guard let file, manager.fileExists(atPath: file.path) else { return }
                try manager.removeItem(at: file)
            }
            let pendingDirectory = transactions?.appendingPathComponent("pending-actions", isDirectory: true)
            let pendingFiles = try files(in: pendingDirectory)
            let pendingActions = try pendingFiles.map { file in
                let data = try Data(contentsOf: file)
                let action = try JSONDecoder().decode(InboxAction.self, from: data)
                guard let signature = action.signature else {
                    throw SyncError.persistence("A pending action has no verifiable pairing signature.")
                }
                return (action, try BridgeMessage.innerActionCanonicalBody(data), signature)
            }
            let ledgerFiles = try files(in: transactions)
            let records = try ledgerFiles.map {
                try JSONDecoder().decode(ICloudTransactionRecord.self, from: Data(contentsOf: $0))
            }
            guard let currentSecret else { return }
            var staleMessageIDs = Set<String>()
            var staleFiles: [URL] = []
            for (file, retained) in zip(pendingFiles, pendingActions) {
                let (action, canonical, signature) = retained
                let expected = BridgeMessage.hmacHex(of: canonical, secret: currentSecret)
                guard signature.lowercased() != expected else { continue }
                staleMessageIDs.insert(action.msgId)
                staleFiles.append(file)
            }
            for (file, record) in zip(ledgerFiles, records) {
                guard record.direction == "ios_to_mac", !isTerminalTransactionState(record.state),
                      staleMessageIDs.contains(record.msgId ?? record.id) else { continue }
                var retired = record
                retired.state = "orphaned"
                retired.updatedAt = NativeTimestampFormat.plainZulu(Date())
                retired.lastError = "Connection repaired; this action belongs to the previous pairing."
                try JSONEncoder().encode(retired).write(to: file, options: .atomic)
                staleMessageIDs.insert(record.msgId ?? record.id)
            }
            for file in staleFiles { try removeIfPresent(file) }
            for messageID in staleMessageIDs {
                guard UUID(uuidString: messageID) != nil else { continue }
                try removeIfPresent(responses?.appendingPathComponent("\(messageID).json"))
                try removeIfPresent(inbox?.appendingPathComponent("\(messageID).json"))
            }
        }
    }

    /// Store an outer-HMAC-verified response; `pollResponse` alone verifies
    /// its inner HMAC/correlation and closes the transaction.
    func persistCloudKitActionResponse(
        _ text: String,
        actionID: String
    ) async -> Bool {
        guard UUID(uuidString: actionID) != nil,
              let responsesDir,
              let data = text.data(using: .utf8),
              let response = try? JSONDecoder().decode([String: String].self, from: data) else {
            return false
        }
        let url = responsesDir.appendingPathComponent("\(actionID).json")
        do {
            try await VolumeIO.run {
                try data.write(to: url, options: .atomic)
            }
            // Wake response waiters only after the bytes are durable.
            ActionResponseWaiters.shared.signal(actionID)
            if let action = response["action"], Self.isUnobservedAction(action) {
                _ = await pollResponse(msgId: actionID, expectedAction: action,
                                       settlesAnswersFromPreviousPairing: true)
            }
            return true
        } catch {
            syncError = "CloudKit action response could not be persisted: \(error.localizedDescription)"
            return false
        }
    }

    private nonisolated static func isUnobservedAction(_ action: String) -> Bool {
        action == "recordNotificationReceipt" || action == "pairDevice"
    }

    /// These automatic sends have no UI waiter. Recover their replies at launch
    /// and on legacy response nudges, including replies delivered after a quit.
    func settleUnobservedActionResponses() async {
        guard let transactionDir else { return }
        let generation = lifecycleGeneration
        let pending = await VolumeIO.run {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: transactionDir, includingPropertiesForKeys: nil
            )) ?? []
            return files.compactMap { file -> (String, String)? in
                guard file.pathExtension == "json",
                      let data = try? Data(contentsOf: file),
                      let record = try? JSONDecoder().decode(ICloudTransactionRecord.self, from: data),
                      record.direction == "ios_to_mac",
                      Self.isUnobservedAction(record.action),
                      !Self.isTerminalTransactionState(record.state) else { return nil }
                return (record.msgId ?? record.id, record.action)
            }
        }
        for (msgId, action) in pending {
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            _ = await pollResponse(msgId: msgId, expectedAction: action, settlesAnswersFromPreviousPairing: true)
        }
    }

    /// Retain the exact signed envelope before submission. A retry of an
    /// unresolved action reuses its message, transaction, timestamp and signature.
    func retainedCloudKitAction(
        _ requested: InboxAction,
        secret: Data,
        intentionalNewRequest: Bool
    ) async throws -> (InboxAction, Data, Bool) {
        guard let transactionDir else { throw SyncError.notSetup }
        let directory = transactionDir.appendingPathComponent("pending-actions", isDirectory: true)
        let retained: (InboxAction, Data)? = try await VolumeIO.run {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var matching: (InboxAction, Data)?
            var ambiguous = false
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.pathExtension == "json" {
                let data = try Data(contentsOf: file)
                let retained = try JSONDecoder().decode(InboxAction.self, from: data)
                if retained.msgId == requested.msgId {
                    // An occupied identity must match every signed body field.
                    guard retained.transactionId == requested.transactionId,
                          retained.clientId == requested.clientId,
                          retained.action == requested.action,
                          retained.createdAt == requested.createdAt,
                          retained.protocolVersion == requested.protocolVersion,
                          retained.payload == requested.payload else {
                        throw SyncError.persistence("The action message ID already belongs to a different pending request.")
                    }
                    return (retained, data)
                }
                // Recover the pending signed identity before submitting provisional IDs after relaunch.
                if !intentionalNewRequest, retained.clientId == requested.clientId,
                   retained.action == requested.action, retained.payload == requested.payload {
                    if matching != nil { ambiguous = true }
                    matching = (retained, data)
                }
            }
            guard !ambiguous else {
                throw SyncError.persistence("Multiple pending actions match this request; retry with the original message identity.")
            }
            return matching
        }
        if let retained { return (retained.0, retained.1, true) }
        let data = try await PhoneSigningIdentity.shared.signedActionData(requested, secret: secret)
        return try await VolumeIO.run {
            let file = directory.appendingPathComponent("\(requested.msgId).json")
            try data.write(to: file, options: .atomic)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.synchronize()
            guard try Data(contentsOf: file) == data else {
                throw SyncError.persistence("The pending action could not be verified after saving.")
            }
            return (requested, data, false)
        }
    }

    func pendingCloudKitAction(msgId: String) async -> InboxAction? {
        guard UUID(uuidString: msgId) != nil, let transactionDir else { return nil }
        let file = transactionDir.appendingPathComponent("pending-actions/\(msgId).json")
        return await VolumeIO.run {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(InboxAction.self, from: data)
        }
    }

    /// Previous-pairing answers settle as orphaned; files remain for ledger pruning.
    func settleAnswerFromPreviousPairing(msgId: String, transactionId: String, action: String) async {
        guard UUID(uuidString: msgId) != nil else { return }
        try? await writeTransaction(
            id: transactionId,
            action: action,
            state: "orphaned",
            error: "Answered under a previous pairing key; this iPhone has paired again since.",
            msgId: msgId
        )
    }

    func retirePendingCloudKitAction(msgId: String) async throws {
        guard UUID(uuidString: msgId) != nil, let transactionDir else { return }
        let file = transactionDir.appendingPathComponent("pending-actions/\(msgId).json")
        try await VolumeIO.run {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    func writeTransaction(
        id: String,
        action: String,
        state: String,
        attempts: Int = 0,
        error: String? = nil,
        response: [String: String]? = nil,
        msgId: String? = nil
    ) async throws {
        guard let transactionDir else {
            throw SyncError.persistence("iCloud transaction ledger is not initialized.")
        }
        let capturedTransactionDir = transactionDir
        let timeoutSeconds = max(0.05, transactionWriteTimeoutSeconds)
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            let resumeBox = ContinuationOnce<Result<Void, Error>>()
            resumeBox.install(continuation)
            // Awaited transitions preserve ordering without blocking unrelated transactions.
            DispatchQueue.global(qos: .utility).async {
                do {
                    guard resumeBox.isPending else { return }

                    let now = NativeTimestampFormat.plainZulu(Date())
                    let url = capturedTransactionDir.appendingPathComponent("\(id).json")
                    // Fixed stripes serialize each retained action's read/modify/write
                    // across send completion and polling with bounded, stable lock files.
                    let stripe = id.utf8.reduce(UInt(0)) { ($0 &* 31 &+ UInt($1)) % 16 }
                    let lockURL = capturedTransactionDir.appendingPathComponent(".transaction-\(stripe).lock")
                    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
                    guard descriptor >= 0 else {
                        throw SyncError.persistence("Could not open the action transaction lock.")
                    }
                    defer { close(descriptor) }
                    guard flock(descriptor, LOCK_EX) == 0 else {
                        throw SyncError.persistence("Could not acquire the action transaction lock.")
                    }
                    defer { flock(descriptor, LOCK_UN) }
                    guard resumeBox.isPending else { return }
                    let existingData = FileManager.default.fileExists(atPath: url.path)
                        ? try Self.coordinatedRead(url, options: [.withoutChanges]) : nil
                    let existing: ICloudTransactionRecord?
                    if let existingData {
                        do {
                            existing = try JSONDecoder().decode(ICloudTransactionRecord.self, from: existingData)
                        } catch {
                            throw SyncError.persistence(
                                "iCloud transaction \(id) could not decode existing state: \(error.localizedDescription)"
                            )
                        }
                    }
                    else {
                        existing = nil
                    }

                    // A response can arrive while the submission is still awaiting
                    // its CloudKit completion. Keep that verified receipt authoritative.
                    if existing?.response != nil && ["queued", "sent", "outcome_unknown"].contains(state) {
                        resumeBox.resume(.success(()))
                        return
                    }
                    let record = ICloudTransactionRecord(
                        id: id,
                        direction: "ios_to_mac",
                        action: action,
                        state: state,
                        createdAt: existing?.createdAt ?? now,
                        updatedAt: now,
                        attempts: max(attempts, existing?.attempts ?? 0),
                        lastError: error ?? existing?.lastError,
                        response: response ?? existing?.response,
                        msgId: msgId ?? existing?.msgId,
                        actionDigest: existing?.actionDigest
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                    let data = try encoder.encode(record)
                    try Self.writeAndVerifyTransaction(data, expected: record, to: url)
                    resumeBox.resume(.success(()))
                } catch {
                    resumeBox.resume(.failure(error as? SyncError ?? SyncError.persistence(
                        "iCloud transaction \(id) state \(state) was not persisted: \(error.localizedDescription)"
                    )))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                resumeBox.resume(.failure(SyncError.timeout(
                    "iCloud transaction \(id) state \(state) timed out after \(Self.timeoutLabel(timeoutSeconds))s"
                )))
            }
        }
        try result.get()
    }

    /// Terminal send failure requires a verified ledger write; report both failures.
    func persistTerminalSendFailure(
        transactionID: String,
        action: String,
        sendError: Error
    ) async throws {
        do {
            try await writeTransaction(
                id: transactionID,
                action: action,
                state: "send_failed",
                attempts: 1,
                error: sendError.localizedDescription
            )
        } catch {
            throw SyncError.persistence(
                "iCloud send failed (\(sendError.localizedDescription)) and its terminal receipt could not be persisted (\(error.localizedDescription))."
            )
        }
    }

    private nonisolated static func writeAndVerifyTransaction(
        _ data: Data,
        expected: ICloudTransactionRecord,
        to url: URL
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
                let handle = try FileHandle(forWritingTo: writeURL)
                defer { try? handle.close() }
                try handle.synchronize()
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SyncError.persistence("iCloud transaction \(expected.id) disappeared after write.")
        }
        let persistedData = try coordinatedRead(url, options: [.withoutChanges])
        guard persistedData == data else {
            throw SyncError.persistence(
                "iCloud transaction \(expected.id) failed read-back verification for state \(expected.state)."
            )
        }
    }

    nonisolated static func timeoutLabel(_ seconds: TimeInterval) -> String {
        Int(exactly: seconds).map(String.init) ?? String(format: "%.2f", seconds)
    }
}
