import Cognition
import NativeAgentCore
import Foundation
import MacControl
import NativeAgentShared
import PersistenceCore

// Blueprint: | `MacPhoneRequestChannel.swift` | Authenticated phone-request results; sends retain exclusion until completion. |

/// Authenticated results settle requests; shutdown releases observation with the outcome unknown.
@MainActor
public final class MacPhoneRequestChannel {
    private weak var bridge: iCloudBridge?
    private final class Pending {
        let done = ScopedWaiter()
        var result: Result<BridgeMessage, Error>?
    }
    private var pending: [String: Pending] = [:]
    /// A cancelled observation cannot prove CloudKit did not deliver.
    private var sendTask: Task<Void, Never>?
    private var sendFinished: ScopedWaiter?
    var hasPendingRequest: Bool { !pending.isEmpty }

    init(bridge: iCloudBridge) { self.bridge = bridge }

    public func request(_ request: PhoneRequest, deadline: ContinuousClock.Instant?) async throws -> BridgeMessage {
        guard let bridge, bridge.usesCloudKitDeviceTransport else { throw DeviceSyncError.notConfigured }
        guard pending.isEmpty else {
            throw DeviceSyncError.underlying(message: "Another phone request is waiting. Let it finish first.")
        }
        if let finished = sendFinished {
            await finished.park(budget: .init(deadline: deadline))
        }
        try Task.checkCancellation()
        guard pending.isEmpty, sendTask == nil else {
            throw DeviceSyncError.underlying(
                message: """
                    The preceding phone request is still settling. Its send was not cancelled. Read the setting \
                    before another change.
                    """)
        }
        try Task.checkCancellation()
        let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let response = Pending()
        pending[request.id] = response
        let finished = ScopedWaiter()
        sendFinished = finished
        sendTask = Task { [weak self] in
            defer { self?.sendTask = nil; self?.sendFinished = nil; finished.resume() }
            do {
                // Every phone-reaching request needs the same Write authority, including settings reads.
                let integration = MacIntegrationID.notifyMobile
                let name = MacIntegrationID.displayName(for: integration)
                let tap = "Trust > Mac > Apps and features > \(name) > Write"
                guard try await MacIntegrationPermissionStore(dataRoot: bridge.sync.dataRoot).allows(integration, mode: .write) else {
                    throw ToolFailureError("operator_permission_off: \(name) Write is off. Only the owner can enable \(tap).",
                        effects: .none, owner: "security/mac_integration_permissions.json \(integration).write",
                        tap: tap, personDecides: true, code: "operator_permission_off", status: .refused,
                        instruction: "Only the owner can enable this switch.")
                }
                guard self?.pending[request.id] != nil else { return }
                _ = try await bridge.sendChatMessage(text: text,
                    metadata: ["kind": PhoneRequest.messageKind], messageID: request.id)
            } catch { self?.finish(request.id, result: .failure(error)) }
        }
        await response.done.park(budget: .init(deadline: deadline))
        if pending[request.id] === response {
            finish(request.id, result: .failure(CancellationError()))
        }
        guard let result = response.result else {
            throw DeviceSyncError.underlying(message: "Phone request waiting ended without a result; its outcome is unconfirmed.")
        }
        return try result.get()
    }

    func receive(_ message: BridgeMessage) throws {
        let result = try JSONDecoder().decode(PhoneRequestResult.self, from: Data(message.text.utf8))
        guard result.requestID == message.correlationID else {
            throw DeviceSyncError.underlying(message: "The phone request result does not match its signed correlation ID.")
        }
        finish(result.requestID, result: .success(message))
    }

    /// Teardown settles the waiter once without claiming no effect; the retained send drains separately.
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
        value.result = result
        value.done.resume()
    }
}
