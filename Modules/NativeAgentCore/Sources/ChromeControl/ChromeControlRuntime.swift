import Darwin
import Foundation
import NativeAgentShared
import NativeAgentChromeRelayCore
import PersistenceCore
import TrustCenter
import MacControl
import NativeAgentCore
// Blueprint: | `ChromeControlRuntime.swift` | `ChromeControlRuntime`: one actor and stored state; authenticated listener/relay attach, authority, channel dispatch and connection streams; listener identities fence late work; transport stop retires passive observations, reconciliation rearms them and terminal stop closes admission/streams; only explicit tab.close removes tabs, shutdown/reload leave them open |

// No origin is a transport-level caller, never permission for a Chrome effect.
public enum ChromeControlInvocationContext {
    @TaskLocal public static var origin: SecurityOriginContext? = nil
}

public enum ChromeControlRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case disconnected
    case connectionUnavailable(String)
    case handshakeRejected(String)
    case invalidResponse
    case requestTimedOut
    case extensionRejected(code: String, message: String)
    case outcomeUnknown(action: String, reason: String)
    case socketFailure(Int32)
    case socketPathTooLong
    case relayUnavailable
    case unsafeSocketPath
    case conversationContext(String)

    public var remedy: JSONValue? {
        guard case .disabled = self else { return nil }
        return Repair.why(owner: "trust/policy.json / chromeControlPolicy.enabled",
                          tap: "NativeAgent > Trust > Mac > Chrome control")
    }

    /// Transport-owned evidence. Dispatched mutations use outcomeUnknown;
    /// a missing connection cannot have read a page or emitted an action.
    public var failureEffects: ToolFailureError.Effects? {
        switch self {
        case .outcomeUnknown: .unknown
        case .extensionRejected(let code, _) where ["invalid_url", "url_scheme_not_allowed", "navigation_url_blocked"].contains(code): .some(.none)
        case .disabled, .disconnected,
             .connectionUnavailable, .handshakeRejected,
             .socketPathTooLong, .relayUnavailable, .unsafeSocketPath: .some(.none)
        case .invalidResponse, .requestTimedOut, .extensionRejected, .socketFailure, .conversationContext: nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Chrome control is off in Trust Center."
        case .disconnected: return "The Chrome extension's connection to NativeAgent ended. raw view · Chrome native messaging transport; no page was read."
        case .connectionUnavailable(let reason): return reason + " raw view · Chrome native messaging transport; no page was read."
        case .handshakeRejected(let reason): return "Chrome handshake rejected: \(reason)"
        case .invalidResponse: return "Chrome returned an invalid control response."
        case .requestTimedOut: return "Chrome did not answer before the control deadline."
        case .extensionRejected(let code, let message):
            // Name the next call when the refusal has one.
            let next: String = switch code {
            case "tab_not_owned": " browser.chrome_navigate{url} opens a new tab in the NativeAgent group."
            case "tab_strip_locked": " Ask the person to finish the drag or restart Chrome; do not repeat the call."
            case "tab_not_painted": " The tab was not activated; mac.look {app:\"Google Chrome\", pixels:true} shows the window as it is."
            case "snapshot_stale", "node_stale": " The page changed since that read; nothing was done. Read the page again and act on its new rows."
            default: ""
            }
            return "Chrome refused the control request (\(code)): \(message)" + next
        case .outcomeUnknown(let action, let reason):
            return "Chrome did not confirm \(action) after dispatch. \(reason) The action may have completed; do not automatically repeat it. Observe the page before retrying."
        case .socketFailure(let code): return "Chrome control socket failed (errno \(code))."
        case .socketPathTooLong: return "Chrome control socket path is too long."
        case .relayUnavailable: return "The bundled NativeAgent Chrome relay is unavailable."
        case .unsafeSocketPath: return "Chrome control refused to replace a non-socket filesystem entry."
        case .conversationContext(let message): return message

        }
    }
}

public enum ChromeControlEffect: String, Sendable, CaseIterable {
    // Existing protocol greeting, used by the transport only; no new app action.
    case attach
    case reloadExtension = "extension.reload"
    case closeTab = "tab.close"
    case navigate
    case snapshot = "page.snapshot.read"
    case look = "page.look"
    case click = "page.element.click"
    case fill = "page.element.fill"
    case type = "page.element.type"
    case select = "page.element.select"
    case keypress = "page.element.keypress"
    case setChecked = "page.element.set_checked"
    case doubleClick = "page.element.double_click"
    case drag = "page.element.drag"
    case wait = "page.wait"
    case scroll = "page.scroll"
    case media = "page.media"

    var requiresEffectTimeAuthorization: Bool { self != .attach }

    var mayChangeExternalState: Bool {
        switch self {
        case .attach, .snapshot, .look, .wait: false
        default: true
        }
    }

    var requiresDriver: Bool { mayChangeExternalState && self != .reloadExtension }

}

public enum ChromeControlConnectionState: Sendable, Equatable {
    case extensionNotLoaded, disconnected, connected

    public func status(enabled: Bool) -> String {
        guard enabled else { return "Chrome control is off" }
        switch self {
        case .extensionNotLoaded: return "On, but no Chrome extension connection has been confirmed yet — press Set up Chrome"
        case .disconnected: return "On, previously connected; Chrome is not connected right now"
        case .connected: return "Connected"
        }
    }
}

public actor ChromeControlRuntime {
    public typealias Authority = @Sendable () async throws -> Void

    private let authority: Authority
    var transportAuthorityFailure: (any Error)?
    let socketPath: String
    private let manageNativeHostRegistration: Bool
    var listenerDescriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    var channel: ChromeControlChannel?
    var connectingChannel: ChromeControlChannel?
    var extensionCanReload = false
    var extensionHasTabProtocol = false
    var readyChannel: ChromeControlChannel? { extensionHasTabProtocol ? channel : nil }
    private var extensionHasConnected: Bool
    var extensionConnectedThisRun = false
    let runtimeStartedAt = Date()
    var listenerStartedAt: Date?
    var listenerFailure: String?
    var facts = ChromeConnectionFacts()
    var factsStorageError: String?
    var handshakeAt: Date?
    let signatureFailureNote: @Sendable (String, String) async throws -> Void
    var browserLaunchObserver: ChromeBrowserLaunchObserver?
    var browserObservationID: UUID?
    var runtimeStopped = false
    var signatureFailureNoted = false
    var signatureFailures: [pid_t: ChromeRelayRefusal] = [:]
    var captureErrors: [String: JSONValue] = [:]
    let conversationTabsURL: URL
    var rememberedTabIDs: [String: Int64] = [:]
    var conversationTabsStorageError: String?
    var groupTabs: [Int64: ChromeConversationTab] = [:]
    // Diagnostic evidence for this app run, across relay/extension reconnects.
    var releasedTabs: [JSONValue] = []
    var busyConversations: Set<String> = []
    private var connectionObservers: [UUID: AsyncStream<ChromeControlConnectionState>.Continuation] = [:]
    var extensionFileReader = ChromeExtensionFiles()
    var extensionFiles: (path: String, diskVersion: String, shippedVersion: String, code: String?)?
    var extensionFilesError: String?
    var extensionFileEvents: FileChangeEvents?
    var extensionFileTask: Task<Void, Never>?
    var extensionFilePaths = Set<URL>()
    var extensionFileAccess: [URL: Bool] = [:]
    var connectedBrowserPID: pid_t?
    var automaticReloadPairs: Set<String> = []
    var extensionReload: ExtensionReloadAttempt?
    var reloadPreflightFailure: JSONValue?
    var reloadWaiters: [UUID: CheckedContinuation<JSONValue, Error>] = [:]
    var reconnectDeadline: Task<Void, Never>?

    var connectionState: ChromeControlConnectionState {
        readyChannel != nil ? .connected : (extensionHasConnected ? .disconnected : .extensionNotLoaded)
    }

    public func connectionStates() -> AsyncStream<ChromeControlConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChromeControlConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(connectionState)
        guard !runtimeStopped else { continuation.finish(); return stream }
        connectionObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeConnectionObserver(id) }
        }
        return stream
    }

    private func removeConnectionObserver(_ id: UUID) {
        connectionObservers.removeValue(forKey: id)
    }

    func publishConnectionState() {
        let state = connectionState
        BrowserConnectionMirror.set(connected: state == .connected)
        for observer in connectionObservers.values { observer.yield(state) }
    }

    private func connectionEnded(installation: UInt64) {
        guard installation == installationGeneration else { return }
        channel = nil
        connectingChannel = nil
        publishConnectionState()
    }
    /// Only the listener that accepted a descriptor may install its channel.
    var listenerGeneration: UInt64 = 0
    private var installationGeneration: UInt64 = 0
    var policyGeneration: UInt64 = 0
    /// Teardown reaches every accepted descriptor still awaiting authentication.
    private var handshakingDescriptors: [Int32: UInt64] = [:]
    /// Teardown removes only the socket and token files this listener created.
    private var socketIdentity: ChromeHostIdentity.FileIdentity?
    private var tokenIdentity: ChromeHostIdentity.FileIdentity?

    deinit {
        browserLaunchObserver?.cancel()
        reconnectDeadline?.cancel()
        extensionFileTask?.cancel()
        extensionFileEvents?.cancel()
    }

    public init(
        socketPath: String = ChromeControlRuntime.defaultSocketPath(),
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        // NativeAgentSecondaryInstall leaves the Mac's native-host registration with the primary install.
        manageNativeHostRegistration: Bool = !UserDefaults.standard.bool(forKey: "NativeAgentSecondaryInstall"),
        signatureFailureNote: @escaping @Sendable (String, String) async throws -> Void = { _, message in nativeLog("[NativeAgent] %@", message) },
        authority: @escaping Authority = {
            try await SwiftNativeTrustCenter(dataRoot: PersistenceCore.defaultDataRoot())
                .authorizeChromeControlEffect(origin: ChromeControlInvocationContext.origin)
        }
    ) {
        self.socketPath = socketPath
        self.conversationTabsURL = dataRoot.appendingPathComponent("chrome/conversation-tabs.json")
        self.manageNativeHostRegistration = manageNativeHostRegistration
        self.authority = authority
        self.signatureFailureNote = signatureFailureNote
        if FileManager.default.fileExists(atPath: conversationTabsURL.path) {
            do {
                let saved = try JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: conversationTabsURL))
                rememberedTabIDs = saved.filter { NativeAgentChatSessionID.isSafePathComponent($0.key) && $0.value >= 0 }
            } catch { conversationTabsStorageError = "Chrome conversation tab IDs could not be read: \(error.localizedDescription)" }
        }
        // Connection history survives restarts and permission changes; manifests/groups cannot prove it.
        self.extensionHasConnected = (try? String(contentsOfFile: socketPath + ".extension-connected", encoding: .utf8)) == "connected\n"
        let factsURL = URL(fileURLWithPath: socketPath + ".connection-facts.json")
        if FileManager.default.fileExists(atPath: factsURL.path) {
            do { self.facts = try JSONDecoder().decode(ChromeConnectionFacts.self, from: Data(contentsOf: factsURL)) }
            catch { self.factsStorageError = "Chrome connection facts could not be read: \(error.localizedDescription)" }
        }
        let seenBefore = self.facts.extensionSeenAt != nil
        self.extensionHasConnected = self.extensionHasConnected || seenBefore
    }

    func authorizeEffect() async throws {
        do { try await authority() }
        catch ChromeControlAuthorityError.disabled {
            throw ChromeControlRuntimeError.disabled
        } catch {
            throw ToolFailureError("Chrome control authority is unavailable: " + error.localizedDescription,
                effects: .none, owner: "trust/policy.json",
                tap: "NativeAgent > Trust > Advanced > Backups > a verified Trust policy backup > Restore > Restore backup")
        }
    }

    /// Listener administration is local; every effect separately authorizes its calling turn.
    func transportAvailable() async -> Bool {
        guard !runtimeStopped else {
            transportAuthorityFailure = ChromeControlRuntimeError.disconnected
            return false
        }
        let origin = SecurityOriginContext(surface: "chat", source: "chrome_transport", isRemote: false)
        do {
            try await ChromeControlInvocationContext.$origin.withValue(origin) { try await authorizeEffect() }
            guard !runtimeStopped else {
                transportAuthorityFailure = ChromeControlRuntimeError.disconnected
                return false
            }
            transportAuthorityFailure = nil
            return true
        } catch {
            transportAuthorityFailure = error
            return false
        }
    }

    public func reconcilePolicy() async {
        guard !runtimeStopped else { return }
        policyGeneration &+= 1
        let generation = policyGeneration
        let enabled = await transportAvailable()
        guard generation == policyGeneration else { return }
        guard enabled else {
            await stopLocked()
            guard generation == policyGeneration else { return }
            if let failure = transportAuthorityFailure as? ToolFailureError {
                OrganPulse.record("chrome_relay", .skipped, note: failure.message)
            } else {
                if manageNativeHostRegistration { try? ChromeNativeHostRegistration.uninstall() }
                OrganPulse.recordOff("chrome_relay", because: "Chrome control is turned off")
            }
            return
        }
        do {
            try startListenerIfNeeded()
            if manageNativeHostRegistration { try ChromeNativeHostRegistration.install() }
            readExtensionFiles()
            await observeBrowserLaunches()
            guard !runtimeStopped, generation == policyGeneration else { return }
            OrganPulse.record("chrome_relay", .worked, note: "listening")
        } catch {
            listenerFailure = error.localizedDescription
            await stopLocked()
        }
    }

    public func existingPageAddress(host: String, tabID: Int64? = nil) async throws -> [String: JSONValue] {
        guard await transportAvailable() else { throw transportAuthorityFailure! }
        guard let channel = readyChannel else { throw await connectionFailure() }
        return try await channel.existingPageAddress(host: host, tabID: tabID)
    }

    public func pageChanges(host: String, tabID: Int64) async throws -> AsyncThrowingStream<JSONValue, Error> {
        guard await transportAvailable() else { throw transportAuthorityFailure! }
        guard let channel = readyChannel else { throw await connectionFailure() }
        return try await channel.pageChanges(host: host, tabID: tabID)
    }

    func performOnChannel(
        _ effect: ChromeControlEffect, payload: [String: JSONValue]
    ) async throws -> (response: JSONValue, channel: ChromeControlChannel) {
        if MacDriverContext.binding == nil {
            let binding = await MacAttentionSessionStore.shared.bindDriver()
            return try await withTaskCancellationHandler {
                try await MacDriverContext.$binding.withValue(binding) {
                    try await performOnChannel(effect, payload: payload)
                }
            } onCancel: { binding.cancel() }
        }
        if effect.requiresEffectTimeAuthorization {
            try await authorizeEffect()
        }
        if channel != nil, readyChannel == nil { throw await connectionFailure() }
        let previous = readyChannel
        do {
            guard let previous else { throw ChromeControlRuntimeError.disconnected }
            return (try await previous.request(action: effect, payload: payload), previous)
        } catch ChromeControlRuntimeError.disconnected {
            // Chrome's reconnect alarm owns host launch; dispatched mutations stay outcomeUnknown.
            try Task.checkCancellation()
            try await authorizeEffect()
            do {
                try startListenerIfNeeded()
                if manageNativeHostRegistration { try ChromeNativeHostRegistration.install() }
            } catch {
                listenerFailure = error.localizedDescription
                await stopLocked()
                throw await connectionFailure()
            }
            let next: ChromeControlChannel
            if let channel = readyChannel, channel !== previous {
                next = channel
            } else {
                throw await connectionFailure()
            }
            try Task.checkCancellation()
            try await authorizeEffect()
            return (try await next.request(action: effect, payload: payload), next)
        }
    }

    public func stop() async {
        guard !runtimeStopped else { return }
        runtimeStopped = true
        policyGeneration &+= 1
        let observers = connectionObservers.values
        connectionObservers.removeAll()
        for observer in observers { observer.yield(.disconnected); observer.finish() }
        await stopLocked()
    }

    /// Registered before the handshake so `stopLocked` can reach the socket
    /// while it is still being read. False means this listener is already gone.
    private func beginHandshake(_ descriptor: Int32, generation: UInt64) -> Bool {
        guard generation == listenerGeneration else { return false }
        handshakingDescriptors[descriptor] = generation
        return true
    }

    private func listenerEnded(generation: UInt64, error: Int32) async {
        guard generation == listenerGeneration else { return }
        listenerFailure = "NativeAgent's Chrome listener stopped accepting connections (errno \(error))."
        await stopLocked()
    }

    private func finishHandshake(_ descriptor: Int32, generation: UInt64, rejection: String?) async {
        guard handshakingDescriptors[descriptor] == generation else { return }
        handshakingDescriptors.removeValue(forKey: descriptor)
        guard generation == listenerGeneration else {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            return
        }
        if let rejection {
            recordHandshake("rejected", reason: rejection)
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            return
        }
        facts.relayConnectedAt = Date()
        recordHandshake("relay_accepted")
        await installAcceptedDescriptor(descriptor, generation: generation)
    }

    private func startListenerIfNeeded() throws {
        // A stopped runtime never recreates its socket, credential or registration.
        guard !runtimeStopped else { throw ChromeControlRuntimeError.disconnected }
        guard listenerDescriptor < 0 else { return }
        // Establish identity before publishing a listener or its credential,
        // including secondary installs that do not administer registration.
        let expectedPeers = try expectedPeerExecutablePaths()
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        guard Array(socketPath.utf8CString).count <= MemoryLayout<sockaddr_un>.size - 2 else {
            throw ChromeControlRuntimeError.socketPathTooLong
        }
        try unlinkSocketIfPresent(path: socketPath)
        // Publish the secret before the socket can accept a connection.
        let token = ChromeControlHandshake.mintToken()
        try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(token.utf8),
            to: URL(fileURLWithPath: ChromeHostIdentity.tokenPath(forSocketPath: socketPath)))
        // Claimed the moment it is written, so a failure below still leaves
        // teardown able to remove the file this call created.
        tokenIdentity = ChromeHostIdentity.FileIdentity(path: ChromeHostIdentity.tokenPath(forSocketPath: socketPath))
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ChromeControlRuntimeError.socketFailure(errno) }
        do {
            try bindUnixSocket(descriptor: descriptor, path: socketPath)
            guard Darwin.listen(descriptor, 1) == 0 else {
                throw ChromeControlRuntimeError.socketFailure(errno)
            }
            chmod(socketPath, 0o600)
        } catch {
            Darwin.close(descriptor)
            try? unlinkSocketIfPresent(path: socketPath)
            throw error
        }
        listenerDescriptor = descriptor
        listenerStartedAt = Date()
        listenerFailure = nil
        socketIdentity = ChromeHostIdentity.FileIdentity(path: socketPath)
        listenerGeneration &+= 1
        let generation = listenerGeneration
        let acceptQueue = DispatchQueue(label: "com.nativeagent.chromecontrol.accept", qos: .utility)
        acceptTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let (accepted, acceptError) = await offPool(acceptQueue) {
                    let accepted = Darwin.accept(descriptor, nil, nil)
                    return (accepted, accepted < 0 ? errno : 0)
                }
                if accepted < 0 {
                    if acceptError == EINTR { continue }
                    await self?.listenerEnded(generation: generation, error: acceptError)
                    break
                }
                guard let self else {
                    _ = Darwin.shutdown(accepted, SHUT_RDWR)
                    Darwin.close(accepted)
                    break
                }
                // Register the descriptor before authentication so stop can reach it.
                guard await self.beginHandshake(accepted, generation: generation) else {
                    _ = Darwin.shutdown(accepted, SHUT_RDWR)
                    Darwin.close(accepted)
                    continue
                }
                // Authenticate off-pool before an unproven peer can affect the live channel.
                let rejection = await offPool(acceptQueue) { () -> String? in
                    do {
                        try ChromeControlHandshake.validateConnection(
                            descriptor: accepted, expecting: expectedPeers, token: token
                        )
                        // Ack before installation; keep registration so stop can interrupt without descriptor reuse.
                        guard ChromeControlHandshake.sendHelloAck(descriptor: accepted, generation: generation) else {
                            return "Chrome handshake rejected: the app could not acknowledge the relay greeting."
                        }
                        return nil
                    } catch { return error.localizedDescription }
                }
                await self.finishHandshake(accepted, generation: generation, rejection: rejection)
            }
        }
    }

    /// Connection identity belongs to the bundle, independently of which
    /// install administers Chrome's native-host registration.
    private func expectedPeerExecutablePaths() throws -> Set<String> {
        let relay = ChromeNativeHostRegistration.bundledRelayURL()
        guard FileManager.default.isExecutableFile(atPath: relay.path) else {
            throw ChromeControlRuntimeError.handshakeRejected("the bundled Chrome relay executable is unavailable.")
        }
        return [relay.resolvingSymlinksInPath().path]
    }

    private func installAcceptedDescriptor(_ descriptor: Int32, generation: UInt64) async {
        guard generation == listenerGeneration,
              await transportAvailable(),
              listenerDescriptor >= 0 || !manageNativeHostRegistration,
              generation == listenerGeneration else {
            Darwin.close(descriptor)
            return
        }
        installationGeneration &+= 1
        let installation = installationGeneration
        let browserPID = ChromeControlHandshake.peerProcessID(descriptor: descriptor)
            .flatMap { ChromeHostIdentity.parentProcessID(of: $0) }
        let liveBrowserPID = browserPID.flatMap { $0 > 1 && ChromeHostIdentity.isBrowserProcess($0) ? $0 : nil }
        // Retire the old channel before shutdown suspends so late replies cannot restore bookmarks.
        let previous = channel
        let previousConnecting = connectingChannel
        channel = nil
        connectingChannel = nil
        publishConnectionState()
        if let previous { await previous.shutdown() }
        if let previousConnecting { await previousConnecting.shutdown() }
        // Stop or a newer connection during shutdown retires this installation.
        guard generation == listenerGeneration,
              installation == installationGeneration else {
            Darwin.close(descriptor)
            return
        }
        let next = ChromeControlChannel(descriptor: descriptor, previousTabs: groupTabs, onReloadFailure: { [weak self] id, reason in
            Task { await self?.extensionReloadFailed(id: id, reason: reason) }
        }, onCaptureFailure: { [weak self] tabID, reason, at in
            Task { await self?.recordCaptureError(reason, tabID: tabID, at: at) }
        }, onTabReleased: { [weak self] tab in
            await self?.recordReleasedTab(tab)
        }) { [weak self] in
            Task { await self?.connectionEnded(installation: installation) }
        }
        connectingChannel = next
        await next.start()
        do {
            // Only Chrome's attach greeting proves extension version and readiness.
            let response = try await next.request(action: .attach, payload: [:])
            guard case .object(let envelope) = response, case .object(let result)? = envelope["result"],
                  result["hostId"] == .string("com.nativeagent.chrome"), result["protocolVersion"] == .int(1),
                  case .string(let version)? = result["extensionVersion"], !version.isEmpty,
                  version.utf8.count <= 128, ChromeExtensionFiles.components(version) != nil else {
                throw ChromeControlRuntimeError.handshakeRejected("the extension returned an invalid attach greeting.")
            }
            let tabs = await next.tabs()
            guard installation == installationGeneration, generation == listenerGeneration,
                  connectingChannel === next, await transportAvailable(),
                  installation == installationGeneration, generation == listenerGeneration,
                  connectingChannel === next else {
                if connectingChannel === next { connectingChannel = nil }
                await next.shutdown()
                return
            }
            // A greeting without tab capabilities proves transport, not tab readiness.
            let capabilities: [JSONValue] = if case .array(let list)? = result["capabilities"] { list } else { [] }
            extensionCanReload = capabilities.contains(.string("extension.reload"))
            extensionHasTabProtocol = if case .array? = result["tabs"] { capabilities.contains(.string("tab.close")) } else { false }
            groupTabs = tabs
            if case .object(let error)? = result["lastExtensionError"],
               case .string(let message)? = error["message"], !message.isEmpty, message.utf8.count <= 4096 {
                facts.extensionError = message
                if case .string(let at)? = error["at"] { facts.extensionErrorAt = at }
            }
            facts.extensionVersion = version
            // The extension's loaded-code digest; nil when unreported.
            facts.extensionCode = if case .string(let code)? = result["codeDigest"], code.count == 16,
                                     code.allSatisfy(\.isHexDigit) { code } else { nil }
            facts.extensionSeenAt = Date()
            recordHandshake("accepted")
        } catch {
            if installation == installationGeneration, generation == listenerGeneration {
                let reason = (error as? ChromeControlRuntimeError).map { failure in
                    if case .handshakeRejected = failure { return failure.localizedDescription }
                    return "Chrome handshake rejected: extension attach failed: \(failure.localizedDescription)"
                } ?? "Chrome handshake rejected: extension attach failed: \(error.localizedDescription)"
                recordHandshake("rejected", reason: reason)
                connectingChannel = nil

            }
            await next.shutdown()
            return
        }
        connectingChannel = nil
        channel = next
        connectedBrowserPID = liveBrowserPID
        extensionHasConnected = true
        extensionConnectedThisRun = true
        try? "connected\n".write(toFile: socketPath + ".extension-connected", atomically: true, encoding: .utf8)
        publishConnectionState()
        readExtensionFiles()
        if let attempt = extensionReload, attempt.pending, let version = facts.extensionVersion {
            let running = facts.extensionCode, folder = extensionFiles?.code ?? attempt.diskCode
            if liveBrowserPID != attempt.browserPID || liveBrowserPID.flatMap({ ChromeHostIdentity.processBirthStamp($0) }) != attempt.browserBirthStamp {
                finishExtensionReload(phase: "failed", after: version, folderCode: folder, reason: "The reconnect came from a different Chrome process.")
            } else if ChromeExtensionFiles.isOlder(version, than: attempt.shipped) {
                finishExtensionReload(phase: "stale", after: version, afterCode: running, folderCode: folder,
                    reason: "reloaded, still \(version), extension files not updated (\(attempt.path))")
            } else if let running, let folder, running != folder {
                finishExtensionReload(phase: "stale", after: version, afterCode: running, folderCode: folder,
                    reason: "reloaded, still \(version), but the running code (\(running)) is not the folder's (\(folder)) at \(attempt.path)")
            } else {
                let evidence = if let running, folder != nil { "; running and folder code both report \(running) (before: \(attempt.beforeCode ?? "none reported"))" }
                    else { "; a running or folder digest is unavailable, so only the version is proven" }
                finishExtensionReload(phase: "succeeded", after: version, afterCode: running, folderCode: folder,
                    reason: "Reload verified by the extension's accepted reconnect and running version" + evidence + ".")
            }
        }
        await reloadIfNeeded()
    }

    private func stopLocked() async {
        // Transport stop retires passive resources; reconciliation rearms them, public stop closes admission.
        browserObservationID = nil
        browserLaunchObserver?.cancel()
        browserLaunchObserver = nil
        extensionFileTask?.cancel()
        extensionFileTask = nil
        extensionFileEvents?.cancel()
        extensionFileEvents = nil
        reconnectDeadline?.cancel()
        reconnectDeadline = nil
        let waiters = reloadWaiters.values
        reloadWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: ChromeControlRuntimeError.disconnected) }
        if extensionReload?.pending == true {
            finishExtensionReload(phase: "unconfirmed", reason: "Chrome transport stopped before the extension reload could be verified; its effect is unknown. Check chrome.status; no automatic retry.")
        }
        let existing = channel
        let existingConnecting = connectingChannel
        channel = nil
        connectingChannel = nil
        publishConnectionState()
        acceptTask?.cancel()
        acceptTask = nil
        // Retire listener admission before a pending handshake can install.
        listenerGeneration &+= 1
        // Shutdown interrupts authentication; its accept task owns the close.
        for descriptor in handshakingDescriptors.keys {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        if listenerDescriptor >= 0 {
            _ = Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
            Darwin.close(listenerDescriptor)
            listenerDescriptor = -1
        }
        // Identity checks protect files replaced by another app launch.
        if let socketIdentity, socketIdentity == ChromeHostIdentity.FileIdentity(path: socketPath) {
            try? unlinkSocketIfPresent(path: socketPath)
        }
        socketIdentity = nil
        // The secret dies with the listener that minted it.
        let tokenPath = ChromeHostIdentity.tokenPath(forSocketPath: socketPath)
        if let tokenIdentity, tokenIdentity == ChromeHostIdentity.FileIdentity(path: tokenPath) {
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        tokenIdentity = nil
        // Retire all listener-owned state before yielding to channel cleanup.
        if let existing {
            await existing.shutdown()
        }
        if let existingConnecting {
            await existingConnecting.shutdown()
        }
    }

    public static func defaultSocketPath() -> String {
        InstallPaths.current.chromeSocket.path
    }
}

private func bindUnixSocket(descriptor: Int32, path: String) throws {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8CString)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
        tuplePointer.withMemoryRebound(to: Int8.self, capacity: pathBytes.count) { pointer in
            for (index, byte) in pathBytes.enumerated() { pointer[index] = byte }
        }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw ChromeControlRuntimeError.socketFailure(errno) }
}

private func unlinkSocketIfPresent(path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        if errno == ENOENT { return }
        throw ChromeControlRuntimeError.socketFailure(errno)
    }
    guard (info.st_mode & S_IFMT) == S_IFSOCK else {
        throw ChromeControlRuntimeError.unsafeSocketPath
    }
    guard unlink(path) == 0 else { throw ChromeControlRuntimeError.socketFailure(errno) }
}
