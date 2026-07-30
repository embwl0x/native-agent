import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    func startTypingHeartbeat(chatId: Int) async -> Task<Void, Never>? {
        do {
            try await sendChatAction(token, chatId, "typing")
        } catch {
            FileHandle.standardError.write(
                Data("TelegramPollLoop: sendChatAction failed for chat \(chatId): \(Self._tgRedactToken(String(describing: error)))\n".utf8)
            )
        }
        guard typingRefreshNanoseconds > 0 else { return nil }
        let token = self.token
        let sendChatAction = self.sendChatAction
        let delay = typingRefreshNanoseconds
        return Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                do {
                    try await sendChatAction(token, chatId, "typing")
                } catch {
                    FileHandle.standardError.write(
                        Data("TelegramPollLoop: sendChatAction refresh failed for chat \(chatId): \(Self._tgRedactToken(String(describing: error)))\n".utf8)
                    )
                }
            }
        }
    }

    func makeProgressSink(chatId: Int, draft: TelegramDraftStreamer? = nil) -> TelegramChatProgressSink {
        let state = TelegramProgressMessageState(maxMessages: 8)
        let token = self.token
        let sendMessage = self.sendMessage
        return { event in
            // chat-smoothness phase 5: accumulated reply text feeds the
            // growing draft (throttled message EDITS), never the discrete
            // progress-message path below.
            if case .textDelta(let accumulated) = event {
                await draft?.onDelta(accumulated)
                return
            }
            guard let text = Self.progressMessage(for: event) else { return }
            // Heartbeats throttle through the per-turn cap; everything else that
            // is a notice (start + terminal notices like invoke_timeout) ALWAYS
            // sends — a dropped timeout is the silent hang we're preventing.
            let alwaysSend: Bool = {
                if case .notice(let kind, _) = event { return kind != "invoke_progress" }
                return false
            }()
            if !alwaysSend {
                let shouldSend = await state.shouldSend(text)
                guard shouldSend else { return }
            }
            do {
                try await sendMessage(token, chatId, text)
            } catch {
                FileHandle.standardError.write(
                    Data("TelegramPollLoop: progress message send failed for chat \(chatId): \(Self._tgRedactToken(String(describing: error)))\n".utf8)
                )
            }
        }
    }

    static func progressMessage(for event: TelegramChatProgressEvent) -> String? {
        switch event {
        case .status(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .notice(_, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .toolResult:
            return nil
        case .textDelta:
            return nil  // draft-streamer lane, never a discrete message
        case .toolUse(let name, let input):
            let lower = name.lowercased()
            switch lower {
            case "read_skill":
                if let skill = progressInputString(input, keys: ["name", "skill", "id"]) {
                    return "Loading skill: \(skill)"
                }
                return "Loading skill"
            case "list_skills":
                return "Checking skills"
            case "tool_load":
                if let tool = progressInputString(input, keys: ["name", "tool", "id"]) {
                    return "Loading tool: \(tool)"
                }
                return "Loading tool"
            case "tool_catalog", "list_tools":
                return "Checking tools"
            case "git_log":
                return "Checking recent commits"
            case "git_status":
                return "Checking repo status"
            case "git_diff":
                return "Checking repo diff"
            case "repo_dirty_summary":
                return "Checking repo state"
            case "read_file", "file_excerpt":
                return "Reading file"
            case "list_dir":
                return "Listing folder"
            case "recall_memory", "recall_search":
                return "Searching memory"
            case "search_kg":
                return "Searching knowledge graph"
            default:
                return "Using tool: \(name)"
            }
        }
    }

    static func progressInputString(_ input: JSONValue?, keys: [String]) -> String? {
        guard case .object(let obj)? = input else { return nil }
        for key in keys {
            if case .string(let value)? = obj[key] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    func runChatHandlerWithRetry(
        chatId: Int,
        text: String,
        attachments: [TelegramMediaAttachment] = [],
        progress: @escaping TelegramChatProgressSink,
        replyTo: TelegramReplyContext? = nil,
        fromUserId: Int? = nil,
        suppressUserAppend: Bool = false
    ) async throws -> String {
        let totalAttempts = max(1, chatRetryAttempts + 1)
        var lastError: Error?
        for attempt in 0..<totalAttempts {
            let context = TelegramChatAttemptContext(
                attemptIndex: attempt,
                totalAttempts: totalAttempts,
                replyTo: replyTo,
                fromUserId: fromUserId,
                suppressUserAppend: suppressUserAppend
            )
            do {
                // Prefer the attachment-aware handler when staged images exist
                // (telegram-vision-in) so the bytes reach the model. The
                // attachment handler is also used for plain text when it's the
                // only handler wired.
                if let attachmentChatHandler {
                    return try await attachmentChatHandler(chatId, text, attachments, progress, context)
                }
                // A staged image must NEVER silently fall through to a
                // text-only handler — the model would answer the caption
                // blind, exactly the failure the vision-in port removes
                // (gpt-5.5 review). Tripwire + honest reply instead.
                if !attachments.isEmpty {
                    await emitAttachmentDroppedTrace(
                        kind: "image",
                        reason: "no attachment-capable chat handler wired",
                        chatId: chatId, updateId: 0)
                    return "(I received your image but this bot configuration "
                        + "has no vision-capable handler wired — the image was "
                        + "not processed.)"
                }
                if let progressChatHandler {
                    return try await progressChatHandler(chatId, text, progress, context)
                }
                if let chatHandler {
                    return try await chatHandler(chatId, text)
                }
                throw TelegramBotError.unavailable
            } catch {
                lastError = error
                guard attempt + 1 < totalAttempts, Self.isRetryableChatHandlerError(error) else {
                    throw error
                }
                FileHandle.standardError.write(
                    Data("TelegramPollLoop: retrying chat handler after transient failure: \(Self._tgRedactToken(String(describing: error)))\n".utf8)
                )
                await progress(.status(text: "Draft stalled; retrying"))
                await writeStatePatch([
                    "lastChatRetryAt": .string(_tgNowString()),
                    "lastChatRetryFailedAttempt": .int(Int64(attempt + 1)),
                    "lastChatRetryNextAttempt": .int(Int64(attempt + 2)),
                    "lastChatRetrySuppressUserAppend": .bool(true),
                    "lastChatRetryError": .string(String(describing: error)),
                ])
                // A3.4: honor a provider Retry-After when the failure carried
                // one (the transient message embeds ` [retry-after=Ns]`). Wait
                // max(ladder backoff, Retry-After) so we neither hammer a 429
                // before its window nor shorten the ladder's own floor.
                let delayNanos = max(
                    chatRetryDelayNanoseconds,
                    Self.retryAfterNanoseconds(for: error)
                )
                if delayNanos > 0 {
                    try await Task.sleep(nanoseconds: delayNanos)
                }
            }
        }
        throw lastError ?? TelegramBotError.unavailable
    }

    /// A3.4: extract a provider-honored Retry-After (in nanoseconds) from an
    /// error whose text carries the ` [retry-after=Ns]` sentinel the provider
    /// adapters embed on a 429 with a Retry-After header. The surface wait is
    /// capped at 300s so a hostile/absurd header can't wedge the loop.
    static func retryAfterNanoseconds(for error: Error) -> UInt64 {
        let description = [
            (error as? LocalizedError)?.errorDescription,
            String(describing: error)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        guard let range = description.range(
            of: "retry-after=[0-9]+s",
            options: .regularExpression
        ) else { return 0 }
        let token = description[range]                        // "retry-after=30s"
        let digits = token.dropFirst("retry-after=".count).dropLast()
        guard let secs = Int(digits), secs > 0 else { return 0 }
        return UInt64(min(secs, 300)) * 1_000_000_000
    }

    static func isRetryableChatHandlerError(_ error: Error) -> Bool {
        let description = [
            (error as? LocalizedError)?.errorDescription,
            String(describing: error)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        // A provider failure AFTER tool dispatches already ran is marked by
        // ChatOrchestration (ProviderErrorAfterToolEffects). Replaying the
        // whole handler would re-execute those tools — never retryable, no
        // matter which transient phrase the inner error also matches
        // (gpt-5.5 fix round 2026-07-18, HIGH).
        if description.contains("whole-turn retry unsafe") {
            return false
        }

        let retryablePhrases = [
            "llm: transient",
            "connection refused",
            "cannot connect",
            "network connection was lost",
            "code=-1001",
            "timed out",
            "upstream connect",
            "disconnect/reset",
            "transport failure",
            "server status 5",
            "status 502",
            "status 503",
            "status 504",
            "status 529",
            "rate limited",
            "rate limit",
            "rate_limit",
            "too many requests",
            "overloaded",
            "overloaded_error",
            "invalid response status 429",
            "invalid response status 529",
            "unavailable"
        ]
        return retryablePhrases.contains { description.contains($0) }
    }

    static func chatErrorNotice(for error: Error) -> String {
        if let notice = providerUsageNotice(for: error) {
            return notice
        }
        if isRetryableChatHandlerError(error) {
            return "(drafting stalled; try again in a moment)"
        }
        return "(internal error while drafting a reply)"
    }

    static func providerUsageNotice(for error: Error) -> String? {
        let description = [
            (error as? LocalizedError)?.errorDescription,
            String(describing: error)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        let looksLikeUsageFailure =
            description.contains("out of extra usage")
            || description.contains("usage is exhausted")
            || description.contains("usage exhausted")
            || description.contains("quota exceeded")
            || description.contains("insufficient_quota")
            || description.contains("oauth_direct exhausted")
            || description.contains("usage limit for this billing cycle")
            || description.contains("reached your usage limit")

        guard looksLikeUsageFailure else { return nil }
        if description.contains("kimi") {
            return "(Kimi Code usage limit reached for this billing cycle. "
                + "Switch provider with /provider, buy extra usage at "
                + "kimi.com/membership, or wait for the cycle refresh.)"
        }
        if description.contains("anthropic") || description.contains("claude") {
            return "(Claude OAuth usage is exhausted. Switch provider with /provider or add more at claude.ai/settings/usage.)"
        }
        if description.contains("openai") || description.contains("chatgpt") {
            return "(OpenAI OAuth usage is exhausted. Switch provider with /provider or refresh/add ChatGPT usage.)"
        }
        return "(Provider usage is exhausted. Switch provider with /provider or update that provider's usage limit.)"
    }
}
