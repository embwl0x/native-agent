import Foundation
import NativeAgentCore
import PersistenceCore
import BackgroundLoops
import ProviderRouting

// MARK: - Subsystem #13: TelegramBot
//
// SwiftNative owns Telegram management and the polling path directly.
//
// The Swift surface covers Telegram management and runtime delivery:
//   GET  /v1/telegram/status         — status snapshot
//   POST /v1/telegram/test           — send a test reply to the configured chat
//   POST /v1/telegram/logs/clear     — wipe receipts/blocked/errors jsonl logs
//   Swift long-poll loop              — getUpdates directly, no daemon hop
//   Slash-command dispatch            — /status plus completeness extension
//   Inbound media ingest              — Telegram Bot API direct download
//   Chat fan-out                      — Swift ChatOrchestration handler
//
// The old daemon-era status envelope was wider than this typed model. Field
// set still evolves, so we extract a small headline set and preserve the rest
// in `extras`.
