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


extension NativeClient {
    func configureSearXNG(baseURL: String) async throws {
        // 2026-06-06 daemon-config retirement: write the user-supplied
        // searxng_base_url into the Swift-native `<dataRoot>/research/config.json`.
        // Previously a no-op stub (daemon owned the writer); now Swift owns it
        // under the same file lock the picker/autodetect helpers use.
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = await persistence.readJSON(path, defaultValue: .object([:]))
            var root: [String: JSONValue]
            if case .object(let obj) = current { root = obj } else { root = [:] }
            root["searxng_base_url"] = .string(trimmed)
            try await persistence.writeJSON(.object(root), to: path)
        }
    }

    func autodetectSearXNG() async throws -> DetectSearXNGResponse {
        // Subsystem #17 (cluster C7): when .research is on, the in-process
        // SwiftNativeResearchClient runs the same docker-ps + common-port
        // scan, persists `searxng_base_url` via PersistenceCore, and skips
        // the retired route entirely.
        return try await swiftAutodetectSearXNG()
    }

    func search(query: String) async throws -> [ResearchResult] {
        // Subsystem #17 (cluster C7): when .research is on, the in-process
        // SwiftNativeResearchClient queries SearXNG directly using the same
        // /search?format=json call the daemon uses, writes a receipt JSON
        // to data/research/<id>.json, and returns the same [{title,url,
        // snippet,source}] shape the daemon does.
        return try await swiftResearchSearch(query: query)
    }
}
