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
    func configureTelegram(token: String, allowedChatIds: [String], allowedUserIds: [String], requireMention: Bool, model: String, reasoningEffort: String, enabled: Bool, clearToken: Bool = false) async throws {
        // DAEMON KILLED 2026-06-02. Persist to <dataRoot>/telegram/config.json.
        // If `token` arrives empty (UI cleared after a successful save), keep
        // the existing on-disk token so the IDs the user just edited don't
        // wipe out the stored token. Clear is still explicit via clearToken.
        let existing = TelegramBot.TelegramConfig.loadFromDisk()
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToken: String = {
            if clearToken { return "" }
            if !trimmedToken.isEmpty { return trimmedToken }
            return existing?.botToken ?? ""
        }()
        let chatIds: Set<Int64> = Set(allowedChatIds.compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) })
        let userIds: Set<Int64> = Set(allowedUserIds.compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) })
        // Enabled is now explicit: a saved-disabled token must round-trip so
        // the user can toggle the poller off without wiping the token. clearToken
        // and an empty effectiveToken both force enabled=false; otherwise the
        // caller's explicit `enabled` arg wins.
        let effectiveEnabled = !clearToken && !effectiveToken.isEmpty && enabled
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        let migratedModel = trimmedModel.isEmpty ? existing?.model : trimmedModel
        let migratedEffort = trimmedEffort.isEmpty ? existing?.reasoningEffort : trimmedEffort
        if migratedModel?.isEmpty == false || migratedEffort?.isEmpty == false {
            var body: [String: JSONValue] = ["surface": .string("telegram")]
            if let migratedModel, !migratedModel.isEmpty {
                body["model"] = .string(migratedModel)
                body["inferProvider"] = .bool(true)
            }
            if let migratedEffort, !migratedEffort.isEmpty {
                body["reasoningEffort"] = .string(migratedEffort)
            }
            _ = try await SwiftNativeProviderRouting().saveModelConfig(.object(body))
        }
        let cfg = TelegramBot.TelegramConfig(
            botToken: effectiveToken,
            allowedChatIds: chatIds,
            allowedUserIds: userIds,
            requireMention: requireMention,
            enabled: effectiveEnabled,
            model: nil,
            reasoningEffort: nil
        )
        try TelegramBot.TelegramConfig.saveToDisk(cfg)
        // F4 fix-3: kick the background loops manager to re-read the file on
        // disk and bring up / tear down the TelegramPollLoop. Without this,
        // the save lands but the previously-running poller keeps the OLD
        // token/allowlist until the next app restart.
        await BackgroundLoopsManager.shared.restartLoop(id: "telegram_poll")
    }

    func testTelegram(chatId: String?) async throws -> TelegramTestResponse {
        let testMessage = "NativeAgent Telegram test reply: online."
        // SwiftNative Telegram test path. The module reads the saved config and
        // calls Telegram directly; no daemon URL is required.
        let impl = makeTelegramBot()
        let result = try await impl.sendTestMessage(message: testMessage, chatId: chatId)
        let data = try JSONEncoder().encode(result.rawResponse)
        return try JSONDecoder().decode(TelegramTestResponse.self, from: data)
    }

    func clearTelegramLogs() async throws -> TelegramStatus {
        // SwiftNative clear + refreshed status. No daemon URL is required.
        let impl = makeTelegramBot()
        try await impl.clearLogs()
        let swiftStatus = try await impl.getStatus()
        let data = try JSONEncoder().encode(swiftStatus)
        return try JSONDecoder().decode(TelegramStatus.self, from: data)
    }
}
