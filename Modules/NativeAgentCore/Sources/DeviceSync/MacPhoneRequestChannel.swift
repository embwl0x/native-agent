import Foundation
import NativeAgentShared

/// One bounded waiter per request; authenticated bridge delivery settles it.
@MainActor
public final class MacPhoneRequestChannel {
    private weak var bridge: iCloudBridge?
    private struct Pending {
        let continuation: CheckedContinuation<BridgeMessage, Error>
        let deadline: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]

    init(bridge: iCloudBridge) { self.bridge = bridge }

    public func request(_ request: PhoneRequest) async throws -> BridgeMessage {
        guard let bridge, bridge.usesCloudKitDeviceTransport else { throw DeviceSyncError.notConfigured }
        guard pending.isEmpty else {
            throw DeviceSyncError.underlying(message: "Another phone request is waiting. Let it finish first.")
        }
        try Task.checkCancellation()
        let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow))) }
                    catch { return }
                    self?.finish(request.id, result: .failure(DeviceSyncError.underlying(
                        message: "Phone request \(request.id) expired without a result. The phone may have been offline or closed; no result is claimed."
                    )))
                }
                pending[request.id] = Pending(continuation: continuation, deadline: deadline)
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
        value.deadline.cancel()
        value.continuation.resume(with: result)
    }
}
