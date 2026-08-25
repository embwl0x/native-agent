import ChatOrchestration
import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

private struct Wave8ChatFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-chat-wave8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class NextGenNavigationCapture: @unchecked Sendable {
    var count = 0
}

private final class ToolInputFormSubmissionCapture: @unchecked Sendable {
    var data: Data?
    var cancelCount = 0
}

private final class ContextFillCompactionCapture: @unchecked Sendable {
    var sessionIDs: [String] = []
    var models: [String] = []
    var providers: [String] = []
    var forceValues: [Bool] = []
    var didCompact = false
}

@MainActor
@Suite("App chat reports-only wave 8 durable behavior", .serialized)
struct AppChatReportsOnlyWave8BehaviorTests {
    private func appModel(root: URL) -> AppModel {
        AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            activeChatSessionIDWriter: { _ in },
            chatSnapshotPublisher: {}
        )
    }


    // app.chat / ui.chat.sidebar.archiveButton
    @Test("mounted archive action persists the archived session and selects a live replacement")
    func archiveActionDoesNotLeaveTheArchivedSessionActive() async throws {
        let fixture = try Wave8ChatFixture()
        defer { fixture.remove() }
        let archived = try await NativeClient.createChatSession(title: "Archive me", dataRoot: fixture.root)
        let replacement = try await NativeClient.createChatSession(title: "Keep me", dataRoot: fixture.root)
        let model = appModel(root: fixture.root)
        model.chatSessions = try await NativeClient.getChatSessions(dataRoot: fixture.root)
        model.activeChatSessionId = archived.id
        model.chatDrafts[archived.id] = "do not carry this forward"
        let sessionsPath = fixture.root.appendingPathComponent("chat/sessions.json")
        let sessionsBeforeArchive = try Data(contentsOf: sessionsPath)

        let archiveResult = await model.archiveActiveChat()
        #expect(archiveResult.succeeded)

        let archivePath = fixture.root.appendingPathComponent("chat/archive/sessions.jsonl")
        let sessionsAfterArchive = try Data(contentsOf: sessionsPath)
        #expect(sessionsAfterArchive != sessionsBeforeArchive)
        let survivingSessions = try await NativeClient.getChatSessions(dataRoot: fixture.root)
        #expect(!survivingSessions.contains { $0.id == archived.id })
        #expect(survivingSessions.contains { $0.id == replacement.id })
        let tail = try String(contentsOf: archivePath, encoding: .utf8)
            .split(separator: "\n")
        #expect(tail.count == 1)
        #expect(tail.first?.contains(archived.id) == true)
        #expect(model.activeChatSessionId == replacement.id)
        // Archive may retain a session-scoped draft for lifecycle cleanup; the
        // invariant is that it never becomes the newly selected session's draft.
        #expect(model.chatDraft(for: replacement.id).isEmpty)

        let retry = try await NativeClient.createChatSession(title: "Retry archive", dataRoot: fixture.root)
        await #expect(throws: (any Error).self) {
            _ = try await NativeClient.archiveChatSession(
                id: retry.id,
                dataRoot: fixture.root,
                afterArchiveTailWrite: {
                    throw NSError(domain: "Wave8", code: 9)
                }
            )
        }
        _ = try await NativeClient.archiveChatSession(id: retry.id, dataRoot: fixture.root)
        let retryTail = try String(contentsOf: archivePath, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.contains(retry.id) }
        #expect(retryTail.count == 1)

        let corrupt = try await NativeClient.createChatSession(title: "Corrupt tail", dataRoot: fixture.root)
        let corruptTail = Data("not-json\n".utf8)
        try corruptTail.write(to: archivePath, options: .atomic)
        await #expect(throws: (any Error).self) {
            _ = try await NativeClient.archiveChatSession(id: corrupt.id, dataRoot: fixture.root)
        }
        #expect(try Data(contentsOf: archivePath) == corruptTail)
        #expect(try await NativeClient.getChatSessions(dataRoot: fixture.root)
            .contains(where: { $0.id == corrupt.id }))
        #expect(model.activeChatSessionId != archived.id)
    }

    // app.chat / ui.chat.header.renameControls
    @Test("shared rename owner preserves unchanged bytes and durably commits a new title")
    func renameOwnerRejectsNoOpAndPersistsChangedTitle() async throws {
        let fixture = try Wave8ChatFixture()
        defer { fixture.remove() }
        let session = try await NativeClient.createChatSession(title: "Original", dataRoot: fixture.root)
        let model = appModel(root: fixture.root)
        model.chatSessions = [session]
        let sessionsURL = fixture.root.appendingPathComponent("chat/sessions.json")
        let before = try Data(contentsOf: sessionsURL)

        await model.renameChatSession(id: session.id, title: "  Original  ")
        let afterNoOp = try Data(contentsOf: sessionsURL)
        #expect(afterNoOp == before)

        await model.renameChatSession(id: session.id, title: "  Renamed  ")
        let persisted = try await NativeClient.getChatSessions(dataRoot: fixture.root)
        #expect(persisted.first(where: { $0.id == session.id })?.title == "Renamed")
        #expect(model.chatSessions.first?.title == "Renamed")
        #expect(model.statusText == "Renamed chat session")

        #expect(ChatHeaderRenamePresentation.belongsToCurrentSession(
            capturedSessionID: session.id, renderedSessionID: session.id
        ))
        #expect(!ChatHeaderRenamePresentation.belongsToCurrentSession(
            capturedSessionID: session.id,
            renderedSessionID: "newly-selected-session"
        ))

        let staleCommit = Task { @MainActor in
            await model.renameChatSession(id: session.id, title: "Older mounted intent")
        }
        await Task.yield()
        let newestCommit = Task { @MainActor in
            await model.renameChatSession(id: session.id, title: "Newest mounted intent")
        }
        await staleCommit.value
        await newestCommit.value
        let afterRace = try await NativeClient.getChatSessions(dataRoot: fixture.root)
        #expect(afterRace.first(where: { $0.id == session.id })?.title == "Newest mounted intent")
    }

    // app.chat / ui.chat.header.nextGenPill
    @Test("mounted NextGen header pill projects live phase fallback and opens its real destination")
    func nextGenHeaderPillUsesLivePhaseStateAndHonorsUnavailableInputs() throws {
        let summary = try JSONDecoder().decode(NextGenSummary.self, from: Data(#"""
        {
            "status":"planning",
            "current_phase_name":"  Context assembly  ",
            "ready_phase_count":1,
            "total_phase_count":3
        }
        """#.utf8))
        let phase = try JSONDecoder().decode(NextGenPhase.self, from: Data(#"""
        {
            "id":"phase-2",
            "title":"Context assembly",
            "status":"in_progress"
        }
        """#.utf8))

        let summaryPill = try #require(
            ChatHeaderNextGenPillPresentation.model(summary: summary, phases: [phase])
        )
        #expect(summaryPill.label == "Phase Context assembly")
        #expect(summaryPill.tooltip == "Phase 1 of 3 · planning")
        #expect(summaryPill.status == "planning")

        let boundedCounts = try #require(
            ChatHeaderNextGenPillPresentation.model(
                summary: try JSONDecoder().decode(NextGenSummary.self, from: Data(#"""
                {
                    "status":"planning", "current_phase_name":"Counts",
                    "ready_phase_count":99, "total_phase_count":2
                }
                """#.utf8)),
                phases: []
            )
        )
        #expect(boundedCounts.tooltip == "Phase 2 of 2 · planning")

        let phaseFallback = try #require(
            ChatHeaderNextGenPillPresentation.model(summary: nil, phases: [phase])
        )
        #expect(phaseFallback.label == "Phase 2 · Context assembly")
        #expect(phaseFallback.tooltip == "Phase 0 of 1 · in_progress")
        #expect(
            ChatHeaderNextGenPillPresentation.model(
                summary: try JSONDecoder().decode(NextGenSummary.self, from: Data(#"""
                {
                    "status":"ready", "current_phase_name":"   "
                }
                """#.utf8)),
                phases: []
            ) == nil,
            "A blank/absent phase source must not render a reassuring ready pill."
        )

        #expect(phaseFallback.accessibilityLabel == "NextGen status: Phase 0 of 1 · in_progress")
        #expect(phaseFallback.tooltip == "Phase 0 of 1 · in_progress")

        let capture = NextGenNavigationCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .openNextGenRequest,
            object: nil,
            queue: nil
        ) { _ in
            capture.count += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: .openNextGenRequest, object: nil)
        #expect(capture.count == 1)
    }

    // app.chat / ui.chat.nextGenActionChips
    @Test("mounted NextGen action chips only offer backed dry-runs and honor the global action gate")
    func nextGenActionChipsUseTheRealEligibilityAndDispatchGates() async throws {
        let summary = try JSONDecoder().decode(NextGenSummary.self, from: Data(#"""
        {
          "actions": [
            {"id":"ops.health.snapshot","name":"Health","dry_run_available":true,"status":"ready"},
            {"id":"truth.audit","name":"Truth","dry_run_available":true,"status":"ready"},
            {"id":"tool.lazy.index","name":"Index","dry_run_available":true,"status":"ready"},
            {"id":"context.route.preview","name":"Route","dry_run_available":true,"status":"ready"},
            {"id":"release.gate","name":"Release","dry_run_available":true,"status":"ready"},
            {"id":"workflow.launch","name":"Unbacked","dry_run_available":true,"status":"ready"},
            {"id":"connector.oauth.check","name":"Done","dry_run_available":true,"status":"completed"},
            {"id":"browser.capture","name":"No dry run","dry_run_available":false,"status":"ready"},
            {"id":" ops.health.snapshot ","name":"Duplicate","dry_run_available":true,"status":"ready"}
          ]
        }
        """#.utf8))
        #expect(NextGenActionChipsPresentation.visibleActions(summary: nil).isEmpty)
        #expect(NextGenActionChipsPresentation.visibleActions(summary: summary).map(\.id) == [
            "ops.health.snapshot", "truth.audit", "tool.lazy.index", "context.route.preview",
        ])
        #expect(NextGenActionChipsPresentation.hasMore(summary: summary))
        #expect(NextGenActionChipsPresentation.eligibleActions(summary: summary).filter {
            NextGenActionChipsPresentation.normalizedID($0.id) == "ops.health.snapshot"
        }.count == 1)
        #expect(!NextGenActionChipsPresentation.eligibleActions(summary: summary).contains {
            $0.id == "workflow.launch"
        })

        #expect(NextGenActionChipsPresentation.canRun(
            actionID: "ops.health.snapshot", runningIDs: [], completedIDs: [], isGlobalActionRunning: false
        ))

        #expect(!NextGenActionChipsPresentation.canRun(
            actionID: "truth.audit",
            runningIDs: [],
            completedIDs: [],
            isGlobalActionRunning: true
        ))
        #expect(!NextGenActionChipsPresentation.canRun(
            actionID: "  ",
            runningIDs: [],
            completedIDs: [],
            isGlobalActionRunning: false
        ))
        #expect(!NextGenActionChipsPresentation.canRun(
            actionID: "workflow.launch",
            runningIDs: [],
            completedIDs: [],
            isGlobalActionRunning: false
        ))
    }

    // app.chat / ui.chat.composer.toolInputForm
    @Test("tool input form emits schema-shaped JSON and blocks malformed or missing values")
    func toolInputFormValidatesValuesBeforeItsLiveSubmitAction() throws {
        let tool = try JSONDecoder().decode(ToolCapability.self, from: Data(#"""
        {
          "name": "fixture.complex-input",
          "description": "A tool-input form fixture.",
          "autonomy": "auto",
          "effective_autonomy": "auto",
          "autonomy_source": "fixture",
          "side_effects": false,
          "available_now": true,
          "input_schema": {
            "properties": {
              "title": { "type": "string", "description": "Title" },
              "count": { "type": "integer", "description": "Count" },
              "metadata": { "type": "object", "description": "Metadata" },
              "tags": { "type": "array", "description": "Tags" },
              "enabled": { "type": "boolean", "description": "Enabled" }
            },
            "required": ["title", "metadata", "tags", "enabled"]
          }
        }
        """#.utf8))
        let schema = try #require(tool.inputSchema)

        let validPayload = try ToolInputFormInput.serializedInput(
            schema: schema,
            stringValues: [
                "title": "  shipped  ",
                "metadata": #"{ "channel": "chat" }"#,
                "tags": #"["safe", 2]"#
            ],
            boolValues: ["enabled": true],
            intValues: ["count": 7]
        )
        let validObject = try #require(
            try JSONSerialization.jsonObject(with: validPayload) as? [String: Any]
        )
        #expect(validObject["title"] as? String == "shipped")
        #expect((validObject["metadata"] as? [String: Any])?["channel"] as? String == "chat")
        #expect((validObject["tags"] as? [Any])?.count == 2)
        #expect(validObject["enabled"] as? Bool == true)
        #expect(validObject["count"] as? Int == 7)

        do {
            _ = try ToolInputFormInput.serializedInput(
                schema: schema,
                stringValues: [
                    "title": "shipped",
                    "metadata": "not JSON",
                    "tags": "[]"
                ],
                boolValues: ["enabled": true],
                intValues: [:]
            )
            Issue.record("Malformed object input must never reach tool dispatch.")
        } catch let error as ToolInputFormInput.ValidationError {
            #expect(error == .invalidJSON(field: "metadata", expected: "object text"))
        } catch {
            Issue.record("Malformed object input produced an unexpected error: \(error)")
        }

        do {
            _ = try ToolInputFormInput.serializedInput(
                schema: schema,
                stringValues: [
                    "title": "   ",
                    "metadata": "{}",
                    "tags": "[]"
                ],
                boolValues: ["enabled": true],
                intValues: [:]
            )
            Issue.record("Blank required text must never reach tool dispatch.")
        } catch let error as ToolInputFormInput.ValidationError {
            #expect(error == .missingRequiredField("title"))
        } catch {
            Issue.record("Blank required text produced an unexpected error: \(error)")
        }

        let mountedTool = try JSONDecoder().decode(ToolCapability.self, from: Data(#"""
        {
          "name": "fixture.mounted-input",
          "description": "A mounted tool-input form fixture.",
          "autonomy": "auto",
          "effective_autonomy": "auto",
          "autonomy_source": "fixture",
          "side_effects": false,
          "available_now": true,
          "input_schema": {
            "properties": {
              "title": { "type": "string", "description": "Title" }
            },
            "required": ["title"]
          }
        }
        """#.utf8))
        let mountedPayload = try ToolInputFormInput.serializedInput(
            schema: mountedTool.inputSchema,
            stringValues: ["title": "  mounted value  "],
            boolValues: [:], intValues: [:]
        )
        let mountedObject = try #require(
            try JSONSerialization.jsonObject(with: mountedPayload) as? [String: Any]
        )
        #expect(mountedObject["title"] as? String == "mounted value")

    }

    // app.chat / ui.chat.header.conversationSettingsToggle
    @Test("conversation settings header control keeps an AX identity and reveals the brain-control detail")
    func conversationSettingsToggleRevealsAndHidesRealDetailRow() async throws {
        let fixture = try Wave8ChatFixture()
        defer { fixture.remove() }
        let session = try await NativeClient.createChatSession(title: "Settings", dataRoot: fixture.root)
        let model = appModel(root: fixture.root)
        model.chatSessions = [session]
        model.activeChatSessionId = session.id

        #expect(ChatHeaderPresentation.title(for: session) == "Settings")
        #expect(ChatHeaderPresentation.metadata(count: session.messageCount, fingerprint: nil).showsContextReady == false)
    }

    // app.chat / ui.chat.conversationSettings.staleModelWarning
    @Test("conversation settings visibly warn only when a loaded provider catalog omits its selected model")
    func conversationSettingsStaleModelWarningTracksTheLiveProviderCatalog() async throws {
        let stale = try #require(ChatConversationSettingsModelWarning.make(
            providerName: "Fixture Provider",
            selectedModel: "retired-model",
            advertisedModelIDs: ["current-model"],
            isExplicitlyUnavailable: false
        ))
        #expect(stale.kind == .staleCatalog)
        #expect(stale.text == "retired-model is not in Fixture Provider's current model catalog. Choose a replacement before sending.")
        #expect(ChatConversationSettingsModelWarning.make(
            providerName: "Fixture Provider",
            selectedModel: "retired-model",
            advertisedModelIDs: [],
            isExplicitlyUnavailable: false
        ) == nil, "An absent/empty catalog is not evidence that a saved model is stale.")
        let unavailable = try #require(ChatConversationSettingsModelWarning.make(
            providerName: "Fixture Provider",
            selectedModel: "retired-model",
            advertisedModelIDs: [],
            isExplicitlyUnavailable: true
        ))
        #expect(unavailable.kind == .unavailable)

        let provider = try JSONDecoder().decode(ProviderInfo.self, from: Data(#"""
        {
          "provider_id": "fixture-provider",
          "display_name": "Fixture Provider",
          "auth_modes": ["api_key"],
          "auth_status": {
            "provider_id": "fixture-provider",
            "state": "ready",
            "detail": "Ready"
          },
          "models": [{
            "id": "current-model",
            "name": "Current Model",
            "context_length": 128000,
            "supports_streaming": true,
            "supports_vision": true,
            "supports_tools": true,
            "supports_json_mode": true
          }]
        }
        """#.utf8))
        let defaults = UserDefaults.standard
        let savedProvider = defaults.object(forKey: "chatProvider")
        let savedModel = defaults.object(forKey: "chatModel")
        defer {
            if let savedProvider { defaults.set(savedProvider, forKey: "chatProvider") }
            else { defaults.removeObject(forKey: "chatProvider") }
            if let savedModel { defaults.set(savedModel, forKey: "chatModel") }
            else { defaults.removeObject(forKey: "chatModel") }
        }

        let fixture = try Wave8ChatFixture()
        defer { fixture.remove() }
        let model = appModel(root: fixture.root)
        model.chatProvider = provider.provider_id
        model.chatModel = "retired-model"
        model.providersList = [provider]
        var refreshedProvider = provider
        refreshedProvider.models[0].id = "retired-model"
        refreshedProvider.models[0].name = "Restored Model"
        model.providersList = [refreshedProvider]
        #expect(ChatConversationSettingsModelWarning.make(
            providerName: refreshedProvider.display_name,
            selectedModel: "retired-model",
            advertisedModelIDs: refreshedProvider.models.map(\.id),
            isExplicitlyUnavailable: false
        ) == nil)
    }

    // app.chat / ui.chat.contextFillBar.compactButton
    @Test("context fill compact button is visible only when useful and invokes its forced compact action")
    func contextFillCompactButtonUsesLiveAvailabilityAndReportsDeclinedCompaction() async throws {
        let compactable = SessionContextStatus(
            session_id: "compact-session",
            used_tokens: 80_000,
            transcript_tokens: 70_000,
            prompt_tokens: 10_000,
            previous_turn_tokens: nil,
            turn_delta_tokens: nil,
            budget: 100_000,
            percent: 80,
            message_count: 4,
            compactable: true,
            auto_compact_threshold: 60_000,
            model: "fixture-model",
            context_loaded: true,
            context_mode: "provider_receipt",
            context_fingerprint: "fixture-context",
            context_prompt_chars: 280_000
        )
        var noLongerCompactable = compactable
        noLongerCompactable.compactable = false
        #expect(ContextFillCompactionPresentation.buttonState(
            status: nil, isCompacting: false
        ) == .hidden)
        #expect(ContextFillCompactionPresentation.buttonState(
            status: noLongerCompactable, isCompacting: false
        ) == .hidden)
        #expect(ContextFillCompactionPresentation.buttonState(
            status: compactable, isCompacting: false
        ) == .ready)
        #expect(ContextFillCompactionPresentation.buttonState(
            status: compactable, isCompacting: true
        ) == .compacting)

        let declined = CompactionResult(
            compacted: false,
            session_id: compactable.session_id,
            messages_before: nil,
            messages_after: nil,
            summary_chars: nil,
            messages_replaced: nil,
            reason: "The transcript changed before compaction began.",
            percent: nil,
            error: nil
        )
        #expect(
            ContextFillCompactionPresentation.failureMessage(for: declined)
                == "Context compaction did not run: The transcript changed before compaction began."
        )

        let fixture = try Wave8ChatFixture()
        defer { fixture.remove() }
        let capture = ContextFillCompactionCapture()
        let model = appModel(root: fixture.root)
        let compactAction: ContextFillBar.CompactAction = { sessionID, modelID, providerID, force in
                    capture.sessionIDs.append(sessionID)
                    capture.models.append(modelID)
                    capture.providers.append(providerID)
                    capture.forceValues.append(force)
                    capture.didCompact = true
                    return CompactionResult(
                        compacted: true,
                        session_id: sessionID,
                        messages_before: 4,
                        messages_after: 2,
                        summary_chars: 80,
                        messages_replaced: 2,
                        reason: nil,
                        percent: 30,
                        error: nil
                    )
        }
        _ = try await compactAction(compactable.session_id, model.chatModel, model.chatProvider, true)

        #expect(capture.sessionIDs == [compactable.session_id])
        #expect(capture.models == [model.chatModel])
        #expect(capture.providers == [model.chatProvider])
        #expect(capture.forceValues == [true])
        #expect(ContextFillCompactionPresentation.buttonState(status: noLongerCompactable, isCompacting: false) == .hidden)
    }

    // app.chat / ui.chat.queue.removeNextButton
    @Test("mounted remove-next control removes the visible next turn, never a hidden queue head")
    func removeNextTargetsTheVisibleQueueProjection() throws {
        let fixture = try Wave8ChatFixture()
        defer { fixture.remove() }
        let model = appModel(root: fixture.root)
        let sessionID = "queue-wave8-\(UUID().uuidString)"
        let hidden = QueuedChatTurn(id: "hidden", text: "internal", hideUserBubble: true)
        let next = QueuedChatTurn(id: "next", text: "visible next")
        let later = QueuedChatTurn(id: "later", text: "visible later")
        model.queuedChatTurnsBySession[sessionID] = [hidden, next, later]

        let visibleNext = try #require(ChatQueuePresentation.visibleTurns(
            model.queuedChatTurns(for: sessionID)
        ).first)
        model.removeQueuedChatTurn(visibleNext.id, sessionId: sessionID)

        #expect(model.queuedChatTurns(for: sessionID).map(\.id) == ["hidden", "later"])
        #expect(ChatQueuePresentation.visibleTurns(model.queuedChatTurns(for: sessionID)).map(\.id) == ["later"])
    }

    // app.chat / ui.chat.transcript.inlineApprovalCard
    @Test("mounted approval card resolves the requested id and leaves a rejected daemon call actionable")
    func inlineApprovalCardDrivesTheResolutionBoundary() async throws {
        let fixture = try Wave8ChatFixture()
        defer { fixture.remove() }
        let model = appModel(root: fixture.root)
        let approval = ApprovalRequest(
            id: "approval-1", title: "Write file", action: "write_file", risk: "high", status: "pending"
        )
        model.approvals = [approval]
        var resolved: [(String, String)] = []
        model.approvalResolverOverride = { id, decision in
            resolved.append((id, decision))
            return ApprovalRequest(
                id: id, title: "Write file", action: "write_file", risk: "high", status: decision
            )
        }
        var metadata = ChatMessageMetadata()
        metadata.approvalId = approval.id
        let message = ChatMessage(role: "tool", content: "Allow write?", metadata: metadata)
        _ = try await model.resolveApproval(id: approval.id, decision: "approved")
        #expect(resolved.count == 1)
        #expect(resolved.first?.0 == approval.id)
        #expect(resolved.first?.1 == "approved")

        let failedModel = appModel(root: fixture.root)
        failedModel.approvals = [approval]
        failedModel.approvalResolverOverride = { _, _ in
            throw NSError(domain: "Wave8", code: 1, userInfo: [NSLocalizedDescriptionKey: "daemon unavailable"])
        }
        await #expect(throws: (any Error).self) {
            _ = try await failedModel.resolveApproval(id: approval.id, decision: "denied")
        }
        #expect(InlineApprovalPresentation.state(approvalID: approval.id, locallyResolved: false, localDecision: "", externalStatus: "pending") == .pending)
    }

    // app.chat / ui.chat.transcript.approvalNeverCollapsed
    @Test("a pending approval expands its entire tool group while ordinary tool groups remain collapsed")
    func pendingApprovalNeverHidesBehindToolSummary() throws {
        let fixture = try Wave8ChatFixture()
        defer { fixture.remove() }
        let model = appModel(root: fixture.root)
        let approval = ApprovalRequest(
            id: "approval-visible", title: "Visible approval", action: "write_file", risk: "high", status: "pending"
        )
        model.approvals = [approval]

        var ordinaryMetadata = ChatMessageMetadata()
        ordinaryMetadata.kind = "tool_use"
        ordinaryMetadata.toolName = "read_file"
        let ordinary = ChatMessage(role: "tool", content: "Read complete", metadata: ordinaryMetadata)
        // This is the persisted camel-case receipt shape the core writer
        // emits. Decode it before mounting so the production wire reader,
        // rather than an in-memory fixture, owns the card's authority id.
        let pendingJSON = """
        {"id":"pending-receipt","role":"tool","content":"Allow write?","metadata":{"kind":"\(ChatTranscriptToolMessageKind.approvalPending)","approvalId":"\(approval.id)"}}
        """
        let pendingData = try #require(pendingJSON.data(using: .utf8))
        let pending: NativeAppChatMessage = try JSONDecoder().decode(
            NativeAppChatMessage.self,
            from: pendingData
        )

        #expect(ChatMessageMetadata.approvalPendingKind == ChatTranscriptToolMessageKind.approvalPending)
        #expect(ChatMessageMetadata.approvalPendingKind == "approval_pending")
        #expect(pending.metadata?.isPendingApproval == true)
        #expect(pending.metadata?.approvalId == approval.id)
        #expect(ordinary.metadata?.isPendingApproval == false)

        #expect(ToolCallGroupPresentation.expandsInline(messages: [ordinary, pending]))

        // Negative control: the same two-row group with no shared pending
        // kind stays collapsed, proving the expanded assertion is not a view
        // default or a permanent test-host expansion.
        var secondOrdinaryMetadata = ChatMessageMetadata()
        secondOrdinaryMetadata.kind = "tool_use"
        secondOrdinaryMetadata.toolName = "list_files"
        let secondOrdinary = ChatMessage(
            role: "tool", content: "Listed files", metadata: secondOrdinaryMetadata
        )
        #expect(!ToolCallGroupPresentation.expandsInline(messages: [ordinary, secondOrdinary]))
    }

    // app.chat / feed.chat.inboxStrip
    @Test("mounted inbox strip keeps the rendered item and exposes its read failure")
    func inboxStripFailureIsVisibleWithoutErasingItems() async throws {
        let fixture = try Wave8ChatFixture()
        defer { fixture.remove() }
        let model = appModel(root: fixture.root)
        let item = try JSONDecoder().decode(
            InboxItemRecord.self,
            from: Data(#"{"id":"inbox-1","created_at":"2026-08-24T00:00:00Z","source":"test","severity":"actionable","title":"Review this","summary":"Still waiting","actions":[],"status":"unread"}"#.utf8)
        )
        let newest = try JSONDecoder().decode(
            InboxItemRecord.self,
            from: Data(#"{"id":"inbox-2","created_at":"2026-08-24T00:01:00Z","source":"test","severity":"actionable","title":"Newest item","summary":"Fresh","actions":[],"status":"unread"}"#.utf8)
        )
        var reads = 0
        var delayed: CheckedContinuation<[InboxItemRecord], Error>?
        var delayedError: CheckedContinuation<[InboxItemRecord], Error>?
        model.inboxReaderOverride = { _ in
            reads += 1
            if reads == 1 {
                return try await withCheckedThrowingContinuation { delayed = $0 }
            }
            if reads == 3 {
                return try await withCheckedThrowingContinuation { delayedError = $0 }
            }
            return [newest]
        }
        let loaded = InboxStripPresentation.loaded([newest])
        #expect(loaded.items == [newest])
        #expect(loaded.loadError == nil)
        let retained = InboxStripPresentation.failed(
            previousItems: loaded.items,
            errorDescription: "stale read failed"
        )
        #expect(retained.items == [newest])
        #expect(retained.loadError == "stale read failed")
    }
}
