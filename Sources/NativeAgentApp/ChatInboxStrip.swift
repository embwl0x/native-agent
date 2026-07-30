import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

struct InboxStripContainer: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var items: [InboxItemRecord] = []
    // error_handling fix: surface inbox-action failures instead of swallowing
    // them with `try?` and proceeding as if the action succeeded.
    @State private var actionError: String? = nil
    // U5 W-A item 1 (ChatView:2287): a failed inbox READ was swallowed into
    // [] — the strip rendered as "no unread items" on a corrupt/unreadable
    // inbox. Load failures now keep the last-known items and render this
    // inline error row instead of fabricating an empty strip.
    @State private var loadError: String? = nil

    // R22: source the client from AppModel's canonical `client`.
    private var client: NativeClient { appModel.client }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        if let loadError {
            Label("Inbox unavailable: \(loadError)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help("The unread-inbox read failed; items shown may be stale. The strip retries when the inbox changes.")
                .accessibilityIdentifier("inbox-strip-load-error")
        }
        InboxStripView(
            items: items,
            onAction: { id, actionID in
                do {
                    try await client.inboxAction(id, action: actionID)
                } catch {
                    // Do NOT mark success / reload / write snapshots on failure —
                    // surface the failure to the user.
                    actionError = "Inbox action failed: \(error.localizedDescription)"
                    return
                }
                // Every successful action changes inbox state. Reload now so
                // a read item leaves the unread strip immediately instead of
                // lingering until the next poll, then publish the same state
                // to peripheral surfaces.
                await reload()
                await MacSyncEngine.shared.writeSnapshots()
            }
        )
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let inboxPath = PersistenceCore.defaultDataRoot()
                .appendingPathComponent("notifications", isDirectory: true)
                .appendingPathComponent("inbox.jsonl")
            await ViewFileRefreshTask.run(paths: [inboxPath]) {
                await reload()
            }
        }
        .alert(
            "Inbox action failed",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        }
    }

    func reload() async {
        do {
            items = try await client.getInboxItems(unreadOnly: true)
            loadError = nil
        } catch {
            // Keep last-known items — never fabricate an empty strip; the
            // inline error row above renders the real failure.
            loadError = error.localizedDescription
        }
    }
}

// PATCH-2026-05-07: chat-provider-picker Now shows Provider → Model
// dual picker. Provider list comes from /v1/providers (cached on AppModel
// as providersList). Model list narrows to whatever the SELECTED provider
// exposes — so picking Anthropic shows Claude models, picking ChatGPT
// shows GPT models, etc. Falls back to the catalog-based static list when
// no provider is matched (codex / local / etc).
