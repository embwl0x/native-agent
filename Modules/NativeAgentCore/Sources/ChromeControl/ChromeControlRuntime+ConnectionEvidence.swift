import Darwin
import AppKit
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
import NativeAgentCore
import TrustCenter
import MacControl
import NativeAgentShared
// Blueprint: | `ChromeControlRuntime+ConnectionEvidence.swift` | `ChromeControlRuntime` connection evidence: historical persisted facts, setup verification, connection diagnosis, capture/relay diagnostics, extension errors and observed browser signature preflight; observations never prove connection or permission |

/// Historical observations only. Never used as connection or permission proof.
struct ChromeConnectionFacts: Codable {
    var extensionReload: JSONValue?
    var extensionReloadAt: Date?
    var relayConnectedAt: Date?
    var extensionVersion: String?
    var extensionCode: String?
    var extensionSeenAt: Date?
    var handshakeAt: Date?
    var handshakeResult: String?
    var handshakeReason: String?
    var extensionError: String?
    var extensionErrorAt: String?
}

final class ChromeBrowserLaunchObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    @MainActor init(onLaunch: @escaping @Sendable (pid_t) -> Void) {
        center = NSWorkspace.shared.notificationCenter
        token = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.google.Chrome", !app.isTerminated else { return }
            onLaunch(app.processIdentifier)
        }
    }

    func cancel() {
        lock.lock()
        let token = self.token
        self.token = nil
        lock.unlock()
        if let token { center.removeObserver(token) }
    }

    deinit { cancel() }
}

extension ChromeControlRuntime {
    public func setupConnectionStatus() async -> (state: ChromeControlConnectionState, enabled: Bool, diagnostics: [String: JSONValue]) {
        let enabled = await transportAvailable()
        let browsers = await Self.runningChromeProcesses()
        readExtensionFiles()
        reconcileReloadBrowser(browsers)
        var diagnostics = connectionDiagnostics(browsers: browsers)
        if let failure = transportAuthorityFailure {
            diagnostics["authority_error"] = .string(failure.localizedDescription)
            diagnostics["chrome_control_enabled"] = failure is ToolFailureError ? .null : .bool(false)
            if let failure = failure as? ToolFailureError, let owner = failure.owner {
                diagnostics["remedy"] = Repair.remedy(owner: owner, nextCall: nil, tap: failure.tap)
            } else { diagnostics["remedy"] = (failure as? ChromeControlRuntimeError)?.remedy }
        }
        return (connectionState, enabled, diagnostics)
    }

    public func verifySetup(since selectedAt: Date) async throws {
        do {
            if try await TurnDeadline.withThrowingDeadline(seconds: 30, {
                try await self.waitForSetup(since: selectedAt)
            }) { return }
        } catch is TurnDeadline.DeadlineExceeded {}
        try Task.checkCancellation()
        let failure = await connectionFailure()
        throw ToolFailureError(failure.message, effects: .occurred, owner: failure.owner,
            nextCall: failure.nextCall, tap: failure.tap)
    }

    private func waitForSetup(since selectedAt: Date) async throws -> Bool {
        let events = connectionStates()
        readExtensionFiles(fresh: true)
        for await _ in events {
            try Task.checkCancellation()
            if readyChannel != nil, let seen = facts.extensionSeenAt, seen >= selectedAt,
               let files = extensionFiles, files.path == ChromeExtensionFolder.visible.path,
               files.diskVersion == files.shippedVersion, facts.extensionVersion == files.shippedVersion { return true }
            if let at = handshakeAt, at >= selectedAt, facts.handshakeResult == "rejected" { break }
            if await transportAvailable() == false { break }
        }
        try Task.checkCancellation()
        return false
    }

    public func recordCaptureError(_ reason: String, tabID: Int64, at: Date = Date()) {
        captureErrors[String(tabID)] = .object([
            "error": .string(ContextSecretContentPolicy.redactedFragment(reason)), "at": Self.dateJSON(at),
            "provenance": .string("raw view · Chrome capture failure; no page news was produced"),
        ])
    }

    /// Inspect local owners; never launch Chrome, connect a host or change Trust.
    private func connectionDiagnostics(browsers: [pid_t]) -> [String: JSONValue] {
        let running = !browsers.isEmpty
        let refusal = relayRefusal()
        let currentRefusal = currentRefusal(refusal.record, browsers: browsers)
        let reload = currentReloadReceipt
        let disconnected = disconnection(chromeRunning: running, refusal: currentRefusal)
        var diagnostics: [String: JSONValue] = [
            "app_listener_up": .bool(listenerDescriptor >= 0),
            "runtime_started_at": Self.dateJSON(runtimeStartedAt),
            "listener_started_at": Self.dateJSON(listenerStartedAt),
            "app_listener_error": listenerFailure.map(JSONValue.string) ?? .null,
            "chrome_running": .bool(running),
            "relay_last_connected_at": Self.dateJSON(facts.relayConnectedAt),
            "extension_version_last_seen": facts.extensionVersion.map(JSONValue.string) ?? .null,
            "extension_running_version": channel != nil ? facts.extensionVersion.map(JSONValue.string) ?? .null : .null,
            "extension_shipped_version": extensionFiles.map { .string($0.shippedVersion) } ?? .null,
            "extension_files_version": extensionFiles.map { .string($0.diskVersion) } ?? .null,
            "extension_running_code": channel != nil ? facts.extensionCode.map(JSONValue.string) ?? .null : .null,
            "extension_files_code": extensionFiles?.code.map(JSONValue.string) ?? .null,
            "extension_path": extensionFiles.map { .string($0.path) } ?? .null,
            "extension_version_check_error": extensionFilesError.map(JSONValue.string) ?? .null,
            "extension_reload": reload,
            "extension_reload_last_seen": facts.extensionReload ?? .null,
            "extension_version_note": extensionVersionNote.map(JSONValue.string) ?? .null,
            "extension_last_seen_at": Self.dateJSON(facts.extensionSeenAt),
            "extension_connected_since_runtime_start": .bool(extensionConnectedThisRun),
            "relay_connected": .bool(channel != nil || connectingChannel != nil),
            "handshake_result": .string(channel != nil ? (extensionHasTabProtocol ? "accepted" : "extension_upgrade_required") : connectingChannel != nil ? "extension_attach_pending" : "not_connected"),
            "handshake_at": channel != nil || connectingChannel != nil ? Self.dateJSON(handshakeAt) : .null,
            "handshake_reason": .null,
            "last_handshake_result": facts.handshakeResult.map(JSONValue.string) ?? .null,
            "last_handshake_at": Self.dateJSON(facts.handshakeAt),
            "last_handshake_reason": facts.handshakeReason.map { .string("last seen handshake rejection: " + $0) } ?? .null,
            "diagnostic_storage_error": factsStorageError.map(JSONValue.string) ?? .null,
            "relay_refusal_storage_error": refusal.error.map(JSONValue.string) ?? .null,
            "relay_refusal_current": .bool(currentRefusal != nil),
            "relay_refusal_check": currentRefusal.map { .string($0.check) } ?? .null,
            "relay_refusal_os_status": currentRefusal?.osStatus.map { .int(Int64($0)) } ?? .null,
            "relay_refusal_reason": currentRefusal.map { .string($0.reason) } ?? .null,
            "last_relay_refusal_reason": refusal.record.map { .string("last seen relay refusal: " + $0.reason) } ?? .null,
            "last_relay_refusal_at": Self.dateJSON(refusal.record?.recordedAt),
            "last_extension_error": facts.extensionError.map { .string("last extension error: " + $0) } ?? .null,
            "last_extension_error_at": facts.extensionErrorAt.map(JSONValue.string) ?? .null,
            "down_side": readyChannel != nil ? .null : .string(disconnected.side),
            "connection_note": readyChannel != nil ? .string("The app accepted the relay and confirmed the extension's protocol greeting.")
                : .string(disconnected.reason),
            "provenance": .string("raw view · Chrome native messaging transport, registered unpacked and bundled manifests, Chrome profile preferences, app listener, macOS running-application inventory and running-code signature validation; last-seen facts are historical observations."),
        ]
        if reload != .null, reload == facts.extensionReload {
            diagnostics.removeValue(forKey: "extension_reload_last_seen")
            diagnostics["extension_reload_is_current"] = .bool(true)
        }
        return diagnostics
    }

    private var extensionVersionNote: String? {
        guard let files = extensionFiles, let running = facts.extensionVersion, channel != nil else { return extensionFilesError }
        return "Chrome is running extension \(running) from \(files.path); NativeAgent ships \(files.shippedVersion)"
    }

    @MainActor static func runningChromeProcesses() -> [pid_t] {
        // Exact Chrome bundle identity from macOS, never inferred from a socket.
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.google.Chrome" && !$0.isTerminated }.map(\.processIdentifier)
    }

    private func relayRefusal() -> (record: ChromeRelayRefusal?, error: String?) {
        do { return (try ChromeRelayRefusal.read(socketPath: socketPath), nil) }
        catch { return (nil, "Chrome relay refusal could not be read: \(error.localizedDescription)") }
    }

    private func currentRefusal(_ record: ChromeRelayRefusal?, browsers: [pid_t]) -> ChromeRelayRefusal? {
        guard channel == nil, connectingChannel == nil else { return nil }
        let candidates = ([record].compactMap { $0 } + Array(signatureFailures.values)).filter {
            browsers.contains($0.browserPID) && $0.browserBirthStamp != nil
                && ChromeHostIdentity.processBirthStamp($0.browserPID) == $0.browserBirthStamp
                && $0.recordedAt > (facts.relayConnectedAt ?? .distantPast)
                && ($0.scope == .browser || $0.recordedAt >= (listenerStartedAt ?? runtimeStartedAt))
        }
        return candidates.max { $0.recordedAt < $1.recordedAt }
    }

    /// Register before inventory to close the startup gap; workspace events own later checks.
    public func observeBrowserLaunches() async {
        guard !runtimeStopped, browserObservationID == nil else { return }
        let policy = policyGeneration
        guard await transportAvailable(), !runtimeStopped, policy == policyGeneration,
              browserObservationID == nil else { return }
        let id = UUID()
        browserObservationID = id
        let observer = await ChromeBrowserLaunchObserver { [weak self] pid in
            Task { await self?.checkBrowserSignature(pid, observation: id) }
        }
        guard !runtimeStopped, browserObservationID == id else { observer.cancel(); return }
        browserLaunchObserver = observer
        let processes = await Self.runningChromeProcesses()
        guard !runtimeStopped, browserObservationID == id else { return }
        for pid in processes { await checkBrowserSignature(pid, observation: id) }
    }

    private func checkBrowserSignature(_ pid: pid_t, observation: UUID) async {
        // Recheck live inventory before treating a late launch event's Security lookup as a Chrome fault.
        guard browserObservationID == observation,
              await Self.runningChromeProcesses().contains(pid),
              browserObservationID == observation,
              let birth = ChromeHostIdentity.processBirthStamp(pid) else { return }
        do {
            _ = try ChromeHostIdentity.checkedBrowserSigningIdentifier(forProcess: pid)
            signatureFailures.removeValue(forKey: pid)
        } catch let failure as ChromeHostIdentity.SigningFailure {
            guard ChromeHostIdentity.processBirthStamp(pid) == birth,
                  await Self.runningChromeProcesses().contains(pid),
                  browserObservationID == observation else { return }
            let refusal = ChromeRelayRefusal(scope: .browser, check: failure.check, osStatus: failure.status,
                                            reason: failure.localizedDescription, browserPID: pid)
            signatureFailures = signatureFailures.filter { ChromeHostIdentity.processBirthStamp($0.key) == $0.value.browserBirthStamp }
            signatureFailures[pid] = refusal
            guard !signatureFailureNoted else { return }
            signatureFailureNoted = true
            let message = "Chrome's running-browser signature check failed: \(failure.localizedDescription) The relay will refuse Chrome until this check is fixed. raw view · macOS running Chrome process and ChromeHostIdentity signature validation; no page was read."
            let id = "chrome-browser-signature-\(ProcessInfo.processInfo.operatingSystemVersionString)-\(failure.check)-\(failure.status)"
            do { try await signatureFailureNote(id, message) }
            catch {
                guard browserObservationID == observation else { return }
                nativeLog("[NativeAgent] Chrome signature failure note could not be saved: %@; %@", error.localizedDescription, message)
            }
        } catch { nativeLog("[NativeAgent] Chrome browser signature check failed: %@", error.localizedDescription) }
    }

    static func dateJSON(_ date: Date?) -> JSONValue {
        date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
    }

    private func disconnection(chromeRunning: Bool, refusal: ChromeRelayRefusal?) -> (side: String, reason: String) {
        let result: (side: String, reason: String)
        if channel != nil, !extensionHasTabProtocol {
            result = ("extension_upgrade", extensionReload?.reason ?? extensionFilesError ?? "The connected Chrome extension needs the shipped tab protocol before Chrome control is ready.")
        } else if listenerDescriptor < 0 {
            result = ("app_listener", "NativeAgent's Chrome listener is not running. " + (listenerFailure ?? "No app-side listener is available."))
        } else if !chromeRunning { result = ("chrome", "Chrome is not running.") }
        else if connectingChannel != nil { result = ("extension_attach", "The app accepted the relay; the extension's attach greeting is still pending.") }
        else if let refusal { result = ("relay_refusal", "Chrome relay refused at \(refusal.check): \(refusal.reason)") }
        else if extensionFiles == nil {
            result = ("extension_setup", "The NativeAgent extension is not set up in Chrome. \(extensionFilesError ?? "") Call chrome.setup (Set up Chrome) to load it.")
        } else { result = ("extension_link", "Chrome is running, but NativeAgent has no accepted extension connection. The app listener is up.") }
        return (result.side, channel != nil && extensionHasTabProtocol
            ? "The Chrome extension reconnected while this request was being refused. Nothing was sent." : result.reason)
    }

    func connectionFailure() async -> ToolFailureError {
        let browsers = await Self.runningChromeProcesses()
        let refusal = currentRefusal(relayRefusal().record, browsers: browsers)
        readExtensionFiles()
        let disconnected = disconnection(chromeRunning: !browsers.isEmpty, refusal: refusal)
        if readyChannel != nil || connectingChannel != nil {
            return ToolFailureError(disconnected.reason
                + " Read chrome.status, then do what you meant again once connected.",
                effects: .none, owner: "Chrome native messaging / extension attach",
                nextCall: ToolFailureError.call("app", ["action": .string("chrome.status")]))
        }
        return ToolFailureError(disconnected.reason
            + " Call chrome.setup, then use mac.look and mac.act on Chrome's extensions page to load or reload NativeAgent. Only an accepted connection proves repair.",
            effects: .none, owner: "Chrome native messaging / " + disconnected.side,
            nextCall: ToolFailureError.call("app", ["action": .string("chrome.setup")]))
    }

    func recordHandshake(_ result: String, reason: String? = nil) {
        handshakeAt = Date()
        facts.handshakeAt = handshakeAt
        facts.handshakeResult = result
        facts.handshakeReason = reason
        saveConnectionFacts()
        publishConnectionState()
    }

    func saveConnectionFacts() {
        do {
            let data = try JSONEncoder().encode(facts)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: URL(fileURLWithPath: socketPath + ".connection-facts.json"))
            factsStorageError = nil
        } catch {
            let message = "Chrome connection facts could not be saved: \(error.localizedDescription)"
            factsStorageError = message
            nativeLog("[NativeAgent] %@", message)
        }
    }
}
