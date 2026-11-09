import Foundation
import MacControl
import NativeAgentShared
import Privacy
// Blueprint: | `EngineFaceMacControlProjection.swift` | Driver and Trust events publish the canonical Mac-control presentation |

enum EngineFaceMacControlProjection {
    @concurrent static func observe(engine: NativeAgentEngine) async {
        let (events, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changed.finish() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in await MacAttentionSessionStore.shared.driverChanges() { changed.yield() }
            }
            group.addTask {
                await EngineFaceProjection.watch(read: { (engine.trust.policy, engine.trust.policyReadError) }) { _ in changed.yield() }
            }
            for await _ in events {
                guard !Task.isCancelled else { break }
                let value: MacControlFace
                do { value = try await MacAttentionSessionStore.shared.controlPresentation() }
                catch {
                    value = MacControlFace(driverAllowed: nil, handoffWouldChange: nil, handoffGeneration: nil, driver: nil,
                        state: .unavailable(.init(code: "mac_control_read_failed", message: "Mac control could not be read.",
                            cause: NativeAppSecretRedactor.redactText(error.localizedDescription), effects: .none)))
                }
                guard !Task.isCancelled else { break }
                await engine.face.post(value, at: .macControl)
            }
            group.cancelAll()
        }
    }
}
