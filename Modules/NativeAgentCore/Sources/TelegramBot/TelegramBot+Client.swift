import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import BackgroundLoops
import ProviderRouting
import ApprovalInbox
import NativeAgentShared
import ChatToolRuntime
import MemoryV2
import DeviceSync
import NotificationInbox

// Blueprint: | `TelegramBot+Client.swift` | `SwiftNativeTelegramBot` client wiring and dependency/result contracts; status/test send, locked log clearing and long-poll accounting |

/// Writes Telegram-originated durable memory and notes through the app layer.
public protocol TelegramMemoryWriteRef: Sendable {
    func remember(text: String, source: String) async throws -> String
    func note(text: String, kind: String, source: String) async throws -> String
}

/// Nil reply means unsupported; a committed restart must terminate after the reply attempt, even on send failure.
public struct TelegramSlashDispatchOutcome: Sendable {
    public let reply: String?
    public let afterReplySent: (@Sendable () -> Void)?

    public init(reply: String?, afterReplySent: (@Sendable () -> Void)? = nil) {
        self.reply = reply
        self.afterReplySent = afterReplySent
    }
}

public struct TelegramBotCompletenessDeps: Sendable {
    public let routing: TelegramProviderRoutingBridge?
    public let memory: (any TelegramMemoryWriteRef)?
    public let restart: TelegramRestartBridge?

    public init(
        routing: TelegramProviderRoutingBridge? = nil,
        memory: (any TelegramMemoryWriteRef)? = nil,
        restart: TelegramRestartBridge? = nil
    ) {
        self.routing = routing
        self.memory = memory
        self.restart = restart
    }
}

public actor SwiftNativeTelegramBot {
    let dataRoot: URL
    private let backgroundLoopsManager: BackgroundLoopLifetimes
    let compactionHandler: TelegramCompaction?
    let completenessDeps: TelegramBotCompletenessDeps?
    let partCall: TelegramPartCall?
    let partFace: PartFaces.Call?
    var commandFaces: Task<PartFaces, Never>?

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        backgroundLoopsManager: BackgroundLoopLifetimes = .shared,
        completenessDeps: TelegramBotCompletenessDeps? = nil,
        compactionHandler: TelegramCompaction? = nil,
        partCall: TelegramPartCall? = nil,
        partFace: PartFaces.Call? = nil
    ) {
        self.dataRoot = dataRoot
        self.backgroundLoopsManager = backgroundLoopsManager
        self.completenessDeps = completenessDeps
        self.compactionHandler = compactionHandler
        self.partCall = partCall
        self.partFace = partFace
    }

    func approvalStatus(destination: TelegramDestination) async -> JSONValue {
        do {
            let pending = try await SwiftNativeApprovalInbox(root: dataRoot).list(filter: .pending)
            var count = 0
            for record in pending {
                guard case .object(let payload) = record.payload,
                      case .object(let route)? = payload["telegram"] else { continue }
                func identifier(_ value: JSONValue?) throws -> Int? {
                    switch value {
                    case nil, .null?: return nil
                    case .int(let number)?:
                        if let result = Int(exactly: number) { return result }
                    case .double(let number)?:
                        if let result = Int(exactly: number) { return result }
                    case .string(let string)?:
                        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if value.isEmpty { return nil }
                        if let result = Int(value) { return result }
                    default: break
                    }
                    throw TelegramBotError.underlying("approval destination unavailable")
                }
                guard let chat = try identifier(route["chatId"]) else {
                    throw TelegramBotError.underlying("approval destination unavailable")
                }
                guard chat == destination.chatId else { continue }
                if try identifier(route["threadId"]) == destination.threadId { count += 1 }
            }
            return .object(["status": .string("available"), "count": .int(Int64(count))])
        } catch {
            return .object(["status": .string("unavailable")])
        }
    }

    public func getStatus() async throws -> TelegramStatus {
        let read = await Self.readTransportStatus(dataRoot: dataRoot, manager: backgroundLoopsManager, includeDisconnected: false)
        if let error = read.stateError { throw error }
        var status = read.status
        if case .failure = read.configuration {
            status.lastError = "Saved Telegram settings are invalid or unreadable. Repair or remove telegram/config.json before setting up Telegram again."
        } else if try read.configuration.get() == nil, status.lastError == "No bot token saved — paste one to enable." {
            status.lastError = "No bot token saved - paste one to enable."
        }
        let telegramDir = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        async let receipts = (try? SwiftNativePersistenceCore.tailJSONL(
            telegramDir.appendingPathComponent("receipts.jsonl"),
            limit: 25,
            maxBytes: 1_048_576
        )) ?? []
        async let blocked = (try? SwiftNativePersistenceCore.tailJSONL(
            telegramDir.appendingPathComponent("blocked.jsonl"),
            limit: 25,
            maxBytes: 1_048_576
        )) ?? []
        async let errors = (try? SwiftNativePersistenceCore.tailJSONL(
            telegramDir.appendingPathComponent("errors.jsonl"),
            limit: 25,
            maxBytes: 1_048_576
        )) ?? []
        var extras = status.extras?.objectValue ?? [:]
        extras["receipts"] = .array(await receipts)
        extras["blocked"] = .array(await blocked)
        extras["errors"] = .array(await errors)
        status.extras = .object(extras)
        return status
    }

    /// One checked transport read; callers decide how to present unavailable settings or state.
    public nonisolated static func readTransportStatus(
        dataRoot: URL, manager: BackgroundLoopLifetimes, resolveCredential: Bool = true, includeDisconnected: Bool = true
    ) async -> (status: TelegramStatus, configuration: Result<TelegramConfig?, Error>, stateError: Error?,
                pollBackoffFailures: Int?, lastDiagnosticsClearedAt: String?, voiceTranscription: TelegramVoiceTranscriptionStatus) {
        let configuration = Result { try TelegramConfig.loadSavedConfiguration(
            dataRoot: dataRoot, includeDisconnected: includeDisconnected, resolveCredential: resolveCredential) }
        let cfg = try? configuration.get()
        var stateObj: [String: JSONValue] = [:]
        var stateError: Error?
        do { stateObj = try await TelegramPollLoop.readState(dataRoot: dataRoot) }
        catch { stateError = error }
        if let loop = await manager.loopRunner(loopId: "telegram_poll") as? TelegramPollLoop,
           let polledAt = await loop.lastSuccessfulPollAt {
            stateObj["lastPollAt"] = .string(ISO8601DateFormatter().string(from: polledAt))
        }
        let commandMenu = stateObj["commandMenu"] ?? .object([
            "commandCount": .int(Int64(TelegramCommandRegistry.menuCommandNames.count)),
            "registryVersion": .string(TelegramCommandRegistry.version),
            "synced": .bool(false),
        ])
        let voice = TelegramVoiceTranscriptionStatus(
            enabled: cfg?.voiceTranscriptionEnabled ?? TelegramConfig.defaultVoiceTranscriptionEnabled,
            backend: TelegramVoiceTranscriptionBackends.appleSpeech,
            model: TelegramVoiceTranscriptionBackends.appleSpeechModel,
            maxBytes: cfg?.voiceMaxBytes ?? TelegramConfig.defaultVoiceMaxBytes)
        let extras: [String: JSONValue] = [
            "allowedChatIds": .array((cfg?.allowedChatIds.sorted() ?? []).map { .string(String($0)) }),
            "allowedUserIds": .array((cfg?.allowedUserIds.sorted() ?? []).map { .string(String($0)) }),
            "requireMention": .bool(cfg?.requireMention ?? false),
            "model": cfg?.model.map { .string($0) } ?? .null,
            "reasoningEffort": cfg?.reasoningEffort.map { .string($0) } ?? .null,
            "lastPollAt": stateObj["lastPollAt"] ?? .null,
            "commandMenu": commandMenu,
            "voiceTranscription": .object([
                "enabled": .bool(voice.enabled),
                "backend": .string(voice.backend),
                "model": .string(voice.model),
                "maxBytes": .int(Int64(voice.maxBytes)),
            ]),
        ]
        // Running means the registered loop's runtime is actually running.
        let pollerRunning = await manager.isRunning(loopId: "telegram_poll")
        func integer(_ value: JSONValue?) -> Int? {
            if case .bool(let value)? = value { return value ? 1 : 0 }
            return (value?.integerValue.flatMap(Int.init(exactly:)) ?? value?.stringValue.flatMap(Int.init))
        }
        let status = TelegramStatus(
            enabled: cfg?.enabled ?? false,
            tokenConfigured: cfg?.tokenConfigured ?? false,
            pollerEnabled: pollerRunning,
            lastSeenUpdateId: integer(stateObj["lastSeenUpdateId"]) ?? integer(stateObj["lastUpdateId"]),
            lastSeenAt: stateObj["lastSeenAt"]?.stringValue,
            lastReplyAt: stateObj["lastReplyAt"]?.stringValue,
            lastError: stateError?.localizedDescription ?? stateObj["lastError"]?.stringValue
                ?? (cfg == nil ? "No bot token saved — paste one to enable." : nil),
            extras: .object(extras)
        )
        return (status, configuration, stateError, integer(stateObj["pollBackoffFailures"]),
                stateObj["lastDiagnosticsClearedAt"]?.stringValue, voice)
    }

    public func sendTestMessage(message: String?, chatId: String?) async throws -> TelegramTestResult {
        guard let cfg = TelegramConfig.loadFromDisk(dataRoot: dataRoot),
              !cfg.botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TelegramBotError.notConfigured
        }
        let target: String = {
            if let chatId, !chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return chatId.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let first = cfg.allowedChatIds.sorted().first {
                return String(first)
            }
            return ""
        }()
        guard !target.isEmpty else {
            throw TelegramBotError.notConfigured
        }
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Numeric targets share the chat's send lane; usernames send directly.
            return try await _tgRetryAfterFloodControl(chatId: Int(target)) {
                let result = try await TelegramPollLoop._tgPostJSON(token: cfg.botToken, method: "sendMessage",
                    resultType: TelegramTestResult.self) {
                    try JSONSerialization.data(withJSONObject: [
                        "chat_id": target,
                        "text": text?.isEmpty == false ? text! : "NativeAgent Telegram test reply: online."
                    ])
                }
                return result.value
            }
        } catch let failure as TelegramAPIFailure {
            throw failure
        } catch let error as TelegramBotError {
            throw error
        } catch {
            throw TelegramBotError.underlying(error.localizedDescription)
        }
    }

    public func clearLogs() async throws {
        let telegramDir = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: telegramDir, withIntermediateDirectories: true)
        // Clear errors.jsonl and its rotation backup errors.jsonl.1 under the same lock.
        for name in ["logs.jsonl", "receipts.jsonl", "blocked.jsonl", "errors.jsonl"] {
            let path = telegramDir.appendingPathComponent(name)
            try await SwiftNativePersistenceCore.withFileLock(path) {
                if FileManager.default.fileExists(atPath: path.path) {
                    try FileManager.default.removeItem(at: path)
                }
                if name == "errors.jsonl" {
                    let backup = path.appendingPathExtension("1")
                    if FileManager.default.fileExists(atPath: backup.path) {
                        try FileManager.default.removeItem(at: backup)
                    }
                }
            }
        }
    }
}

/// getUpdates owns its connection pool and replaces it after two consecutive timeouts.
public actor TelegramLongPollSession {
    /// Every successful response wakes health readers; disk checkpoints retain their cadence.
    public static let successfulPoll = Notification.Name("TelegramLongPollSession.successfulPoll")
    private(set) var current = URLSession(configuration: .ephemeral)
    private var consecutiveTimeouts = 0
    public private(set) var lastSuccessfulPollAt: Date?
    private var lastHealthCheckpointAt: Date?

    public init() {}

    func recordResponse() { consecutiveTimeouts = 0 }

    func recordSuccessfulPoll() -> Bool {
        let now = Date()
        lastSuccessfulPollAt = now
        NotificationCenter.default.post(name: Self.successfulPoll, object: nil)
        if let lastHealthCheckpointAt,
           now.timeIntervalSince(lastHealthCheckpointAt) < SwiftNativeLoopScheduler.healthCheckpointInterval { return false }
        lastHealthCheckpointAt = now
        return true
    }

    func recordTimeout() {
        consecutiveTimeouts += 1
        guard consecutiveTimeouts >= 2 else { return }
        current.invalidateAndCancel()
        current = URLSession(configuration: .ephemeral)
        consecutiveTimeouts = 0
    }
}

extension SwiftNativeTelegramBot {
    public func longPoll(
        token: String,
        offset: Int,
        timeoutSeconds: Int = 25,
        session: TelegramLongPollSession
    ) async throws -> TelegramPollResult {
        guard let url = _tgBuildBotURL(
            token: token,
            method: "getUpdates",
            queryItems: [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "timeout", value: String(timeoutSeconds)),
            ]
        ) else {
            throw TelegramBotError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = max(TimeInterval(timeoutSeconds + 10), 35)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.current.data(for: req)
            await session.recordResponse()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // Preserve URLSession cancellation so shutdown is not reported as an outage.
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .timedOut { await session.recordTimeout() }
            // Preserve the transport error cause for diagnosis and offline classification.
            throw TelegramBotError.underlying(String(describing: error))
        }
        let updates: [TelegramUpdate]
        do {
            updates = try TelegramPollLoop._tgValidateResponse(data, response: response,
                operation: "getUpdates", resultType: [TelegramUpdate].self).value
        } catch let failure as TelegramAPIFailure {
            if failure.httpStatus == 401 { throw TelegramBotError.notConfigured }
            if let status = failure.httpStatus, (500..<600).contains(status) {
                throw TelegramBotError.underlying("server status \(status)")
            }
            if failure.kind == .httpStatus, let status = failure.httpStatus {
                throw TelegramBotError.invalidResponse(status: status)
            }
            throw failure
        }
        guard updates.allSatisfy({ $0.updateId >= 0 && $0.nextOffset != nil }) else {
            throw TelegramBotError.underlying("telegram: invalid upstream update ID")
        }
        let nextOffset: Int
        nextOffset = updates.compactMap(\.nextOffset).max() ?? offset
        return TelegramPollResult(updates: updates, nextOffset: nextOffset)
    }
}
