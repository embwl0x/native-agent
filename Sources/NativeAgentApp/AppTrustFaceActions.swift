import AppKit
import ActivityWatch
import AppToolRuntime
import ChatTurnContracts
import ChatTurnRuntime
import EngineRuntime
import MacIntegration
import NativeAgentShared
import PersistenceCore
import SwiftUI
import TrustCenter
import TrustPersistence
import UniformTypeIdentifiers
// Blueprint: | `AppTrustFaceActions.swift` | Trust's native permission controls, Chrome setup, app chooser, workbench and restore adapter |

extension AppQuietToolHost: TrustFaceHost {
    func restoreTrustFaceBackup(_ backup: BackupRecord) async throws -> String {
        switch await appModel.restoreBackup(backup) {
        case .saved(let message): return message
        case .failed(let message): throw PartCallError(code: "restore_failed", message: message)
        }
    }

    func trustFaceMacAction(_ action: String) async throws -> String {
        switch action {
        case "backup":
            switch await appModel.createBackup(reason: "manual Trust Center backup") {
            case .created(_, let message): return message
            case .failed(let message): throw PartCallError(code: "backup_failed", message: message)
            }
        case "setup_mac":
            let policy = try await appModel.engine.trust.load()
            guard let mac = TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(policy) else {
                throw PartCallError(code: "unavailable", message: "Mac access policy is unavailable.")
            }
            let preset = TrustAccessModeCapabilityCatalog.macIntegrationPreset(for: mac)
            if !TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy), preset == .off || preset == .watch {
                let saved = try await appModel.saveMacIntegrationPreset(MacIntegrationPreset.assistant.rawValue, currentPolicy: policy)
                appModel.applySavedTrustPolicy(saved, status: "Applied Assistant.")
            }
            return try await trustFaceMacAction("check_calendar_reminders")
        case "check_calendar_reminders":
            var lines: [String] = []
            var failed = false
            do {
                let calendar = try await appModel.runConnectorAction(id: "mac.calendar_list_upcoming", dryRun: false,
                    input: ["hours_ahead": .int(24), "limit": .int(5)])
                lines.append("Calendar: " + calendar.status)
            } catch { failed = true; lines.append("Calendar check failed: " + error.localizedDescription) }
            do {
                let reminders = try await appModel.runConnectorAction(id: "mac.reminders_list_due_today", dryRun: false,
                    input: ["include_completed": .bool(false), "limit": .int(10)])
                lines.append("Reminders: " + reminders.status)
            } catch { failed = true; lines.append("Reminders check failed: " + error.localizedDescription) }
            let message = lines.joined(separator: "; ")
            if failed { throw PartCallError(code: "check_incomplete", message: message) }
            return message
        case "send_notification":
            let sent = try await appModel.macControlNotify(title: "NativeAgent", message: "Mac Control test")
            guard sent else { throw PartCallError(code: "notification_unconfirmed", message: "The notification was not confirmed sent.") }
            return "Sent."
        case "macos_permissions":
            TrustFaceWindows.show("permissions", title: "macOS permissions", content: MacIntegrationView().environment(appModel))
            return "The existing macOS permission controls are open on this Mac. No grant was requested by opening them."
        case "workbench":
            let policy = try await appModel.engine.trust.load()
            guard policy.macControlPolicy != nil else {
                throw PartCallError(code: "unavailable", message: "Mac control policy is unavailable.")
            }
            TrustFaceWindows.show("workbench", title: "Mac control workbench", content:
                TrustFaceWorkbench().environment(appModel))
            return "The Mac control workbench is open. Nothing has run."
        case "setup_chrome":
            let turn = TurnRequest(message: "", sessionID: nil, surface: "native_actions",
                envelope: TurnEnvelope.personOnMac("mac_ui:chrome.setup", surface: "native_actions")).turn()
            _ = try await ChromeExtensionFolder.setUp(turn: turn, context: .init(dataRoot: appModel.engine.dataRoot))
            return "Chrome connected."
        case "exclude_app":
            let panel = NSOpenPanel()
            panel.title = "Choose an app to exclude"
            panel.prompt = "Choose App"
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK else { return "No app was selected; nothing changed." }
            guard let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else {
                throw PartCallError(code: "app_unavailable", message: "The chosen app has no readable bundle identity; nothing changed.")
            }
            let alert = NSAlert()
            alert.messageText = "Exclude this app and delete what was recorded?"
            alert.informativeText = "Everything already recorded for \(id) is deleted for good, including the recovery log. Future recording skips it entirely."
            alert.addButton(withTitle: "Exclude and delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return "Exclusion cancelled; nothing changed." }
            let controller = appModel.engine.activityWatch
            await controller.addExclusion(bundleID: id)
            guard try await controller.checkedPolicy().excludedBundleIDs.contains(id), let rows = controller.lastPurgedRowCount else {
                throw PartCallError(code: "exclusion_incomplete", message: controller.lastError ?? "Exclusion and deletion could not both be confirmed.")
            }
            return "Excluded \(id); deleted \(rows) recorded spans."
        default: throw PartCallError(code: "no_action", message: "That native Trust action does not exist.")
        }
    }
}

private struct TrustFaceWorkbench: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            if let policy = appModel.engine.trust.policy,
               let effective = TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(policy) {
                MacControlWorkbenchView(policy: effective).padding(24)
            } else {
                Text("Mac control policy is unavailable. Read Trust again.").padding(24)
            }
        }
    }
}

/// Windows retain only native presentation. Their buttons read the same AppModel and canonical policy owners.
@MainActor private enum TrustFaceWindows {
    static var controllers: [String: NSWindowController] = [:]

    static func show<Content: View>(_ id: String, title: String, content: Content) {
        if let controller = controllers[id], controller.window?.isVisible == true {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.center()
        let controller = NSWindowController(window: window)
        controllers[id] = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
