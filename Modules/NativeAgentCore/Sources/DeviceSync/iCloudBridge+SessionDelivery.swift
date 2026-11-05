import ChatTurnRuntime
import Foundation
import NativeAgentCore
import os
import TrustCenter
// Blueprint: | `iCloudBridge+SessionDelivery.swift` | Bound device route; conflated progress joins before terminal recovery. |

extension iCloudBridge {
    /// A phone route without its device or surface throws, so the owed delivery names the missing field instead of guessing a phone.
    public func sessionDelivery(_ context: SessionTurnDelivery.Context) throws -> SessionTurnDelivery.Recipient? {
        guard context.dataRoot.standardizedFileURL == sync.dataRoot.standardizedFileURL,
              let route = context.route, ConversationSurfaceProfile(route.surface).isIOSRemote else { return nil }
        guard let sourceKey = route.sourceKey, AgentBridgeCompletionRoute.isValidIOSDeviceRouteKey(sourceKey) else {
            throw ToolFailureError("The phone reply route names no device; nothing was sent.", argumentPath: "route.sourceKey",
                accepted: "iphone, iphone:<device name>", effects: .none)
        }
        guard let replyTo = route.replyTo else {
            throw ToolFailureError("The phone reply route names no client surface; nothing was sent.", argumentPath: "route.replyTo",
                accepted: ICloudPhoneRoute.clientSurfaces.sorted().joined(separator: ", "), effects: .none)
        }
        let dataRoot = sync.dataRoot
        let sender = ICloudConflatedSender()
        let text = OSAllocatedUnfairLock(initialState: ICloudTextDeltaCoalescer())
        return .init(progress: { event in
            guard case .delta(let delta) = event, !delta.isEmpty,
                  let flush = text.withLock({ $0.push(delta: delta) }) else { return }
            sender.submit(key: "delta") {
                do {
                    _ = try await self.sendChatMessage(text: flush.text, sessionID: context.sessionID,
                        correlationID: context.runID, metadata: ["kind": "text_delta", "live": "true",
                            "seq": String(flush.sequence), "transport": "icloud", "source": "mac",
                            "replyTo": replyTo, "targetSourceKey": sourceKey])
                } catch { nativeLog("Phone session preview unavailable: %@", error.localizedDescription) }
            }
        }, finish: {
            await sender.finish()
            do {
                if let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot,
                    sessionId: context.sessionID, runId: context.runID) {
                    _ = try await self.recoverReply(response, route: AgentBridgeCompletionRoute(surface: "ios",
                        sessionId: context.sessionID, sourceKey: sourceKey, replyTo: replyTo,
                        correlationId: context.runID), liveTurn: true)
                }
            } catch { nativeLog("Phone session reply remains unconfirmed: %@", error.localizedDescription) }
        })
    }
}
