import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry


extension NativeClient {
    struct ManifestSkillValue: Decodable {
        let state: String
        let version: String
        let type: String
        let installedAt: String?
        let path: String
    }
    struct ManifestRegistryFile: Decodable {
        let skills: [String: ManifestSkillValue]
    }

    // PATCH-2026-05-07: bugfix-2 read manifest skills from the local registry.
    /// Read the manifest skill registry from the Swift-native filesystem source.
    func readSkillRegistry() async throws -> [SkillRegistryEntry] {
        // Subsystem #24 wave 31: SwiftNative read-side port of
        // GET /v1/skills/manifest (manifest_registered_skills + the route's
        // {"name": k, **v} reshape). When .skills is ON, serve the merged
        // manifest natively (Mac process is co-located with the data files),
        // decoding into the same SkillRegistryEntry shape the HTTP path yields.
        // On any native error, fall through to the direct filesystem fallback.
        let impl = makeSkillsClient(root: PersistenceCore.defaultDataRoot())
        if let rows = try? await impl.listManifestSkills(),
           let data = try? JSONValue.array(rows).serializedData(pretty: false),
           let entries = try? JSONDecoder.nativeAgent.decode([SkillRegistryEntry].self, from: data) {
            return entries
        }
        // HTTP path retired post-Swift-native-cutover. The makeSkillsClient impl above
        // is the canonical Swift-native path; this fallback now reads the
        // manifest_registry.json directly if the impl returned nil.
        // Fallback: direct filesystem read of manifest_registry.json
        // Phase 11c: read from <repo>/data/ via shared resolver.
        let appSupport = NativeAgentPaths.dataRoot
        let registryURL = appSupport.appendingPathComponent("skills/manifest_registry.json")
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return []
        }
        let data = try Data(contentsOf: registryURL)
        let wrapper = try JSONDecoder.nativeAgent.decode(ManifestRegistryFile.self, from: data)
        return wrapper.skills.map { name, val in
            SkillRegistryEntry(name: name, state: val.state, version: val.version,
                               type: val.type, installedAt: val.installedAt, path: val.path)
        }
    }

    /// Read a skill's manifest.json from its directory (v1 fallback).
    func readSkillManifest(entry: SkillRegistryEntry) throws -> SkillManifest {
        let skillDir = try skillDirectory(for: entry)
        let manifestURL = skillDir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder.nativeAgent.decode(SkillManifest.self, from: data)
    }

    /// Read a skill's README.md from its directory if present (v1 fallback).
    func readSkillReadme(entry: SkillRegistryEntry) throws -> String? {
        let skillDir = try skillDirectory(for: entry)
        let readmeURL = skillDir.appendingPathComponent("README.md")
        guard FileManager.default.fileExists(atPath: readmeURL.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: readmeURL.path)
        let byteCount = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let previewLimit = 64 * 1024
        if byteCount <= previewLimit {
            return try String(contentsOf: readmeURL, encoding: .utf8)
        }
        let handle = try FileHandle(forReadingFrom: readmeURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: previewLimit) ?? Data()
        let preview = String(decoding: data, as: UTF8.self)
        return preview + "\n\n[README preview truncated in the app: \(byteCount) bytes total.]"
    }

    func skillDirectory(for entry: SkillRegistryEntry) throws -> URL {
        let fm = FileManager.default
        let fallback = NativeAgentPaths.dataRoot.appendingPathComponent("skills/\(entry.name)")
        let rawPath = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return fallback }

        let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
        let allowedRoots = [
            NativeAgentPaths.dataRoot.appendingPathComponent("skills").standardizedFileURL,
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/NativeAgent/skills")
                .standardizedFileURL,
        ]
        let candidatePath = candidate.path
        let allowed = allowedRoots.contains { root in
            candidatePath == root.path || candidatePath.hasPrefix(root.path + "/")
        }
        if allowed, fm.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
            return candidate
        }
        return fallback
    }

    /// Enable a skill — routes to POST /v1/skills/{name}/enable (Task 1.4 endpoint).
    /// wave 32 W15: gated to the Swift impl (legacy update_skill status flip
    /// with the manifest state-machine fallback, all flocked) when .skills ON.
    func enableSkill(name: String) async throws {
        let impl = makeSkillsClient(root: PersistenceCore.defaultDataRoot())
        _ = try await impl.enableSkill(name: name)
        return
    }

    /// Disable a skill — routes to POST /v1/skills/{name}/disable (Task 1.4 endpoint).
    /// wave 32 W15: gated to the Swift impl (installed|active → dormant manifest
    /// fallback) when .skills ON.
    func disableSkill(name: String) async throws {
        let impl = makeSkillsClient(root: PersistenceCore.defaultDataRoot())
        _ = try await impl.disableSkill(name: name)
        return
    }

    /// Revoke OAuth for a connector (Task 1.4 endpoint).
    ///
    /// Subsystem #26b wave 35 W06 (2026-06-02) — CLOSES CUTOVER_PLAN.md §6.116
    /// follow-up #7 (the wave-34 W18 reopen). When `.connectorAuth` is ON
    /// (DEFAULT OFF; leash-held), the OAuth "clear" LOCAL mutation runs in-process
    /// against the co-located data root via SwiftNativeConnectorAuthClient: unlink
    /// `<root>/oauth_tokens/<provider>.json` + write the registry record to
    /// `not_connected` under the SAME cross-process flock the daemon's
    /// connector_revoke holds (W18 §6.97). Gated on `.connectorAuth`, NOT the read
    /// flag `.connectors`, so a read-flag flip cannot silently enable the write
    /// (same lesson as `.personaEngineWrites`/`.swarmExecute`). The daemon's
}
