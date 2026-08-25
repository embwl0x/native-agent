import Foundation
import Testing
@testable import TelegramBot
import BackgroundLoops
import PersistenceCore

// MARK: - Coverage ledger: telegram.loop.tickTimeoutOverride
//                         telegram.loop.interval
//                         telegram.config.model/reasoningEffort
//                         telegram.status.voiceHealthBlock
//
// Four settings whose failure is invisible from the outside: a reverted tick
// budget cancels long turns mid-LLM-call and silently eats the rest of the
// batch (the 2026-06-09 audit bug); a raised interval adds a latency floor
// nobody attributes to config; a per-bot model override that stops being read
// falls back to the surface picker; and the voice health block is the settings
// panel's ONLY read on whether voice can work at all.

private func telegramStatusExtras(_ status: TelegramStatus, _ key: String) -> [String: JSONValue]? {
    guard case .object(let extras)? = status.extras,
          case .object(let block)? = extras[key] else { return nil }
    return block
}

@Suite struct TelegramSettingsSurfaceTests {

    // MARK: tick budget + interval

    /// A tick runs the WHOLE chat turn (long poll + transcription + tool loop).
    /// The scheduler's uniform budget is 300s (BackgroundLoopsManager.swift:581,
    /// :631) and the LoopRunner default override is nil, i.e. "take the 300s".
    /// If this loop ever loses its override, a 5-minute turn is cancelled
    /// mid-call and the remaining updates are consumed with no user-visible
    /// error. Envelope: strictly greater than the scheduler default, at least
    /// an hour, and finite.
    @Test func telegramLoop_tick_budget_outlives_the_scheduler_default() {
        let loop = TelegramPollLoop(token: "budget-token")
        guard let override = loop.tickTimeoutOverride else {
            Issue.record("Telegram loop must override the 300s scheduler tick budget")
            return
        }

        #expect(override >= 3600)
        #expect(override > TelegramSettingsSurfaceTests.schedulerDefaultTickBudget)
        #expect(override.isFinite)
        // A runner that does NOT override inherits nil → the 300s default.
        // Pinning this makes the comparison above meaningful rather than a
        // comparison against a number typed twice.
        #expect(DefaultBudgetProbeRunner().tickTimeoutOverride == nil)
    }

    /// Documented scheduler default (BackgroundLoopsManager.swift:581/:631/:653
    /// and BackgroundLoops.swift:802 all spell 300).
    private static let schedulerDefaultTickBudget: TimeInterval = 300

    private struct DefaultBudgetProbeRunner: LoopRunner {
        let loopId = "telegram_budget_probe"
        let interval: TimeInterval = 2
        func tickOutcome() async -> LoopTickOutcome { .completed(result: nil) }
    }

    /// The poll interval is the gap BETWEEN long polls; each tick already
    /// blocks ~25s inside Telegram's long poll. A raised interval is a pure
    /// per-message latency floor. Envelope, not the exact number.
    @Test func telegramLoop_interval_stays_inside_the_latency_floor_envelope() {
        let loop = TelegramPollLoop(token: "interval-token")
        #expect(loop.interval > 0)
        #expect(loop.interval <= 5)
        // An explicit interval must be honoured verbatim — a clamp here would
        // silently ignore an operator's setting.
        #expect(TelegramPollLoop(interval: 0.5, token: "t").interval == 0.5)
    }

    // MARK: per-bot model override

    @Test func telegramConfig_model_and_reasoningEffort_round_trip_from_disk() throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(
                botToken: "123:abc",
                allowedChatIds: [77],
                enabled: true,
                model: "claude-opus-5",
                reasoningEffort: "high"
            ),
            dataRoot: root
        )

        let loaded = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(loaded.model == "claude-opus-5")
        #expect(loaded.reasoningEffort == "high")
    }

    /// The wrong-value trap: a blank override must normalize to nil so the
    /// surface picker runs. An empty-string model reaching the provider is a
    /// silent zero — the turn fails or silently swaps models.
    @Test func telegramConfig_blank_model_override_normalizes_to_nil() throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"bot_token":"123:abc","enabled":true,"model":"   ","reasoning_effort":""}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))

        let loaded = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(loaded.model == nil)
        #expect(loaded.reasoningEffort == nil)
    }

    /// The Mac settings panel reads the override off getStatus().extras. If the
    /// surfacing drops, the panel shows "picker" while the loop uses the
    /// override (or the reverse) with nothing failing.
    @Test func telegramStatus_surfaces_the_model_override_it_loaded() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(
                botToken: "123:abc",
                allowedChatIds: [77],
                enabled: true,
                model: "claude-opus-5",
                reasoningEffort: "high"
            ),
            dataRoot: root
        )
        let status = try await SwiftNativeTelegramBot(dataRoot: root).getStatus()
        guard case .object(let extras)? = status.extras else {
            Issue.record("status carried no extras")
            return
        }
        #expect(extras["model"] == .string("claude-opus-5"))
        #expect(extras["reasoningEffort"] == .string("high"))

        let bareRoot = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: bareRoot) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(botToken: "123:abc", allowedChatIds: [77], enabled: true),
            dataRoot: bareRoot
        )
        let bare = try await SwiftNativeTelegramBot(dataRoot: bareRoot).getStatus()
        guard case .object(let bareExtras)? = bare.extras else {
            Issue.record("status carried no extras")
            return
        }
        // Explicit null, not a missing key: the panel distinguishes
        // "no override" from "we forgot to report".
        #expect(bareExtras["model"] == .null)
        #expect(bareExtras["reasoningEffort"] == .null)
    }

    // MARK: voice health block

    /// An unsupported backend string must report BOTH flags false. The ledger
    /// flagged `guard voiceRequiresAPIKey else { return true }` as reporting
    /// "configured" unconditionally for non-OpenAI backends; the
    /// backendSupported guard in front of it is what stops that, and nothing
    /// pinned it.
    @Test func voiceHealth_unsupported_backend_reports_unsupported_and_unconfigured() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(
            #"{"bot_token":"123:abc","enabled":true,"voice_transcription_backend":"deepgram"}"#.utf8
        ).write(to: dir.appendingPathComponent("config.json"))

        let status = try await SwiftNativeTelegramBot(dataRoot: root).getStatus()
        let block = try #require(telegramStatusExtras(status, "voiceTranscription"))
        #expect(block["backendSupported"] == .bool(false))
        #expect(block["keyConfigured"] == .bool(false))
    }

    @Test func voiceHealth_appleSpeech_backend_needs_no_key_and_is_supported() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(
                botToken: "123:abc",
                allowedChatIds: [77],
                enabled: true,
                voiceTranscriptionBackend: TelegramVoiceTranscriptionBackends.appleSpeech
            ),
            dataRoot: root
        )
        let status = try await SwiftNativeTelegramBot(dataRoot: root).getStatus()
        let block = try #require(telegramStatusExtras(status, "voiceTranscription"))
        #expect(block["backendSupported"] == .bool(true))
        #expect(block["requiresAPIKey"] == .bool(false))
        #expect(block["keyConfigured"] == .bool(true))
    }

    @Test func voiceHealth_openAI_backend_reads_the_provider_key_under_the_pinned_root() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(
                botToken: "123:abc",
                allowedChatIds: [77],
                enabled: true,
                voiceTranscriptionBackend: TelegramVoiceTranscriptionBackends.openAI
            ),
            dataRoot: root
        )

        // (a) no key file under this root. The resolver consults the process
        // environment FIRST, so this leg is only meaningful when the harness
        // has no OPENAI_API_KEY exported — asserting it unconditionally would
        // make the test environment-dependent rather than hermetic.
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil {
            let before = try await SwiftNativeTelegramBot(dataRoot: root).getStatus()
            let blockBefore = try #require(telegramStatusExtras(before, "voiceTranscription"))
            #expect(blockBefore["requiresAPIKey"] == .bool(true))
            #expect(blockBefore["backendSupported"] == .bool(true))
            #expect(blockBefore["keyConfigured"] == .bool(false))
        }

        // (b) a provider key file under THIS root flips it — proving the block
        // reads the pinned dataRoot and not some ambient location.
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try Data(#"{"api_key":"sk-test-not-a-real-key"}"#.utf8)
            .write(to: providers.appendingPathComponent("openai.json"))

        let after = try await SwiftNativeTelegramBot(dataRoot: root).getStatus()
        let blockAfter = try #require(telegramStatusExtras(after, "voiceTranscription"))
        #expect(blockAfter["keyConfigured"] == .bool(true))
    }
}
