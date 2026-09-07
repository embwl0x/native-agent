import Foundation
import SwiftUI
import NativeAgentShared

extension ChatView {
    func send() {
        guard !isSubmittingSend else { return }
        guard !isCapturing else {
            showToast("Screen capture is still in progress")
            return
        }
        let attachments = pendingAttachments
        let message = text
        // 2026-09-06: the snapshot's own edit time, captured BEFORE the box is
        // cleared (clearing `text` stamps a fresh one). The send-clear carries
        // it so sending older text here cannot delete a newer unsent edit made
        // in a detached panel on the same conversation.
        let messageEditedAt = draftEditedAt
        let composerSessionId = appModel.activeChatSessionId
        // PATCH-2026-05-08: review-fix-B If the user typed a /command and hit
        // send (instead of clicking from the popover), dispatch it instead of
        // shipping it as a chat message. Otherwise `/model gpt-5.5` would go
        // to the LLM as text, which the agent would echo back at us.
        // B.2: only intercept known slash commands; /tmp/foo or any other
        // non-command text falls through to regular chat send.
        //
        // Phase 13 (item 7): dynamically-registered capability tools count too
        // — /recall_search, /workspace_list and friends dispatch rather than
        // reaching the LLM as text.
        //
        // D2 (2026-08-28): the prefix check itself now lives in
        // ChatSlashCommandRouting so the detached panel makes the same call.
        switch ChatSlashCommandRouting.decide(
            text: message,
            dynamicToolNames: capabilitiesStore.slashCommandNames,
            supportsDispatch: true
        ) {
        case .dispatch(let commandLine):
            // 2026-09-06: this used to drop the pending attachments on the
            // floor. A slash command sends nothing, so it consumes nothing —
            // and cancelling the /clear confirmation left the attachments
            // already gone. Picking the same command from the popover never
            // came through here, so mouse and Return also disagreed.
            handleSlashCommand(commandLine)
            return
        case .unsupportedHere(let command):
            // Unreachable with supportsDispatch: true; kept exhaustive so a new
            // decision case cannot silently fall through to a chat send.
            showToast(ChatSlashCommandRouting.unsupportedMessage(command: command))
            return
        case .sendAsMessage:
            break
        }
        isSubmittingSend = true
        Task { @MainActor in
            defer { isSubmittingSend = false }
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
                appModel.clearChatDraftAfterSend(
                    message,
                    sessionId: acceptedSessionId,
                    editedAt: messageEditedAt
                )
                draftAdoptedText = ""
                pendingAttachments = []
                // 2026-09-06: the composer's words have been sent, but the
                // recognizer's transcript is cumulative and its pre-dictation
                // base still pointed at them — the next update wrote the whole
                // already-sent phrase back into the empty box.
                endDictation()
                transcriptLatestRequest &+= 1
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
        // 2026-09-06: the composer is cleared at the END, on the paths that
        // actually consume the command. Clearing here wiped what the person
        // typed before the arguments were even checked, so `/think bogus`
        // answered "choose a supported level" with an empty box to retype in.
        let showDeveloperSurfaces = NativeAgentShellPreference.developerSurfacesShown(
            UserDefaults.standard.bool(forKey: "showDeveloperSurfaces")
        )
        let builtIn = ChatSlashCommandRegistry.descriptor(named: cmd)
        if builtIn?.developerOnly == true, !showDeveloperSurfaces {
            showToast("Unknown command /\(cmd). Type /help for the list.")
            return
        }
        switch builtIn?.route {
        case .clear:
            clearConfirmation.request()
        case .compact:
            // Await and present the typed mutation result so a failed compact
            // is never reported as success on this surface.
            if appModel.activeChatSessionId.isEmpty {
                showToast("No active session to compact")
            } else {
                Task {
                    let result = await appModel.compactActiveChat()
                    await MainActor.run { showToast(result.userMessage) }
                }
            }
        case .model:
            if !arg.isEmpty {
                appModel.chatModel = arg
                Task { @MainActor in
                    let result = await appModel.saveChatBrainDefaults()
                    showToast(result.userMessage)
                }
            }
        case .think:
            let effort = arg.lowercased()
            let valid = reasoningOptions(from: appModel.modelCatalog, model: appModel.chatModel)
                .map(\.id)
            guard valid.contains(effort) else {
                showToast("Choose a supported level: \(valid.joined(separator: ", "))")
                return
            }
            appModel.chatReasoningEffort = effort
            Task { @MainActor in
                let result = await appModel.saveChatBrainDefaults()
                showToast(result.userMessage)
            }
        case .fast:
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
            Task { @MainActor in
                let result = await appModel.saveChatBrainDefaults()
                showToast(result.userMessage)
            }
        case .persona:
            if !arg.isEmpty { appModel.chatPersona = arg }
        case .remember:
            guard !arg.isEmpty else { showToast("/remember requires a fact"); return }
            Task {
                let result = await appModel.addMemoryFact(arg)
                await MainActor.run { showToast(result.userMessage) }
            }
        case .note:
            // Manual /note is an intentional direct MemoryV2 lane. Provider
            // tool calls use commit_memory through the shared chat dispatcher.
            guard !arg.isEmpty else { showToast("/note requires some text"); return }
            Task {
                let result = await appModel.addNote(arg)
                await MainActor.run { showToast(result.userMessage) }
            }
        case .scratch:
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
                let result = await appModel.writeScratch(key: scratchKey, value: scratchValue)
                await MainActor.run {
                    showToast(result.userMessage)
                }
            }
        case .help:
            let helpMsg = ChatMessage(role: "system", content:
                ChatSlashCommandRegistry.helpText(showDeveloperSurfaces: showDeveloperSurfaces)
            )
            appModel.chatMessages.append(helpMsg)
        // One tool catalog owner: /tools opens the Tools page in the shared tab.
        case .tools:
            NativeAgentAppCoordinator.shared.request(.skillsTools(.tools))
        // PATCH-2026-05-09: nextgen-surface — navigate sidebar to Capabilities (NextGen panel)
        case .nextgen:
            NativeAgentAppCoordinator.shared.request(.sidebar(.capabilities))
            showToast("Navigating to NextGen in Capabilities\u{2026}")
        // PATCH-2026-06-06: chat-upgrades — /export dumps the current session
        // transcript as Markdown into ~/Downloads.
        case .export:
            exportCurrentChatToDownloads()
        case nil:
            // PATCH-Phase7b: if cmd matches a known, available capability tool → dispatch it.
            if let cap = capabilitiesStore.tools.first(where: { $0.name == cmd }), cap.availableNow {
                // 2026-09-06: the command belongs to the conversation it was
                // typed into. The task below suspends, so reading the active
                // session inside it filed the placeholder and the receipt
                // wherever the person had moved to by then.
                let commandSessionId = appModel.activeChatSessionId
                Task {
                    await dispatchSlashCommandTool(
                        cap: cap,
                        freeText: arg,
                        sessionId: commandSessionId
                    )
                }
            } else if capabilitiesStore.tools.contains(where: { $0.name == cmd }) {
                // Tool exists but isn't available (blocked / needs approval / wrong provider).
                showToast("/\(cmd) is not available now — check tool status in /tools")
                return
            } else {
                showToast("Unknown command /\(cmd). Type /help for the list.")
                return
            }
        }
        // The command was taken. Only now does the composer lose its text.
        text = ""
        appModel.commitChatDraft("", sessionId: appModel.activeChatSessionId)
        draftAdoptedText = ""
    }

    // PATCH-Phase7b: resolve arg plan and dispatch the tool, rendering the receipt inline.
    @MainActor
    func dispatchSlashCommandTool(cap: ToolCapability, freeText: String, sessionId: String) async {
        var plan = capabilitiesStore.planDispatch(toolName: cap.name, freeText: freeText)
            ?? DispatchArgPlan(tool: cap, mode: .zeroArgs, prefilled: [:])
        // Carried through the form sheet so a submission made after a session
        // switch still lands where the command was typed (2026-09-06).
        plan.sessionId = sessionId

        switch plan.mode {
        case .zeroArgs:
            await runDispatchAndRenderReceipt(tool: cap.name, input: [:], sessionId: sessionId)

        case .singleStringArg(let field):
            let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Need the user to supply the value — fall back to a form.
                currentDispatchPlan = plan
                showToolInputForm = true
            } else {
                await runDispatchAndRenderReceipt(
                    tool: cap.name,
                    input: [field: trimmed],
                    sessionId: sessionId
                )
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
    func runDispatchAndRenderReceipt(tool: String, input: [String: Any], sessionId targetSessionId: String) async {
        let sessionId: String? = targetSessionId.isEmpty ? nil : targetSessionId
        // Serialize input on the MainActor before we cross the concurrency boundary.
        let inputSnapshot = input
        let inputForDisplay = input  // kept for receipt rendering on MainActor
        // Optimistic pending message so the user sees immediate feedback.
        let pendingContent = "⏳ Dispatching **\(tool)**…"
        let pending = ChatMessage(role: "system", content: pendingContent)
        appendDispatchMessage(pending, to: targetSessionId)

        // Serialize the dict to Data here (on MainActor) so the nonisolated dispatchToolData
        // method receives Sendable types only.
        guard let bodyData = try? JSONSerialization.data(withJSONObject: inputSnapshot) else {
            replaceDispatchPlaceholder(
                pending.id,
                with: ChatMessage(role: "system",
                    content: "❌ **\(tool)** dispatch failed: could not serialize input"),
                in: targetSessionId
            )
            return
        }

        do {
            let result = try await appModel.dispatchToolData(tool: tool, inputData: bodyData, sessionId: sessionId)
            // Render the receipt where the command was typed.
            let receipt = buildReceiptMessage(result: result, tool: tool, input: inputForDisplay)
            replaceDispatchPlaceholder(pending.id, with: receipt, in: targetSessionId)
        } catch {
            let errMsg = ChatMessage(role: "system", content:
                "❌ **\(tool)** dispatch failed: \(error.localizedDescription)"
            )
            replaceDispatchPlaceholder(pending.id, with: errMsg, in: targetSessionId)
        }
    }

    // 2026-09-06: a dispatch that finishes after the person opens another
    // conversation used to land there — `appModel.chatMessages` writes
    // whichever session is active NOW, so the receipt went to the wrong
    // transcript and the placeholder stayed behind in the right one. Both
    // helpers name the session the command was typed into.
    @MainActor
    func appendDispatchMessage(_ message: ChatMessage, to sessionId: String) {
        var messages = appModel.chatMessages(for: sessionId)
        messages.append(message)
        appModel.setChatMessages(messages, for: sessionId)
    }

    @MainActor
    func replaceDispatchPlaceholder(
        _ placeholderId: String,
        with message: ChatMessage,
        in sessionId: String
    ) {
        var messages = appModel.chatMessages(for: sessionId)
        messages.removeAll { $0.id == placeholderId }
        messages.append(message)
        appModel.setChatMessages(messages, for: sessionId)
    }

    // Sendable-safe dispatch that accepts the ToolInputForm's already validated,
    // JSON-shaped data before crossing the Task actor boundary.
    @MainActor
    func runDispatchAndRenderReceiptData(tool: String, inputData: Data, sessionId targetSessionId: String) async {
        let sessionId: String? = targetSessionId.isEmpty ? nil : targetSessionId
        let pendingContent = "⏳ Dispatching **\(tool)**…"
        let pending = ChatMessage(role: "system", content: pendingContent)
        appendDispatchMessage(pending, to: targetSessionId)
        do {
            let result = try await appModel.dispatchToolData(tool: tool, inputData: inputData, sessionId: sessionId)
            // Re-hydrate for display only — failure is non-fatal (fall back to empty input).
            let inputForDisplay = (try? JSONSerialization.jsonObject(with: inputData) as? [String: Any]) ?? [:]
            let receipt = buildReceiptMessage(result: result, tool: tool, input: inputForDisplay)
            replaceDispatchPlaceholder(pending.id, with: receipt, in: targetSessionId)
        } catch {
            replaceDispatchPlaceholder(
                pending.id,
                with: ChatMessage(role: "system",
                    content: "❌ **\(tool)** dispatch failed: \(error.localizedDescription)"),
                in: targetSessionId
            )
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
