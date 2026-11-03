import Cognition
import NativeAgentCore
import Foundation
import MacControl
import NativeAgentShared
import PersistenceCore

// Blueprint: | `MacPhoneRequestChannel.swift` | `MacPhoneRequestChannel`: every phone request checks notify_mobile Write at send admission through MacIntegrationPermissionStore; one bounded authenticated waiter; timeout retires waiting while send ownership drains to actual exit |

/// One bounded waiter per request; authenticated bridge delivery settles it.
@MainActor
public final class MacPhoneRequestChannel {
    private weak var bridge: iCloudBridge?
    private final class Pending {
        let done = ScopedWaiter()
        var deadline: Task<Void, Never>?
        var result: Result<BridgeMessage, Error>?
    }
    private var pending: [String: Pending] = [:]
    /// Timeout/cancel retires the waiter, but the send owns exclusion until
    /// its actual exit: cancellation cannot prove CloudKit did not deliver it.
    private var sendTask: Task<Void, Never>?
    private var sendFinished: ScopedWaiter?
    var hasPendingRequest: Bool { !pending.isEmpty }

    init(bridge: iCloudBridge) { self.bridge = bridge }

    public func request(_ request: PhoneRequest) async throws -> BridgeMessage {
        guard let bridge, bridge.usesCloudKitDeviceTransport else { throw DeviceSyncError.notConfigured }
        guard pending.isEmpty else {
            throw DeviceSyncError.underlying(message: "Another phone request is waiting. Let it finish first.")
        }
        if let finished = sendFinished {
            let ceiling = ContinuousClock.now.advanced(by: .seconds(min(3, max(0, request.expiresAt.timeIntervalSinceNow))))
            await TaskWaitDeadline.$current.withValue(min(TaskWaitDeadline.current ?? ceiling, ceiling)) {
                await finished.park()
            }
        }
        try Task.checkCancellation()
        guard pending.isEmpty, sendTask == nil, request.expiresAt > Date() else {
            throw DeviceSyncError.underlying(message: "The preceding phone request is still settling, or this request expired while waiting. Its send was not cancelled. Read the setting before another change.")
        }
        let seconds = Int(request.expiresAt.timeIntervalSinceNow.rounded())
        try Task.checkCancellation()
        let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let response = Pending()
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow))) }
            catch { return }
            // The Mac knows only when it last heard from the phone, not whether it is listening.
            let heard: String
            do {
                let contact = try SignedPeerEvidenceStore.load(dataRoot: PersistenceCore.defaultDataRoot())?.contactAt
                heard = contact.map { "it was last heard from at \(ISO8601DateFormatter().string(from: $0)), \(Int(-$0.timeIntervalSinceNow / 60)) minutes ago" }
                    ?? "it has not been heard from on this Mac"
            } catch {
                heard = "its saved contact evidence is unavailable: \(error.localizedDescription). Repair mobile/signed_peer_evidence.json, preserving its contents"
            }
            self?.finish(request.id, result: .failure(DeviceSyncError.underlying(
                message: "The phone has not answered in \(seconds) s; \(heard). "
                    + (request.kind.isSettings
                        ? "The setting's outcome is unconfirmed. Open NativeAgent on the phone and read the setting before another change."
                        : "If NativeAgent is open on the phone, ask again; or give a place.")
            )))
        }
        response.deadline = deadline
        pending[request.id] = response
        let finished = ScopedWaiter()
        sendFinished = finished
        sendTask = Task { [weak self] in
            defer { self?.sendTask = nil; self?.sendFinished = nil; finished.resume() }
            do {
                // All phone-reaching requests, including settings reads, use
                // the same Write authority as phone.request's dispatch gate.
                let integration = MacIntegrationID.notifyMobile
                let name = MacIntegrationID.displayName(for: integration)
                let tap = "Trust > Mac > Apps and features > \(name) > Write"
                guard try await MacIntegrationPermissionStore(dataRoot: bridge.sync.dataRoot).allows(integration, mode: .write) else {
                    throw ToolFailureError("operator_permission_off: \(name) Write is off. Only the owner can enable \(tap).",
                        effects: .none, owner: "security/mac_integration_permissions.json \(integration).write",
                        tap: tap, personDecides: true, code: "operator_permission_off", status: .refused,
                        instruction: "Only the owner can enable this switch.")
                }
                guard self?.pending[request.id] != nil, request.expiresAt > Date() else { return }
                _ = try await bridge.sendChatMessage(text: text,
                    metadata: ["kind": PhoneRequest.messageKind], messageID: request.id)
            } catch { self?.finish(request.id, result: .failure(error)) }
        }
        await response.done.park()
        if pending[request.id] === response {
            finish(request.id, result: .failure(CancellationError()))
        }
        return try response.result!.get()
    }

    func receive(_ message: BridgeMessage) {
        guard let result = try? JSONDecoder().decode(PhoneRequestResult.self, from: Data(message.text.utf8)),
              result.requestID == message.correlationID else { return }
        finish(result.requestID, result: .success(message))
    }

    /// Passive transport teardown ends the wait once, with no claim that a
    /// cancelled send had no effect. The send's retained slot drains separately.
    func stop() {
        for id in Array(pending.keys) {
            finish(id, result: .failure(DeviceSyncError.underlying(
                message: "Phone sync stopped before this request settled; delivery and the phone's outcome are unknown."
            )))
        }
        sendTask?.cancel()
    }

    private func finish(_ id: String, result: Result<BridgeMessage, Error>) {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.deadline?.cancel()
        value.result = result
        value.done.resume()
    }
}
