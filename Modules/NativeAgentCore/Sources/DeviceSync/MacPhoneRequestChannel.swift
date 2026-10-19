import Cognition
import Foundation
import NativeAgentShared
import PersistenceCore

/// One bounded waiter per request; authenticated bridge delivery settles it.
@MainActor
public final class MacPhoneRequestChannel {
    private weak var bridge: iCloudBridge?
    private struct Pending {
        let continuation: CheckedContinuation<BridgeMessage, Error>
        let deadline: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]
    var hasPendingRequest: Bool { !pending.isEmpty }

    init(bridge: iCloudBridge) { self.bridge = bridge }

    public func request(_ request: PhoneRequest) async throws -> BridgeMessage {
        guard let bridge, bridge.usesCloudKitDeviceTransport else { throw DeviceSyncError.notConfigured }
        guard pending.isEmpty else {
            throw DeviceSyncError.underlying(message: "Another phone request is waiting. Let it finish first.")
        }
        let seconds = Int(request.expiresAt.timeIntervalSinceNow.rounded())
        try Task.checkCancellation()
        let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow))) }
                    catch { return }
                    // The Mac knows only when it last heard from the phone, not whether it is listening.
                    let contact = SignedPeerEvidenceStore.load(dataRoot: PersistenceCore.defaultDataRoot())?.contactAt
                    let heard = contact.map { "it was last heard from at \(ISO8601DateFormatter().string(from: $0)), \(Int(-$0.timeIntervalSinceNow / 60)) minutes ago" }
                        ?? "it has not been heard from on this Mac"
                    self?.finish(request.id, result: .failure(DeviceSyncError.underlying(
                        message: "The phone has not answered in \(seconds) s; \(heard). If NativeAgent is open on the phone, ask again; or give a place."
                    )))
                }
                pending[request.id] = Pending(continuation: continuation, deadline: deadline)
                bridge.scheduleNextDeviceDrainFallback()
                Task { [weak self] in
                    guard self?.pending[request.id] != nil, request.expiresAt > Date() else { return }
                    do {
                        _ = try await bridge.sendChatMessage(text: text,
                            metadata: ["kind": PhoneRequest.messageKind], messageID: request.id)
                    } catch { self?.finish(request.id, result: .failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(request.id, result: .failure(CancellationError())) }
        }
    }

    func receive(_ message: BridgeMessage) {
        guard let result = try? JSONDecoder().decode(PhoneRequestResult.self, from: Data(message.text.utf8)),
              result.requestID == message.correlationID else { return }
        finish(result.requestID, result: .success(message))
    }

    private func finish(_ id: String, result: Result<BridgeMessage, Error>) {
        guard let value = pending.removeValue(forKey: id) else { return }
        bridge?.scheduleNextDeviceDrainFallback()
        value.deadline.cancel()
        value.continuation.resume(with: result)
    }
}
