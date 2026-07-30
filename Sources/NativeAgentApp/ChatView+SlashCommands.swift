import Foundation
import SwiftUI
import NativeAgentShared

extension ChatView {
    func send() {
        guard !isCapturing else {
            showToast("Screen capture is still in progress")
            return
        }
        let attachments = pendingAttachments
        let message = text
        let composerSessionId = appModel.activeChatSessionId
        // PATCH-2026-05-08: review-fix-B If the user typed a /command and hit
        // send (instead of clicking from the popover), dispatch it instead of
        // shipping it as a chat message. Otherwise `/model gpt-5.5` would go
        // to the LLM as text, which the agent would echo back at us.
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // B.2: only intercept known slash commands; /tmp/foo or any other
        // non-command text falls through to regular chat send.
        if trimmed.hasPrefix("/") {
            let firstToken = trimmed.dropFirst().components(separatedBy: .whitespacesAndNewlines).first ?? ""
            let firstTokenLC = firstToken.lowercased()
            if knownSlashCommands.contains(firstTokenLC) {
                handleSlashCommand(String(trimmed.dropFirst()))
                // handleSlashCommand clears `text` itself; clear pending attachments too
                pendingAttachments = []
                return
            }
            // Phase 13 (item 7): also match dynamically-registered capability tools.
            // If the user typed /recall_search, /workspace_list, or any other tool
            // exposed by capabilitiesStore, dispatch it instead of falling through to chat.
            let dynamicTools = capabilitiesStore.slashCommandTools()
            if dynamicTools.contains(where: { $0.name == firstTokenLC }) {
                handleSlashCommand(String(trimmed.dropFirst()))
                pendingAttachments = []
                return
            }
        }
        Task { @MainActor in
            let acceptance = await appModel.startActiveChatTurn(
                message,
                attachments: attachments,
                expectedSessionId: composerSessionId
            )
            switch acceptance {
            case .accepted(let acceptedSessionId), .queued(let acceptedSessionId, _):
                // The acceptance path can suspend behind a pending Stop write.
                // Only clear the exact composer snapshot that was accepted;
                // preserve any edits or attachments added while it waited.
                guard appModel.activeChatSessionId == acceptedSessionId,
                      composerSessionId == acceptedSessionId,
                      text == message,
                      pendingAttachments == attachments
                else { return }
                text = ""
                // H5: the composer's draft is view-local @State now, so clearing
                // `text` does not clear the persisted copy automatically.
                appModel.commitChatDraft("", sessionId: acceptedSessionId)
                pendingAttachments = []
                scrollCoordinator.forceFollow()
            case .rejected(let failureMessage):
                showToast(failureMessage)
            }
        }
    }

    // PATCH-2026-05-08: wave2-chat-ux — slash command handler
    func handleSlashCommand(_ raw: String) {
        let parts = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let cmd = parts.first?.lowercased() ?? ""
        let arg = parts.dropFirst().joined(separator: " ")
        text = ""
        appModel.commitChatDraft("", sessionId: appModel.activeChatSessionId)
        switch cmd {
        case "clear":
            showClearConfirm = true
        case "compact":
            // ui-honesty 2026-06-10: compactActiveChat is fire-and-forget void
            // and reports via appModel.statusText ("Session compacted" /
            // "Compact failed: …"). Await it and toast the RESULT — previously
            // a failed compact was completely silent on this surface.
            if appModel.activeChatSessionId.isEmpty {
                showToast("No active session to compact")
            } else {
                Task {
                    await appModel.compactActiveChat()
                    await MainActor.run { showToast(appModel.statusText) }
                }
            }
        case "model":
            if !arg.isEmpty {
                appModel.chatModel = arg
                Task { @MainActor in await appModel.saveChatBrainDefaults() }
            }
        case "think":
            let effort = arg.lowercased()
            let valid = reasoningOptions(from: appModel.modelCatalog, model: appModel.chatModel)
                .map(\.id)
            guard valid.contains(effort) else {
                showToast("Choose a supported level: \(valid.joined(separator: ", "))")
                return
            }
            appModel.chatReasoningEffort = effort
            Task { @MainActor in await appModel.saveChatBrainDefaults() }
        case "fast":
            guard appModel.chatModel.lowercased().hasPrefix("gpt-") else {
                showToast("Fast mode is only available for GPT models")
                return
            }
            switch arg.lowercased() {
            case "on": appModel.chatFastMode = true
            case "off": appModel.chatFastMode = false
            default:
                showToast("Usage: /fast <on|off>")
                return
            }
            Task { @MainActor in await appModel.saveChatBrainDefaults() }
        case "persona":
            if !arg.isEmpty { appModel.chatPersona = arg }
        case "remember":
            guard !arg.isEmpty else { showToast("/remember requires a fact"); return }
            // ui-honesty 2026-06-10: previously fired-and-forgot then toasted
            // success unconditionally. addMemoryFact is void and reports via
            // statusText ("Memory saved" / "Remember failed: …") — await it
            // and toast the actual result.
            Task {
                await appModel.addMemoryFact(arg)
                await MainActor.run { showToast(appModel.statusText) }
            }
        case "note":
            // PATCH-Phase1a-dispatcher: /note <text> — POST /v1/notes → Dispatcher.run(commit_memory)
            // Both /note and the agent's commit_memory tool call go through the same Dispatcher.run() path.
            guard !arg.isEmpty else { showToast("/note requires some text"); return }
            // ui-honesty 2026-06-10: same as /remember — toast the result
            // ("Note committed" / "Note failed: …"), not a blind success.
            Task {
                await appModel.addNote(arg)
                await MainActor.run { showToast(appModel.statusText) }
            }
        case "scratch":
            // PATCH-phase-3c: /scratch <key> <value...> — POST /v1/scratch → Dispatcher.run(scratchpad_write)
            // First whitespace-separated token is the key; everything after is the value string.
            let scratchParts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard scratchParts.count == 2 else {
                showToast("/scratch requires a key and a value: /scratch <key> <value>")
                return
            }
            let scratchKey = scratchParts[0]
            let scratchValue = scratchParts[1]
            showToast("Writing scratch \(scratchKey)...")
            Task {
                let ok = await appModel.writeScratch(key: scratchKey, value: scratchValue)
                await MainActor.run {
                    showToast(ok ? "Scratch \(scratchKey) set" : "Scratch \(scratchKey) failed")
                }
            }
        case "help":
            let helpMsg = ChatMessage(role: "system", content:
                "Slash commands:\n/clear — wipe session messages\n/compact — compact context\n/model <id> — set model\n/think <low|medium|high|xhigh|max|ultra> — reasoning effort\n/fast <on|off> — GPT priority processing\n/persona <name> — set persona\n/remember <fact> — save a memory\n/note <text> — commit a note to agent memory\n/scratch <key> <value> — write ephemeral session scratchpad key\n/tools — open Tools inside Skills & Tools\n\(UserDefaults.standard.bool(forKey: "showDeveloperSurfaces") ? "/nextgen — open Capabilities\n" : "")/export — export this chat to Downloads\n/help — this list\n\nAvailable registered tool names also work as slash commands."
            )
            appModel.chatMessages.append(helpMsg)
        // One tool catalog owner: /tools opens the Tools page in the shared tab.
        case "tools":
            NativeAgentAppCoordinator.shared.request(.skillsTools(.tools))
        // PATCH-2026-05-09: nextgen-surface — navigate sidebar to Capabilities (NextGen panel)
        case "nextgen":
            NativeAgentAppCoordinator.shared.request(.sidebar(.capabilities))
            showToast("Navigating to NextGen in Capabilities\u{2026}")
        // PATCH-2026-06-06: chat-upgrades — /export dumps the current session
        // transcript as Markdown into ~/Downloads.
        case "export":
            exportCurrentChatToDownloads()
        default:
            // PATCH-Phase7b: if cmd matches a known, available capability tool → dispatch it.
            if let cap = capabilitiesStore.tools.first(where: { $0.name == cmd }), cap.availableNow {
                Task {
                    await dispatchSlashCommandTool(cap: cap, freeText: arg)
                }
            } else if capabilitiesStore.tools.contains(where: { $0.name == cmd }) {
                // Tool exists but isn't available (blocked / needs approval / wrong provider).
                showToast("/\(cmd) is not available now — check tool status in /tools")
            } else {
                showToast("Unknown command /\(cmd). Type /help for the list.")
            }
        }
    }

    // PATCH-Phase7b: resolve arg plan and dispatch the tool, rendering the receipt inline.
    @MainActor
    func dispatchSlashCommandTool(cap: ToolCapability, freeText: String) async {
        let plan = capabilitiesStore.planDispatch(toolName: cap.name, freeText: freeText)
            ?? DispatchArgPlan(tool: cap, mode: .zeroArgs, prefilled: [:])

        switch plan.mode {
        case .zeroArgs:
            await runDispatchAndRenderReceipt(tool: cap.name, input: [:])

        case .singleStringArg(let field):
            let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Need the user to supply the value — fall back to a form.
                currentDispatchPlan = plan
                showToolInputForm = true
            } else {
                await runDispatchAndRenderReceipt(tool: cap.name, input: [field: trimmed])
            }

        case .formNeeded:
            currentDispatchPlan = plan
            showToolInputForm = true
        }
    }

    // PATCH-Phase7b: POST to /v1/dispatch, then append a system-style receipt message.
    // `inputJSON` is the pre-serialized JSON Data so we don't pass [String: Any] across
    // the actor boundary (Swift 6 Sendability).
    @MainActor
    func runDispatchAndRenderReceipt(tool: String, input: [String: Any]) async {
        let sessionId: String? = appModel.activeChatSessionId.isEmpty ? nil : appModel.activeChatSessionId
        // Serialize input on the MainActor before we cross the concurrency boundary.
        let inputSnapshot = input
        let inputForDisplay = input  // kept for receipt rendering on MainActor
        // Optimistic pending message so the user sees immediate feedback.
        let pendingContent = "⏳ Dispatching **\(tool)**…"
        let pending = ChatMessage(role: "system", content: pendingContent)
        appModel.chatMessages.append(pending)

        // Serialize the dict to Data here (on MainActor) so the nonisolated dispatchTool
        // method receives Sendable types only.
        guard let bodyData = try? JSONSerialization.data(withJSONObject: inputSnapshot) else {
            appModel.chatMessages.removeAll { $0.id == pending.id }
            appModel.chatMessages.append(ChatMessage(role: "system",
                content: "❌ **\(tool)** dispatch failed: could not serialize input"))
            return
        }

        do {
            let result = try await appModel.dispatchToolData(tool: tool, inputData: bodyData, sessionId: sessionId)
            // Remove the pending placeholder.
            appModel.chatMessages.removeAll { $0.id == pending.id }
            // Render the receipt.
            let receipt = buildReceiptMessage(result: result, tool: tool, input: inputForDisplay)
            appModel.chatMessages.append(receipt)
        } catch {
            appModel.chatMessages.removeAll { $0.id == pending.id }
            let errMsg = ChatMessage(role: "system", content:
                "❌ **\(tool)** dispatch failed: \(error.localizedDescription)"
            )
            appModel.chatMessages.append(errMsg)
        }
    }

    // Phase 13 (item 8): Sendable-safe dispatch that accepts pre-serialized Data.
    // Called from ToolInputForm's onSubmit closure where [String: Any] is serialized
    // to Data before crossing the Task actor boundary, satisfying Swift 6 strict concurrency.
    @MainActor
    func runDispatchAndRenderReceiptData(tool: String, inputData: Data) async {
        let sessionId: String? = appModel.activeChatSessionId.isEmpty ? nil : appModel.activeChatSessionId
        let pendingContent = "⏳ Dispatching **\(tool)**…"
        let pending = ChatMessage(role: "system", content: pendingContent)
        appModel.chatMessages.append(pending)
        do {
            let result = try await appModel.dispatchToolData(tool: tool, inputData: inputData, sessionId: sessionId)
            appModel.chatMessages.removeAll { $0.id == pending.id }
            // Re-hydrate for display only — failure is non-fatal (fall back to empty input).
            let inputForDisplay = (try? JSONSerialization.jsonObject(with: inputData) as? [String: Any]) ?? [:]
            let receipt = buildReceiptMessage(result: result, tool: tool, input: inputForDisplay)
            appModel.chatMessages.append(receipt)
        } catch {
            appModel.chatMessages.removeAll { $0.id == pending.id }
            appModel.chatMessages.append(ChatMessage(role: "system",
                content: "❌ **\(tool)** dispatch failed: \(error.localizedDescription)"))
        }
    }

    // PATCH-Phase7b: Build a system-role ChatMessage that renders the dispatch receipt.
    func buildReceiptMessage(result: DispatchResult, tool: String, input: [String: Any]) -> ChatMessage {
        // Status badge
        let badge: String
        switch result.status.lowercased() {
        case "ok":               badge = "✅"
        case "pending_approval": badge = "⏳"
        case "failed":           badge = "❌"
        case "blocked":          badge = "🚫"
        case "dry_run":          badge = "🔍"
        default:                 badge = "•"
        }

        // Arg summary (max 80 chars)
        var argSummary = ""
        if !input.isEmpty {
            let parts = input.map { k, v in "\(k)=\(v)" }.joined(separator: " ")
            argSummary = "(\(parts.truncated(to: 80, keeping: 77)))"
        }

        // Output preview (max 400 chars)
        var outputBlock = ""
        if result.ok, let out = result.output {
            let preview = out.rawString.count > 400
                ? String(out.rawString.prefix(400)) + "\n…(truncated)"
                : out.rawString
            outputBlock = "\n```\n\(preview)\n```"
        }

        // Error detail
        var errorBlock = ""
        if let err = result.error {
            errorBlock = "\n`\(err.code)` \(err.message)"
        }

        let trace = "\n*\(result.durationMs)ms · autonomy: \(result.effectiveAutonomy)*"

        let content = "\(badge) **\(tool)**\(argSummary)\(outputBlock)\(errorBlock)\(trace)"
        return ChatMessage(role: "system", content: content)
    }
}
