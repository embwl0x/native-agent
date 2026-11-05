import AuthoredCapabilities
import Cognition
import Foundation
import MacControl
import NativeAgentShared
import ProviderRouting
import StandingBots
// Blueprint: | `EnginePages.swift` | The native pages registered on `engine.pages`: each page's read (its face and the record position or moment it read) and its row actions |

extension NativeAgentEngine {
    /// Every page, registered and read once at launch and again at every change of what it reads, for every door; a door's view only draws
    /// it. A native page's read and act live in its own file; this is only the list.
    @MainActor func registerPages() {
        today.start(engine: self)
        watch(page: "inbox", paths: [], notifications: [], read: inboxFaceRead(), actBy: inboxAct)
        watch(page: "trust", paths: trustFacePaths, notifications: trustFaceNotifications, read: trustFace, actBy: trustAct)
        // The Mac assistant's owner reads its watches once at launch and on its own refreshes; Trust only draws what it publishes.
        Task { @MainActor [macIntegration] in await macIntegration.refreshWatches() }
        watch(page: "desk", paths: desk.pageUpdatePaths, notifications: [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange],
              read: { try await self.deskFace() }, act: { try await self.deskAct(row: $0, action: $1, value: $2) })
        watch(page: "settings", paths: [
            "trust/policy.json", "config/embeddings.json", "security/mac_integration_permissions.json",
            "memory/memory.sqlite", "memory/memory.sqlite-wal",
        ].map { dataRoot.appendingPathComponent($0) },
              notifications: [MacIntegrationPermissionStore.didChange, SettingsFaceChange.platform, SettingsFaceChange.cognition],
              read: { try await self.settingsFace() },
              actBy: { try await self.settingsAct(row: $0, action: $1, value: $2, by: $3) })
        Task { @MainActor [cognitionView] in
            var previous: SettingsInnerLifeStatus.State?
            for await change in await cognitionView.changes() {
                guard !Task.isCancelled else { return }
                guard change.reason == "bootstrap" || change.reason.hasPrefix("configuration:")
                    || change.reason.hasPrefix("provider_lifecycle:") || change.reason.hasPrefix("reflection:") else { continue }
                await cognitionView.refreshVitals()
                let current = SettingsInnerLifeStatus.state(runtime: cognitionView.subconsciousRuntime,
                                                           reflectionRoute: cognitionView.reflectionRoute)
                guard previous != current else { continue }
                previous = current
                NotificationCenter.default.post(name: SettingsFaceChange.cognition, object: nil)
            }
        }
        let database = dataRoot.appendingPathComponent("memory/memory.sqlite")
        watch(page: "memories", paths: [database, URL(fileURLWithPath: database.path + "-wal"),
                                       dataRoot.appendingPathComponent("memory/profile.json")],
              read: { try await self.memoriesFace() }, act: { try await self.memoriesAct(row: $0, action: $1, value: $2) })
        watchPersonalityAvailability()
        watch(page: "personality", paths: personalityPaths, notifications: [ChatGPTAccountModelRefresh.didRefresh],
              read: { try await self.personalityFace() }, act: { row, action, value in
            try await self.personalityAct(row: row, action: action, value: value)
        })
        // Owners that refresh their own face at their publication points read once here and need no paths.
        watch(page: "providers", paths: [], read: providers.faceRead(on: pages), actBy: { [weak self] row, action, value, by in
            guard let self else { throw PartCallError(code: "providers_closed", message: "The provider owner has closed.") }
            return try await self.actProvidersFace(row: row, action: action, value: value, by: by)
        })
        watch(page: "connectors", paths: [], read: connectors.faceReader(pages: pages), actBy: connectors.actOnFace)
        watch(page: "capabilities", paths: [], read: CapabilitiesFace.reader(self), actBy: CapabilitiesFace.answer(self))
        watch(page: "diagnostics", paths: [], read: { [self] in diagnosticsFace() },
              act: { [self] in try await actDiagnostics(row: $0, action: $1, value: $2) })
        watch(page: "home", paths: [], read: homePageRead(), act: homePageAction())
        watch(page: "bots", paths: ContactThreadReadouts.helperPaths(dataRoot), notifications: [BotRunQueue.didChange, ShelfStore.didChange,
            ContactThreadReadouts.helpersDidChange, TranscriptsFacade.sessionIndexDidChange],
            read: BotsFace.reader(self), act: { row, action, value in try await BotsFace.act(self, row: row, action: action, value: value) })
    }

    /// A native page whose owner changes `paths` (or posts `notifications`): read now and at every change, whoever is looking.
    @MainActor func watch(page: String, paths: [URL], notifications: [Notification.Name] = [], read: @escaping PartFaces.Read,
                          act: PartFaces.Act? = nil, actBy: PartFaces.ActBy? = nil) {
        if let actBy { pages.register(page: page, read: read, actBy: actBy) } else { pages.register(page: page, read: read, act: act) }
        let pages = self.pages
        Task { @MainActor in
            await EventDeadlinePhysiology.refreshOnChanges(paths: paths, notifications: notifications) { await pages.refresh(page: page) }
        }
    }
}
