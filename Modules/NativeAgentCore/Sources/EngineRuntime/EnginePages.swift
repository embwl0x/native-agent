import AuthoredCapabilities
import AgentConversations
import AgentWorkspace
import Cognition
import DreamREMCycle
import Foundation
import MacControl
import NativeAgentShared
import ProviderRouting
import PersonaEngine
import PersistenceCore
import StandingBots
import TrustCenter
// Blueprint: | `EnginePages.swift` | The pages registered on `engine.pages`: the agent's pages (the part that draws each and its owner's packet read, levers included), the stem's lever pages (their native read), the agent's own pages, and the one way a tap runs a row's call |

extension NativeAgentEngine {
    /// Every page, registered and read once at launch and again at every change of what it reads, for every door; a door's view only draws
    /// it. A page the agent draws names its part and its owner's packet read; a lever page is the stem's own read. Each read lives in its own
    /// file; this is only the list. A row does what its call says: every tap runs it through the person's door (`ToolsFacade.personTap`).
    @MainActor func registerPages() async {
        let run: PartFaces.Run = { [tools, weak self, weak pages, weak phoneMemoryPages] call, tap in
            guard let self else { throw CancellationError() }
            if let outcome = try await self.cognitionPageOutcome(call, page: tap.page) {
                await pages?.refresh(page: tap.page)
                return outcome
            }
            let result: Result<FaceActOutcome, Error>
            do { result = .success(try await tools.personTap(call, tap)) }
            catch { result = .failure(error) }
            if tap.page == "memories" {
                await pages?.refresh(page: "memories")
                await phoneMemoryPages?.refresh(page: "memories")
            }
            return try result.get()
        }
        await pages.runs(run)
        await phoneMemoryPages.runs(run)
        let read: PartFaces.DemandRead = { [tools] in try await tools.pageRead($0, envelope: .native("background:page-read")) }
        let document: PartFaces.Call = { [tools] in await tools.face(id: $0, input: $1, version: $2, documentRead: true) }
        await pages.reads(read, project: document)
        await phoneMemoryPages.reads(read, project: document)
        await pages.register(page: "diagnostics", contains: { [dataRoot] item in
            try await RuntimeReadouts.readRunLedger(dataRoot: dataRoot).contains { $0.id == item }
        }, body: { [weak self] item in
            guard let self else { throw CancellationError() }
            return try await self.readDocument(subject: .run(item))
        })
        await pages.register(page: "today")
        Task { [weak self] in
            guard let self else { return }
            await today.start(engine: self)
        }
        await watch(page: "inbox", paths: [], notifications: [], read: inboxFaceRead())
        await watch(page: "trust", paths: trustFacePaths, notifications: trustFaceNotifications, read: trustFace)
        // The Mac assistant's owner reads its watches once at launch and on its own refreshes; Trust only draws what it publishes.
        Task { @MainActor [macIntegration] in await macIntegration.refreshWatches() }
        desk.faceDidChange = { [weak pages, today] in
            Task {
                await today.waitingChanged()
                await pages?.refresh(page: "desk")
            }
        }
        await watch(page: "desk", part: "native-desk", paths: desk.pageUpdatePaths, notifications: [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange],
              read: { try await self.deskPacket() })
        await watch(page: "settings", paths: [
            "trust/policy.json", "config/embeddings.json", "security/mac_integration_permissions.json",
            "memory/memory.sqlite", "memory/memory.sqlite-wal", "triggers/trigger_config.json", "research/config.json",
        ].map { dataRoot.appendingPathComponent($0) },
              notifications: [MacIntegrationPermissionStore.didChange, SettingsFaceChange.platform, SettingsFaceChange.cognition,
                              AbilityStore.didChange],
              read: { try await self.settingsFace() })
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
        let memoryPaths = [database, URL(fileURLWithPath: database.path + "-wal"), dataRoot.appendingPathComponent("memory/profile.json")]
        await pages.register(page: "memories", part: "native-memories", read: { try await self.memoriesPacket() })
        await phoneMemoryPages.register(page: "memories", part: "native-memories", read: { try await self.memoriesPacket(surface: "ios") })
        Task { @MainActor [pages, phoneMemoryPages] in
            await EventDeadlinePhysiology.refreshOnChanges(paths: memoryPaths, notifications: [AgentPeerStore.trustDidChange]) {
                await pages.refresh(page: "memories")
                await phoneMemoryPages.refresh(page: "memories")
            }
        }
        watchPersonalityAvailability()
        await watch(page: "personality", part: "native-personality", paths: personalityPaths, notifications: [ChatGPTAccountModelRefresh.didRefresh],
              read: { try await self.personalityPacket() })
        // Owners that refresh their own face at their publication points read once here and need no paths.
        await watch(page: "providers", paths: [], read: providers.faceRead(on: pages))
        await watch(page: "connectors", paths: connectorsFacePaths, notifications: Self.connectorsFaceNotifications, read: connectorsFaceRead())
        await pages.register(page: "connectors", body: connectorsFaceBody())
        await watch(page: "capabilities", paths: CapabilitiesFace.paths(dataRoot), notifications: CapabilitiesFace.notifications,
              read: CapabilitiesFace.reader(self))
        await pages.register(page: "capabilities", body: CapabilitiesFace.body(self))
        await watch(page: "diagnostics", part: "native-diagnostics", paths: [], read: { [self] in try await diagnosticsPacket() })
        await watch(page: "home", part: "native-home", paths: [], read: homePacketRead())
        await watch(page: "bots", paths: ContactThreadReadouts.helperPaths(dataRoot), notifications: [BotRunQueue.didChange, ShelfStore.didChange,
            ContactThreadReadouts.helpersDidChange, TranscriptsFacade.sessionIndexDidChange],
            read: BotsFace.reader(self))
        await pages.register(page: "bots", contains: { BotsFace.isDocument($0) }, body: BotsFace.body(self))
        await watch(page: "dreams", part: "native-dreams", paths: [dataRoot.appendingPathComponent("dream_diary", isDirectory: true),
            SwiftNativeTrustCenter.policyURL(dataRoot: dataRoot)], read: { try await self.dreamsPacket() })
        await pages.register(page: "dreams", contains: { _ in true }, item: { [self] item, request in
            let reading = try await dreamsPresentation(item, request: request)
            return try await collectionItemFace(reading, part: "native-dreams")
        })
        await pages.register(page: "dreams", contains: { $0.hasPrefix("entry:") }, body: { [self] item in
            try await collectionDocument(page: "dreams", item: item)
        })
        await watch(page: "knowledge", part: "native-graph", paths: [database, URL(fileURLWithPath: database.path + "-wal"),
            SwiftNativeTrustCenter.policyURL(dataRoot: dataRoot)],
            read: { try await self.graphPacket() })
        await pages.register(page: "knowledge", contains: { _ in true }, item: { [self] item, request in
            let reading = try await graphPresentation(item, request: request)
            return try await collectionItemFace(reading, part: "native-graph")
        })
        await pages.register(page: "knowledge", contains: { $0.hasPrefix("summary:") }, body: { [self] item in
            try await collectionDocument(page: "knowledge", item: item)
        })
        await registerCognitionPages()
        Task { await pages.ownPages() }
    }

    /// A page the agent's part draws from its owner's packet, whose owner changes `paths` (or posts `notifications`): read now and at every
    /// change, whoever is looking.
    @MainActor func watch(page: String, part: String, paths: [URL], notifications: [Notification.Name] = [],
                          read: @escaping PartFaces.PacketRead) async {
        await pages.register(page: page, part: part, read: read)
        let pages = self.pages
        Task { @MainActor in
            await EventDeadlinePhysiology.refreshOnChanges(paths: paths, notifications: notifications,
                directoryFiles: pageDirectoryFiles) { await pages.refresh(page: page) }
        }
    }

    /// A lever page (the stem's own read) whose owner changes `paths` (or posts `notifications`): read now and at every change, whoever is looking.
    @MainActor func watch(page: String, paths: [URL], notifications: [Notification.Name] = [], read: @escaping PartFaces.Read) async {
        await pages.register(page: page, read: read)
        let pages = self.pages
        Task { @MainActor in
            await EventDeadlinePhysiology.refreshOnChanges(paths: paths, notifications: notifications,
                directoryFiles: pageDirectoryFiles) { await pages.refresh(page: page) }
        }
    }

    nonisolated func pageDirectoryFiles(_ directory: URL) throws -> [URL] {
        let path = directory.standardizedFileURL.path
        if path == dataRoot.appendingPathComponent("dream_diary", isDirectory: true).standardizedFileURL.path {
            return try FileBackedDreamDiary(dataRoot: dataRoot).observationPaths()
        }
        if path == dataRoot.appendingPathComponent("providers", isDirectory: true).standardizedFileURL.path {
            return try SwiftNativeProviderRouting.observationPaths(dataRoot: dataRoot)
        }
        if path == defaultPersonaRoot(dataRoot: dataRoot).appendingPathComponent("skills/bodies").standardizedFileURL.path {
            return try InstalledSkillInventory.files(dataRoot: dataRoot)
        }
        if path == dataRoot.appendingPathComponent("bots/definitions", isDirectory: true).standardizedFileURL.path {
            return try BotDefinitionStore(dataRoot: dataRoot).definitionFiles()
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    nonisolated func pageFileReading(_ file: URL) throws -> JSONValue? {
        guard file.standardizedFileURL == dataRoot.appendingPathComponent("abilities/state.json").standardizedFileURL else { return nil }
        return try TrialLevers.reading(dataRoot: dataRoot)
    }
}
