import BackgroundWork
import Foundation
import AttentionRouting
import BackgroundLoops
import ChatOrchestration
import Cognition
import PersistenceCore
import Desk

// MARK: - Desk notify loop (desk-side push, NO cognition)
//
// A throttled, desk-local loop that lets the Desk tap User on the shoulder: it
// reads desk state, asks DeskNotifyEvaluator which direct/urgent items changed
// since their last ping (cooldown-gated), fires a Mac banner + paired-device
// push for each, then stamps lastNotifiedAt so a single change can't fan out
// into duplicate pings (Agent's idempotency requirement).
//
// This NEVER touches the CognitiveSubstrate — it's a SEPARATE loop from the
// cognition manifest in assembleAllLoops. The desk reaches out to User; it does
// not live in her head (User's hard line, 2026-06-29). Self-gating: with no
// item marked direct/urgent, every tick is a cheap state-read that returns nil.

extension BackgroundLoopsAssembly {
    static func makeDeskNotifyLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 24 * 60 * 60,
        postMacNotification: @escaping @Sendable (String, String) async -> Bool = { title, body in
            await NativeAgentNotifications.postAndReport(title: title, body: body).posted
        },
        postPairedDeviceNotification: (@Sendable (String, String) async -> Bool)? = nil
    ) -> some LoopRunner {
        DeskNotifyRunner(
            interval: intervalSeconds,
            dataRoot: dataRoot,
            attention: AttentionRouter.shared,
            postMacNotification: postMacNotification,
            postPairedDeviceNotification: postPairedDeviceNotification,
            postNagNotification: { title, body, handle in
                await NativeAgentNotifications.postAndReport(
                    title: title, body: body,
                    userInfo: handle.map { [NativeAgentNotificationRoute.deskHandleKey: $0] } ?? [:]
                ).posted
            }
        )
    }
}
