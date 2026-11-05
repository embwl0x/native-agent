import Darwin
import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `iCloudSyncEngine+Transactions.swift` | Signed envelope retention, pairing reconciliation, mailbox recovery and bounded locked persistence |

extension iCloudSyncEngine {
    /// Only actual missing files are optional for response/envelope owners; unreadable bytes must throw.
    nonisolated static func readActionMailboxFile(at file: URL) throws -> Data? {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError { return nil }
            throw error
        }
        if FileManager.default.isUbiquitousItem(at: file) {
            try FileManager.default.startDownloadingUbiquitousItem(at: file)
        }
        return try coordinatedRead(file, options: [.withoutChanges])
    }

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
                let data = try VolumeIO.contents(of: file)
                let action = try JSONDecoder().decode(InboxAction.self, from: data)
                guard let signature = action.signature else {
                    throw SyncError.persistence("A pending action has no verifiable pairing signature.")
                }
                return (action, try BridgeMessage.innerActionCanonicalBody(data), signature)
            }
            let ledgerFiles = try files(in: transactions)
            let records = try ledgerFiles.map {
                try JSONDecoder().decode(ICloudTransactionRecord.self, from: VolumeIO.contents(of: $0))
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

    /// Outer HMAC admits mailbox bytes; pollResponse alone verifies inner HMAC/correlation and closes the transaction.
    func persistCloudKitActionResponse(
        _ text: String,
        actionID: String
    ) async -> Bool {
        guard UUID(uuidString: actionID) != nil,
              let responsesDir,
              let data = text.data(using: .utf8) else {
            syncError = "CloudKit action response has no valid mailbox identity or initialized storage."
            return false
        }
        let url = responsesDir.appendingPathComponent("\(actionID).json")
        do {
            let response = try JSONDecoder().decode([String: String].self, from: data)
            guard let action = response["action"], !action.isEmpty else {
                throw SyncError.persistence("CloudKit action response omitted its action identity.")
            }
            try await VolumeIO.run {
                try data.write(to: url, options: .atomic)
            }
            // Wake response waiters only after the bytes are durable.
            ActionResponseWaiters.shared.signal(actionID)
            _ = try await pollResponse(msgId: actionID, expectedAction: action,
                                   settlesAnswersFromPreviousPairing: true)
            return true
        } catch {
            syncError = "CloudKit action response could not be read or settled: \(error.localizedDescription)"
            return false
        }
    }

    /// Retained sends outlive UI waits; on launch every unsettled one is polled by exact identity within the budget. Settled records are
    /// the retention sweep's, never a recovery gap; a send left unpolled when the budget ends stays retained and settles on its arrival.
    func settleUnobservedActionResponses(budget: OperationWaitBudget = .init()) async {
        do {
            try await OperationWaitBudget.withDeadline(seconds: 5, budget: budget) { @MainActor budget in
                await self.recoverUnobservedActionResponses(budget: budget)
            }
        } catch {
            syncError = "Action mailbox recovery did not finish: \(error.localizedDescription). Unsettled responses remain retained."
        }
    }

    private func recoverUnobservedActionResponses(budget: OperationWaitBudget) async {
        guard let transactionDir else { return }
        let generation = lifecycleGeneration
        let recovered: (pending: [(String, String)], gaps: [String])
        do { recovered = try await VolumeIO.run(budget: budget) {
            let enumerator = try FileManager.default.contentsOfDirectory(atPath: transactionDir.path)
            var pending: [(String, String)] = []
            var gaps: [String] = []
            for name in enumerator.filter({ $0.hasSuffix(".json") }).sorted() {
                do {
                    let file = transactionDir.appendingPathComponent(name)
                    let record = try JSONDecoder().decode(ICloudTransactionRecord.self, from: VolumeIO.contents(of: file))
                    guard record.direction == "ios_to_mac",
                          !Self.isTerminalTransactionState(record.state) else { continue }
                    guard let messageID = record.msgId else {
                        throw SyncError.persistence("Pending action has no message identity.")
                    }
                    pending.append((messageID, record.action))
                } catch { gaps.append("\(name): \(error.localizedDescription)") }
            }
            return (pending, gaps)
        } } catch {
            syncError = """
                Pending action recovery could not read its transaction evidence: \(error.localizedDescription). Saved actions remain pending; repair iPhone \
                transaction storage before retrying recovery.
                """
            return
        }
        var gaps = recovered.gaps
        for (msgId, action) in recovered.pending {
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            if budget.expired {
                NSLog("[iCloudSync] launch recovery budget ended; %ld unsettled sends stay retained until their responses arrive",
                      recovered.pending.count)
                break
            }
            do {
                _ = try await pollResponse(msgId: msgId, expectedAction: action, settlesAnswersFromPreviousPairing: true, budget: budget)
            } catch { gaps.append("\(msgId): \(error.localizedDescription)") }
        }
        guard generation == lifecycleGeneration, !Task.isCancelled else { return }
        if !gaps.isEmpty { syncError = "Action mailbox recovery is incomplete: " + gaps.joined(separator: ". ") }
    }

    /// Persist the exact signed envelope before submission so unresolved retries retain message, transaction, timestamp and signature.
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
                let data = try VolumeIO.contents(of: file)
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
            guard try VolumeIO.contents(of: file) == data else {
                throw SyncError.persistence("The pending action could not be verified after saving.")
            }
            return (requested, data, false)
        }
    }

    func pendingCloudKitAction(msgId: String, budget: OperationWaitBudget = .init()) async throws -> InboxAction? {
        guard UUID(uuidString: msgId) != nil else { throw SyncError.persistence("Invalid pending action identity.") }
        guard let transactionDir else { throw SyncError.notSetup }
        let file = transactionDir.appendingPathComponent("pending-actions/\(msgId).json")
        return try await VolumeIO.run(budget: budget) {
            guard let data = try Self.readActionMailboxFile(at: file) else { return nil }
            let action = try JSONDecoder().decode(InboxAction.self, from: data)
            guard action.msgId == msgId else { throw SyncError.persistence("Pending action filename and message identity disagree.") }
            return action
        }
    }

    /// Previous-pairing answers settle as orphaned; files remain for ledger pruning.
    func settleAnswerFromPreviousPairing(msgId: String, transactionId: String, action: String, budget: OperationWaitBudget = .init()) async throws {
        try await writeTransaction(
            id: transactionId,
            action: action,
            state: "orphaned",
            error: "Answered under a previous pairing key; this iPhone has paired again since.",
            msgId: msgId,
            budget: budget
        )
    }

    func retirePendingCloudKitAction(msgId: String, budget: OperationWaitBudget = .init()) async throws {
        guard UUID(uuidString: msgId) != nil, let transactionDir else { return }
        let file = transactionDir.appendingPathComponent("pending-actions/\(msgId).json")
        try await VolumeIO.run(budget: budget) {
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
        msgId: String? = nil,
        budget: OperationWaitBudget = .init()
    ) async throws {
        guard let transactionDir else {
            throw SyncError.persistence("iCloud transaction ledger is not initialized.")
        }
        let capturedTransactionDir = transactionDir
        guard !budget.expired else { throw budget.cancellationError }
        let timeoutSeconds = min(max(0.05, transactionWriteTimeoutSeconds),
            budget.wallDate?.timeIntervalSinceNow ?? .infinity)
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            let resumeBox = ContinuationOnce<Result<Void, Error>>()
            resumeBox.install(continuation)
            // Awaited transitions preserve ordering without blocking unrelated transactions.
            DispatchQueue.global(qos: .utility).async {
                do {
                    guard resumeBox.isPending else { return }

                    let now = NativeTimestampFormat.plainZulu(Date())
                    let url = capturedTransactionDir.appendingPathComponent("\(id).json")
                    // Stable lock stripes serialize per-action read/modify/write across send and poll with bounded lock-file growth.
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

                    // A verified response may precede CloudKit submission completion and must remain authoritative.
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
