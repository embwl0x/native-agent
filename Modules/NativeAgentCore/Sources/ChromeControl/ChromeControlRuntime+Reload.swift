import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
import NativeAgentCore
import TrustCenter
import MacControl
// Blueprint: | `ChromeControlRuntime+Reload.swift` | `ChromeControlRuntime` reload members: manifest/file observations, automatic/manual attempts and reconnect-confirmed receipts with running/folder code digests; browser process identity and listener generation fence reload proof |

extension ChromeControlRuntime {
    public enum ReloadSource: String, Sendable, Codable { case automatic, manual, verb }
    struct ExtensionReloadAttempt: Codable {
        let id: String
        let source: ReloadSource
        let before: String
        let beforeCode: String?
        var diskCode: String?
        let shipped: String
        let path: String
        let browserPID: pid_t
        let browserBirthStamp: UInt64
        let startedAt: Date
        var phase = "sending"
        var after: String?
        var afterCode: String?
        var completedAt: Date?
        var reason: String?
        var pending: Bool { phase == "sending" || phase == "awaiting_reconnect" }
        var receipt: JSONValue { .object([
            "id": .string(id), "action": .string("chrome.reload_extension"),
            "source": .string(source.rawValue),
            "front_app_changed": .bool(false), "focus_changed": .bool(false),
            "status": .string(phase), "before_version": .string(before),
            "after_version": after.map(JSONValue.string) ?? .null,
            "before_code": beforeCode.map(JSONValue.string) ?? .null,
            "after_code": afterCode.map(JSONValue.string) ?? .null,
            "folder_code": diskCode.map(JSONValue.string) ?? .null,
            "shipped_version": .string(shipped), "extension_path": .string(path),
            "started_at": ChromeControlRuntime.dateJSON(startedAt),
            "completed_at": ChromeControlRuntime.dateJSON(completedAt),
            "reason": reason.map(JSONValue.string) ?? .null,
            "remedy": completedAt != nil && phase != "succeeded" ? Repair.remedy(
                owner: "Chrome / extension reload", nextCall: .object(["tool": .string("app"),
                    "input": .object(["action": .string(phase == "unconfirmed" ? "chrome.status" : "chrome.reload_extension")])]), tap: nil) : .null,
            "provenance": .string("raw view · Chrome native messaging reload transport and accepted reconnect version; no page snapshot was read."),
        ]) }
    }
    var currentReloadReceipt: JSONValue {
        if extensionReload?.pending == true { return extensionReload!.receipt }
        let latest = reloadPreflightFailure ?? extensionReload?.receipt ?? facts.extensionReload
        if readyChannel != nil, let files = extensionFiles, facts.extensionVersion == files.shippedVersion {
            if case .object(let receipt)? = latest, receipt["status"] == .string("succeeded"),
               receipt["after_version"] == .string(files.shippedVersion) { return .object(receipt) }
            // Only an accepted greeting after a failed read/preflight supersedes that failure.
            if case .object(let receipt)? = latest, receipt["status"] == .string("failed"),
               let completed = facts.extensionReloadAt, let seen = facts.extensionSeenAt,
               completed >= seen {
                return .object(receipt)
            }
            return .object([
                "status": .string("matched"), "running_version": .string(files.shippedVersion),
                "shipped_version": .string(files.shippedVersion),
                "reason": .string("The accepted extension is running the shipped version."),
                "provenance": .string("raw view · accepted Chrome extension greeting and shipped manifest; previous reload attempts are last-seen history."),
            ])
        }
        return latest ?? .null
    }

    func readExtensionFiles(fresh: Bool = false) {
        // Content follows file events; permission-only changes need an access check.
        let access = Dictionary(uniqueKeysWithValues: extensionFilePaths.map {
            ($0, FileManager.default.isReadableFile(atPath: $0.path))
        })
        if !fresh, extensionFileEvents != nil, access == extensionFileAccess {
            return
        }
        defer { publishConnectionState() }
        do {
            extensionFiles = try extensionFileReader.read()
            extensionFilesError = nil
        } catch {
            extensionFiles = nil
            extensionFilesError = "Chrome extension version check failed: \(error.localizedDescription)"
        }
        let paths = extensionFileReader.watchedPaths
        extensionFileAccess = Dictionary(uniqueKeysWithValues: paths.map {
            ($0, access[$0] ?? FileManager.default.isReadableFile(atPath: $0.path))
        })
        // On-demand reads remain available while off; passive observations belong to active transport.
        guard !runtimeStopped, listenerDescriptor >= 0 else { return }
        guard paths != extensionFilePaths || extensionFileEvents == nil else { return }
        extensionFileTask?.cancel()
        extensionFileEvents?.cancel()
        extensionFilePaths = paths
        let events = FileChangeEvents(paths: Array(paths))
        extensionFileEvents = events
        extensionFileTask = Task { [weak self] in
            for await _ in events.stream {
                guard !Task.isCancelled else { return }
                await self?.extensionFilesChanged(events)
            }
        }
        // The initial edge after FileChangeEvents arms closes the read-before-watch gap.
    }

    private func extensionFilesChanged(_ events: FileChangeEvents) async {
        guard extensionFileEvents === events, !Task.isCancelled else { return }
        readExtensionFiles(fresh: true)
        guard extensionFileEvents === events, !Task.isCancelled else { return }
        await reloadIfNeeded()
    }

    /// The explicit reversible verb can retry a failed/stale automatic attempt.
    /// Completion follows accepted attach, never an elapsed reconnect timer.
    public func reloadExtension(source: ReloadSource = .manual) async throws -> JSONValue {
        try await authorizeEffect()
        if extensionReload?.pending == true {
            let browsers = await Self.runningChromeProcesses()
            reconcileReloadBrowser(browsers)
        }
        if extensionReload?.pending != true {
            readExtensionFiles()
            do {
                guard let channel else { throw await connectionFailure() }
                try await beginExtensionReload(on: channel, source: source)
            } catch {
                return recordReloadPreflightFailure(error, source: source)
            }
        }
        if extensionReload?.pending != true { return extensionReload!.receipt }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if extensionReload?.pending != true { continuation.resume(returning: extensionReload!.receipt) }
                else { reloadWaiters[waiter] = continuation }
            }
        } onCancel: {
            Task { await self.cancelReloadWaiter(waiter) }
        }
    }

    private func cancelReloadWaiter(_ id: UUID) {
        reloadWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func recordReloadPreflightFailure(_ error: Error, source: ReloadSource) -> JSONValue {
        var fields: [String: JSONValue] = [
            "action": .string("chrome.reload_extension"), "status": .string("failed"),
            "source": .string(source.rawValue), "effects": .string("none"),
            "front_app_changed": .bool(false), "focus_changed": .bool(false),
            "dispatched": .bool(false), "before_version": facts.extensionVersion.map(JSONValue.string) ?? .null,
            "after_version": .null, "shipped_version": extensionFiles.map { .string($0.shippedVersion) } ?? .null,
            "extension_path": extensionFiles.map { .string($0.path) } ?? .null,
            "completed_at": Self.dateJSON(Date()),
            "reason": .string("Extension reload unavailable: \(error.localizedDescription). Call chrome.reload_extension after resolving this reason; no automatic retry."),
            "provenance": .string("raw view · Chrome reload preflight, native connection and registered unpacked manifest; no reload was dispatched and no page was read."),
        ]
        if let failure = error as? ToolFailureError, let owner = failure.owner {
            fields["remedy"] = Repair.remedy(owner: owner,
                nextCall: failure.nextCall.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) },
                tap: failure.tap)
        } else if let failure = error as? ChromeControlRuntimeError {
            fields["remedy"] = failure.remedy
        }
        let receipt = JSONValue.object(fields)
        reloadPreflightFailure = receipt
        facts.extensionReload = receipt
        facts.extensionReloadAt = Date()
        saveConnectionFacts()
        return receipt
    }

    func extensionReloadFailed(id: String, reason: String) {
        guard extensionReload?.id == id else { return }
        finishExtensionReload(phase: "failed", reason: "Extension reload failed: \(reason). Call chrome.reload_extension to try explicitly; no automatic retry.")
    }

    func finishExtensionReload(phase: String, after: String? = nil, afterCode: String? = nil, folderCode: String? = nil, reason: String? = nil) {
        guard var attempt = extensionReload, attempt.pending else { return }
        reconnectDeadline?.cancel()
        reconnectDeadline = nil
        attempt.phase = phase
        attempt.after = after
        attempt.afterCode = afterCode
        attempt.diskCode = folderCode ?? attempt.diskCode
        attempt.reason = reason
        attempt.completedAt = Date()
        extensionReload = attempt
        facts.extensionReload = attempt.receipt
        facts.extensionReloadAt = attempt.completedAt
        saveConnectionFacts()
        let waiters = reloadWaiters.values
        reloadWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: attempt.receipt) }
    }

    private func beginExtensionReload(on connection: ChromeControlChannel, source: ReloadSource) async throws {
        guard extensionCanReload else {
            throw ToolFailureError("This Chrome extension needs to be loaded again.", effects: .none,
                owner: "Chrome / extension reload protocol",
                nextCall: ToolFailureError.call("app", ["action": .string("chrome.setup")]))
        }
        try ChromeExtensionFolder.prepare()
        readExtensionFiles(fresh: true)
        guard let files = extensionFiles, let before = facts.extensionVersion,
              let pid = connectedBrowserPID, pid > 1,
              let birthStamp = ChromeHostIdentity.processBirthStamp(pid) else {
            throw ToolFailureError(extensionFilesError
                ?? "The accepted Chrome connection has no live browser process identity for an extension reload.",
                effects: .none, owner: "Chrome / registered extension and browser identity",
                nextCall: ToolFailureError.call("app", ["action": .string("chrome.setup")]))
        }
        // Reload reads Chrome's registered folder, which must hold the shipped version.
        guard files.diskVersion == files.shippedVersion else {
            throw ToolFailureError("Chrome's extension folder (\(files.path)) holds \(files.diskVersion), not the shipped \(files.shippedVersion). Load the current copy.", effects: .none,
                owner: "Chrome / registered extension folder",
                nextCall: ToolFailureError.call("app", ["action": .string("chrome.setup")]))
        }
        let id = UUID().uuidString.lowercased()
        reloadPreflightFailure = nil
        extensionReload = ExtensionReloadAttempt(id: id, source: source, before: before, beforeCode: facts.extensionCode,
            diskCode: files.code, shipped: files.shippedVersion,
            path: files.path, browserPID: pid, browserBirthStamp: birthStamp, startedAt: Date())
        automaticReloadPairs.insert(files.shippedVersion + "/" + before)
        let generation = listenerGeneration
        // Reload drops the connection; one request deadline bounds the wait for its reconnect.
        defer {
            if generation == listenerGeneration, extensionReload?.id == id, extensionReload?.phase == "awaiting_reconnect" {
                reconnectDeadline?.cancel()
                reconnectDeadline = Task { [weak self, requestTimeout = connection.requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await self?.reconnectOverdue(id)
                }
            }
        }
        do {
            let response = try await connection.request(action: .reloadExtension, payload: ["reloadId": .string(id)])
            guard generation == listenerGeneration else { return }
            guard case .object(let envelope) = response, case .object(let result)? = envelope["result"],
                  result["reloadId"] == .string(id), result["beforeVersion"] == .string(before),
                  result["status"] == .string("acknowledged") else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            if extensionReload?.id == id, extensionReload?.pending == true {
                extensionReload?.phase = "awaiting_reconnect"
                extensionReload?.reason = "Reload acknowledged; awaiting the extension's accepted reconnect."
                facts.extensionReload = extensionReload?.receipt
                saveConnectionFacts()
            }
        } catch {
            guard generation == listenerGeneration else { return }
            if extensionReload?.id == id {
                if case ChromeControlRuntimeError.outcomeUnknown = error, extensionReload?.pending == true {
                    // Lost acknowledgement/cancellation preserves the dispatched reload until reconnect/termination.
                    extensionReload?.phase = "awaiting_reconnect"
                    extensionReload?.reason = "Reload dispatch is unconfirmed: \(error.localizedDescription). Awaiting an accepted reconnect; no automatic retry."
                    // The pre-dispatch record preserves process and ID across later storage failures.
                    facts.extensionReload = extensionReload?.receipt
                    saveConnectionFacts()
                } else {
                    finishExtensionReload(phase: "failed", reason: "Extension reload failed: \(error.localizedDescription). Call chrome.reload_extension to try explicitly; no automatic retry.")
                }
            }
        }
    }

    private func reconnectOverdue(_ id: String) {
        guard extensionReload?.id == id, extensionReload?.phase == "awaiting_reconnect" else { return }
        finishExtensionReload(phase: "unconfirmed", reason: "The extension did not reconnect after the reload; its effect is unknown. Check chrome.status; no automatic retry.")
    }

    func reconcileReloadBrowser(_ browsers: [pid_t]) {
        if let attempt = extensionReload, attempt.pending,
           !browsers.contains(attempt.browserPID) || ChromeHostIdentity.processBirthStamp(attempt.browserPID) != attempt.browserBirthStamp {
            finishExtensionReload(phase: "failed", reason: "Chrome's browser process ended before the extension's reload could be verified. Call chrome.reload_extension after Chrome reconnects.")
        }
    }

    func reloadIfNeeded() async {
        if extensionReload?.pending != true, let next = channel, let files = extensionFiles, let running = facts.extensionVersion,
           ChromeExtensionFiles.isOlder(running, than: files.shippedVersion) {
            let pair = files.shippedVersion + "/" + running
            if await transportAvailable(), channel === next, automaticReloadPairs.insert(pair).inserted {
                do { try await beginExtensionReload(on: next, source: .automatic) }
                catch { _ = recordReloadPreflightFailure(error, source: .automatic) }
            }
        }
    }
}
