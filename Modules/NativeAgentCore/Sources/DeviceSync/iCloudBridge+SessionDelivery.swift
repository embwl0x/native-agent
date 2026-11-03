import ChatTurnRuntime
import Foundation
import NativeAgentCore
import os
import TrustCenter
// Blueprint: | `iCloudBridge+SessionDelivery.swift` | Phone continuation recipient resolves the bound device route, retains conflated full-text snapshots and joins admitted publication before reply recovery; fresh phone turns use the mounted forwarder stream |

extension iCloudBridge {
    public func sessionDelivery(_ context: SessionTurnDelivery.Context) -> SessionTurnDelivery.Recipient? {
        guard context.dataRoot.standardizedFileURL == sync.dataRoot.standardizedFileURL,
              let route = context.route, ConversationSurfaceProfile(route.surface).isIOSRemote, let sourceKey = route.sourceKey,
              AgentBridgeCompletionRoute.isValidIOSDeviceRouteKey(sourceKey) else { return nil }
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
                            "replyTo": route.replyTo ?? "iphone", "targetSourceKey": sourceKey])
                } catch { nativeLog("Phone session preview unavailable: %@", error.localizedDescription) }
            }
        }, finish: {
            await sender.finish()
            do {
                if let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot,
                    sessionId: context.sessionID, runId: context.runID) {
                    _ = try await self.recoverReply(response, route: AgentBridgeCompletionRoute(surface: "ios",
                        sessionId: context.sessionID, sourceKey: sourceKey, replyTo: route.replyTo,
                        correlationId: context.runID), liveTurn: true)
                }
            } catch { nativeLog("Phone session reply remains unconfirmed: %@", error.localizedDescription) }
        })
    }
}
