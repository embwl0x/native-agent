import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentCommsActions+Agents.swift` | agents action contracts and execution |

enum AgentCommsActions {}

struct AgentContactsArgs: DoorArgs {
    static let rootSchemaConstraints: [String: JSONValue] = ["additionalProperties": .bool(false)]
    static let detailsField = DoorFieldDescriptor.bool("details").nullable()
    static let discoverField = DoorFieldDescriptor.stringBoolOrNull("discover", "true, or a name to find.", booleanFirst: true)
    static let doorFields: [DoorFieldDescriptor] = [detailsField, discoverField]
    let details: Bool?
    let discover: DoorStringOrBool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        details = try door.bool(Self.detailsField)
        discover = try door.stringOrBool(Self.discoverField)
    }
}

struct AgentConnectArgs: DoorArgs {
    static let rootSchemaConstraints: [String: JSONValue] = ["additionalProperties": .bool(false)]
    static let nameField = DoorFieldDescriptor.string("name", """
        The participant's name, at most 120 characters. On its own — with no endpoint and no transport — it is looked up among the \
        known agent hosts on this Mac, matched case-insensitively including common aliases. With an endpoint it is the display name for \
        that contact.
        """, required: true)
    static let endpointField = DoorFieldDescriptor.string("endpoint", """
        Required for a2a/nativeAgent: HTTPS URL, or explicit loopback HTTP. No embedded credentials, query, or fragment. Omit for \
        desktop, and omit to connect by name.
        """).nullable()
    static let transportField = DoorFieldDescriptor.choice("transport", ["auto", "a2a", "nativeAgent", "desktop"]).nullable()
    static let disconnectField = DoorFieldDescriptor.bool("disconnect").nullable()
    static let reopenField = DoorFieldDescriptor.bool("reopen", """
        By name, on the person's ask: a host that loads its entry only at launch (Claude Desktop, Codex, Cursor) is quit, seen gone \
        and opened again after setup.
        """).nullable()
    static let workingDirectoryField = DoorFieldDescriptor.string("working_directory", """
        ACP agents only: explicit absolute project folder to show on the connect card. Omit for a new empty folder in this app's \
        workspace.
        """).nullable()
    static let workspaceField = DoorFieldDescriptor.string("workspace", "Existing workspace folder, required for Cursor Workspace. Omit for global connections.").nullable()
    static let executablePathField = DoorFieldDescriptor.string("executable_path", "Exact resolved executable bound by the app to the connect approval. Retained unchanged on replay.").nullable()
    static let appBundleIDField = DoorFieldDescriptor.string("app_bundle_id", """
        Desktop only: exact installed app bundle identifier, such as com.example.agent. No guessed recipient identity.
        """).nullable()
    static let conversationLabelField = DoorFieldDescriptor.string("conversation_label", """
        Desktop: optional visible conversation or bot label to verify in the app. Grok Bot by name: the exact sidebar name of the Bot \
        that receives the routine request, as Use this Bot on the Connect card; only before that request is sent. Target data, not \
        instructions or a verified session ID.
        """).nullable()
    static let bearerTokenField = DoorFieldDescriptor.string("bearer_token", """
        Optional network credential for this peer only; never use another connector's credentials. Not accepted for desktop.
        """, secret: true).nullable()
    static let abilityField = DoorFieldDescriptor.stringBoolOrNull("ability", """
            A saved contact can be reached through one of your abilities: its id here, with the contact's name, moves the contact there \
            (agent.message runs it, and it answers with agent.reply), and false moves it back to its built-in route.
            """, booleanFirst: false)
    static let doorFields = [
        nameField, endpointField, transportField, disconnectField, reopenField, workingDirectoryField,
        workspaceField, executablePathField, appBundleIDField, conversationLabelField, bearerTokenField,
        abilityField,
    ]
    let name: String
    let endpoint: String?
    let transport: String?
    let disconnect: Bool?
    let reopen: Bool?
    let workingDirectory: String?
    let workspace: String?
    let executablePath: String?
    let appBundleID: String?
    let conversationLabel: String?
    let bearerToken: String?
    let ability: DoorStringOrBool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        name = try door.requiredString(Self.nameField)
        endpoint = try door.string(Self.endpointField).flatMap { $0.isEmpty ? nil : $0 }
        transport = try door.string(Self.transportField).flatMap { $0.isEmpty ? nil : $0 }
        disconnect = try door.bool(Self.disconnectField).flatMap { $0 ? true : nil }
        reopen = try door.bool(Self.reopenField)
        workingDirectory = try door.string(Self.workingDirectoryField)
        workspace = try door.string(Self.workspaceField)
        executablePath = try door.string(Self.executablePathField)
        appBundleID = try door.string(Self.appBundleIDField).flatMap { $0.isEmpty ? nil : $0 }
        conversationLabel = try door.string(Self.conversationLabelField).flatMap { $0.isEmpty ? nil : $0 }
        bearerToken = try door.string(Self.bearerTokenField).flatMap { $0.isEmpty ? nil : $0 }
        ability = try door.stringOrBool(Self.abilityField).flatMap { if case .string("") = $0 { nil } else { $0 } }
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.nameField.name] = .string(name)
        fields[Self.endpointField.name] = endpoint.map(JSONValue.string)
        fields[Self.transportField.name] = transport.map(JSONValue.string)
        fields[Self.disconnectField.name] = disconnect.map(JSONValue.bool)
        fields[Self.reopenField.name] = reopen.map(JSONValue.bool)
        fields[Self.workingDirectoryField.name] = workingDirectory.map(JSONValue.string)
        fields[Self.workspaceField.name] = workspace.map(JSONValue.string)
        fields[Self.executablePathField.name] = executablePath.map(JSONValue.string)
        fields[Self.appBundleIDField.name] = appBundleID.map(JSONValue.string)
        fields[Self.conversationLabelField.name] = conversationLabel.map(JSONValue.string)
        fields[Self.bearerTokenField.name] = bearerToken.map(JSONValue.string)
        fields[Self.abilityField.name] = ability?.wire
        return fields
    }
}

struct AgentMessageArgs: DoorArgs {
    static let rootSchemaConstraints: [String: JSONValue] = ["additionalProperties": .bool(false)]
    static let argumentNames = ["agent": ["to"]]
    static let agentField = DoorFieldDescriptor.string("agent", """
        A unique saved participant name or handle, bot:<UUID>, or peer:<UUID> from agent.contacts. Ambiguous names need an exact reference; \
        never guess.
        """, required: true, subject: true)
    static let textField = DoorFieldDescriptor.string("text", "The message to send.", required: true)
    static let filesField = DoorFieldDescriptor.objects("files", AgentMessageFiles.Attachment.self, description: """
            Optional file attachments in the reply attachment's local-path form: [{path}]. A2A only; other adapters refuse before \
            sending text. At most four regular files, 8 MiB total, behind the ordinary attachment and secret fences. Queued paths are \
            read when the send executes; missing, empty, unreadable or secret-bearing files refuse the whole send.
            """, maxItems: 4).nullable()
    static let conversationField = DoorFieldDescriptor.string("conversation", """
        Optional human conversation label, such as browser work, for adapters supporting separate conversations. Omit to use this participant's \
        current conversation. Home message shortcuts also take args {text, conversation}. Bots have one continuous conversation: omit this \
        field for bots. Opening a bot by name shows its latest full saved reply. On supported routes, an unused label starts a separate \
        conversation; on a read it selects an existing one. The app retains the underlying identities.
        """).nullable()
    static let newConversationField = DoorFieldDescriptor.bool("new_conversation").nullable()
    static let expectsReplyField = DoorFieldDescriptor.bool("expects_reply", """
        false for a message needing no answer. Acceptance is still owed until the recipient receives it. Omit for questions and work.
        """).nullable()
    static let dryRunField = DoorFieldDescriptor.bool("dry_run", """
        true checks this contact's send route end to end without sending anything (agent.verify uses it). Omit to send.
        """).nullable()
    static let waitSecondsField = DoorFieldDescriptor.int("wait_seconds", """
        Wait for a live lane's reply inline: default 20, maximum 120; 0 sends and continues. Async lanes ignore the wait and say \
        wait_ignored:lane_is_async. Timeout keeps the queued receipt; the later answer still arrives once.
        """, minimum: 0, maximum: 120).nullable()
    static let conversationIDField = DoorFieldDescriptor.string("conversation_id", """
        Advanced override: exact existing remote conversation identity. Normally omit; the app remembers it. A failed resume never \
        falls back to a fresh conversation. Bots retain their own conversation.
        """).nullable()
    static let messageIDField = DoorFieldDescriptor.string("message_id", """
        Optional caller message identity for coding agents or A2A; NativeAgent accepts a UUID for receipt correlation, not \
        deduplication. Not supported for bot sends. Use returned request identity for recovery.
        """).nullable()
    static let taskIDField = DoorFieldDescriptor.string("task_id", "A2A only: exact task to continue, especially when it needs input.").nullable()
    static let doorFields = [
        agentField, textField, filesField, conversationField, newConversationField, expectsReplyField,
        dryRunField, waitSecondsField, conversationIDField, messageIDField, taskIDField,
    ]
    let agent: String
    let text: String
    let files: [AgentMessageFiles.Attachment]?
    let conversation: String?
    let newConversation: Bool?
    let expectsReply: Bool?
    let dryRun: Bool?
    let waitSeconds: Int?
    let conversationID: String?
    let messageID: String?
    let taskID: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        agent = try door.requiredString(Self.agentField)
        text = try door.requiredString(Self.textField)
        files = try door.objects(Self.filesField, as: AgentMessageFiles.Attachment.self)
        conversation = try door.string(Self.conversationField)
        newConversation = try door.bool(Self.newConversationField)
        expectsReply = try door.bool(Self.expectsReplyField)
        dryRun = try door.bool(Self.dryRunField)
        waitSeconds = try door.int(Self.waitSecondsField)
        conversationID = try door.string(Self.conversationIDField)
        messageID = try door.string(Self.messageIDField)
        taskID = try door.string(Self.taskIDField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.agentField.name] = .string(agent)
        fields[Self.textField.name] = .string(text)
        fields[Self.filesField.name] = files.map { .array($0.map { .object(["path": .string($0.path)]) }) }
        fields[Self.conversationField.name] = conversation.map(JSONValue.string)
        fields[Self.newConversationField.name] = newConversation.map(JSONValue.bool)
        fields[Self.expectsReplyField.name] = expectsReply.map(JSONValue.bool)
        fields[Self.dryRunField.name] = dryRun.map(JSONValue.bool)
        fields[Self.waitSecondsField.name] = waitSeconds.map { .int(Int64($0)) }
        fields[Self.conversationIDField.name] = conversationID.map(JSONValue.string)
        fields[Self.messageIDField.name] = messageID.map(JSONValue.string)
        fields[Self.taskIDField.name] = taskID.map(JSONValue.string)
        return fields
    }
}

struct AgentReadArgs: DoorArgs {
    static let rootSchemaConstraints: [String: JSONValue] = ["additionalProperties": .bool(false)]
    static let agentField = DoorFieldDescriptor.string("agent", """
        A unique saved participant name or handle, bot:<UUID>, or peer:<UUID> from agent.contacts. Ambiguous names need an exact reference; \
        never guess.
        """).nullable()
    static let conversationField = DoorFieldDescriptor.string("conversation", """
        Optional human conversation label, such as browser work, for adapters supporting separate conversations. Omit to use this participant's \
        current conversation. Home message shortcuts also take args {text, conversation}. Bots have one continuous conversation: omit this \
        field for bots. Opening a bot by name shows its latest full saved reply. On supported routes, an unused label starts a separate \
        conversation; on a read it selects an existing one. The app retains the underlying identities.
        """).nullable()
    static let jobField = DoorFieldDescriptor.string("job", "A job's id from agent.job: reads that job, its state, check, deliverables and diff. Omit for conversations.").nullable()
    static let detailsField = DoorFieldDescriptor.bool("details").nullable()
    static let waitSecondsField = DoorFieldDescriptor.int("wait_seconds", """
        Wait 1–300 seconds on a named conversation or its retained exact reply IDs. Omit history and listing filters. Untracked IDs are \
        read once without waiting; nothing is resent.
        """, minimum: 1, maximum: 300).nullable()
    static let historyBeforeField = DoorFieldDescriptor.string("history_before", """
        Conversation scrollback only: earlier_before returned by session_history. Omit for recent messages; never sends or restarts a \
        turn.
        """).nullable()
    static let historyExchangeField = DoorFieldDescriptor.string("history_exchange", """
        Conversation scrollback only: open one message from session_history in full. Mutually exclusive with history_before and \
        advanced protocol IDs.
        """).nullable()
    static let messageIDField = DoorFieldDescriptor.string("message_id", """
        Advanced exact message/request or bot shelf-entry identity. Normally omit; the app retains it. A reply is not independent proof \
        that work finished.
        """).nullable()
    static let conversationIDField = DoorFieldDescriptor.string("conversation_id", """
        Advanced exact conversation identity for NativeAgent reply recovery; bots may use bot:<UUID>. Normally omit. Coding receipt \
        reads do not accept a conversation filter.
        """).nullable()
    static let taskIDField = DoorFieldDescriptor.string("task_id", "Advanced A2A task identity to retrieve. Normally omit; the app retains it.").nullable()
    static let pageSizeField = DoorFieldDescriptor.int("page_size", "A2A task listing page size.", minimum: 1, maximum: 100).nullable()
    static let pageTokenField = DoorFieldDescriptor.string("page_token", "A2A nextPageToken from the previous listing.").nullable()
    static let contextIDField = DoorFieldDescriptor.string("context_id", "A2A task listing context filter.").nullable()
    static let statusField = DoorFieldDescriptor.string("status", "A2A task listing status, for example TASK_STATE_WORKING.").nullable()
    static let historyLengthField = DoorFieldDescriptor.int("history_length", "Maximum messages in each listed A2A task's history.", minimum: 0).nullable()
    static let includeArtifactsField = DoorFieldDescriptor.bool("include_artifacts").nullable()
    static let statusTimestampAfterField = DoorFieldDescriptor.string("status_timestamp_after", "A2A tasks updated at or after this RFC3339 timestamp.").nullable()
    static let limitField = DoorFieldDescriptor.int("limit", "Local listing size: coding agents 1–12, bots and Dot 1–100.", minimum: 1, maximum: 100).nullable()
    static let offsetField = DoorFieldDescriptor.int("offset", """
        Coding listing offset or NativeAgent reply character offset. For Dot, messages from newest; returned messages are \
        chronological. NativeAgent returns bounded pages; follow the exact next object for Dot or next_offset for other reply pages. \
        Bots use their existing shelf cursor instead.
        """, minimum: 0).nullable()
    static let maxCharsField = DoorFieldDescriptor.int("max_chars", """
        NativeAgent or Dot reply text window, 1–16000 characters; default 8000. Dot retains every omitted character through next.
        """, minimum: 1, maximum: 16000).nullable()
    static let textOffsetField = DoorFieldDescriptor.int("text_offset", """
        Dot only: character offset within the first selected message, supplied by next. Omit for a fresh read.
        """, minimum: 0).nullable()
    static let sourceVersionField = DoorFieldDescriptor.string("source_version", """
        Dot only: exact retained transcript version from next. Changed source requires a fresh read; omit for a fresh window.
        """).nullable()
    static let doorFields = [
        agentField, conversationField, jobField, detailsField, waitSecondsField, historyBeforeField,
        historyExchangeField, messageIDField, conversationIDField, taskIDField, pageSizeField, pageTokenField,
        contextIDField, statusField, historyLengthField, includeArtifactsField, statusTimestampAfterField,
        limitField, offsetField, maxCharsField, textOffsetField, sourceVersionField,
    ]
    let agent: String?
    let conversation: String?
    let job: String?
    let details: Bool?
    let waitSeconds: Int?
    let historyBefore: String?
    let historyExchange: String?
    let messageID: String?
    let conversationID: String?
    let taskID: String?
    let pageSize: Int?
    let pageToken: String?
    let contextID: String?
    let status: String?
    let historyLength: DoorNumberLiteral?
    let includeArtifacts: Bool?
    let statusTimestampAfter: String?
    let limit: DoorNumberLiteral?
    let offset: DoorNumberLiteral?
    let maxChars: DoorNumberLiteral?
    let textOffset: DoorNumberLiteral?
    let sourceVersion: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        agent = try door.string(Self.agentField)
        conversation = try door.string(Self.conversationField)
        job = try door.string(Self.jobField)
        details = try door.bool(Self.detailsField)
        waitSeconds = try door.int(Self.waitSecondsField)
        historyBefore = try door.string(Self.historyBeforeField)
        historyExchange = try door.string(Self.historyExchangeField)
        messageID = try door.string(Self.messageIDField)
        conversationID = try door.string(Self.conversationIDField)
        taskID = try door.string(Self.taskIDField)
        pageSize = try door.int(Self.pageSizeField)
        pageToken = try door.string(Self.pageTokenField)
        contextID = try door.string(Self.contextIDField)
        status = try door.string(Self.statusField)
        historyLength = try door.numberLiteral(Self.historyLengthField)
        includeArtifacts = try door.bool(Self.includeArtifactsField)
        statusTimestampAfter = try door.string(Self.statusTimestampAfterField)
        limit = try door.numberLiteral(Self.limitField)
        offset = try door.numberLiteral(Self.offsetField)
        maxChars = try door.numberLiteral(Self.maxCharsField)
        textOffset = try door.numberLiteral(Self.textOffsetField)
        sourceVersion = try door.string(Self.sourceVersionField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.agentField.name] = agent.map(JSONValue.string)
        fields[Self.conversationField.name] = conversation.map(JSONValue.string)
        fields[Self.jobField.name] = job.map(JSONValue.string)
        fields[Self.detailsField.name] = details.map(JSONValue.bool)
        fields[Self.waitSecondsField.name] = waitSeconds.map { .int(Int64($0)) }
        fields[Self.historyBeforeField.name] = historyBefore.map(JSONValue.string)
        fields[Self.historyExchangeField.name] = historyExchange.map(JSONValue.string)
        fields[Self.messageIDField.name] = messageID.map(JSONValue.string)
        fields[Self.conversationIDField.name] = conversationID.map(JSONValue.string)
        fields[Self.taskIDField.name] = taskID.map(JSONValue.string)
        fields[Self.pageSizeField.name] = pageSize.map { .int(Int64($0)) }
        fields[Self.pageTokenField.name] = pageToken.map(JSONValue.string)
        fields[Self.contextIDField.name] = contextID.map(JSONValue.string)
        fields[Self.statusField.name] = status.map(JSONValue.string)
        fields[Self.historyLengthField.name] = historyLength?.wire
        fields[Self.includeArtifactsField.name] = includeArtifacts.map(JSONValue.bool)
        fields[Self.statusTimestampAfterField.name] = statusTimestampAfter.map(JSONValue.string)
        fields[Self.limitField.name] = limit?.wire
        fields[Self.offsetField.name] = offset?.wire
        fields[Self.maxCharsField.name] = maxChars?.wire
        fields[Self.textOffsetField.name] = textOffset?.wire
        fields[Self.sourceVersionField.name] = sourceVersion.map(JSONValue.string)
        return fields
    }
}

struct AgentCancelArgs: DoorArgs {
    static let rootSchemaConstraints: [String: JSONValue] = ["additionalProperties": .bool(false)]
    static let agentField = DoorFieldDescriptor.string("agent", """
        A unique saved participant name or handle, bot:<UUID>, or peer:<UUID> from agent.contacts. Ambiguous names need an exact reference; \
        never guess.
        """).nullable()
    static let conversationField = DoorFieldDescriptor.string("conversation", """
        Optional human conversation label, such as browser work, for adapters supporting separate conversations. Omit to use this participant's \
        current conversation. Home message shortcuts also take args {text, conversation}. Bots have one continuous conversation: omit this \
        field for bots. Opening a bot by name shows its latest full saved reply. On supported routes, an unused label starts a separate \
        conversation; on a read it selects an existing one. The app retains the underlying identities.
        """).nullable()
    static let jobField = DoorFieldDescriptor.string("job", "A job's id from agent.job: stops that job on its agent's own terms. Omit for conversations.").nullable()
    static let clearQueueField = DoorFieldDescriptor.bool("clear_queue").nullable()
    static let conversationIDField = DoorFieldDescriptor.string("conversation_id", "Advanced exact conversation identity of the send to stop. Normally omit; the app retains it.").nullable()
    static let messageIDField = DoorFieldDescriptor.string("message_id", "Advanced exact message identity of the send to stop. Normally omit; the app retains it.").nullable()
    static let taskIDField = DoorFieldDescriptor.string("task_id", "Advanced A2A task identity to cancel. Normally omit; the app retains it.").nullable()
    static let doorFields = [
        agentField, conversationField, jobField, clearQueueField, conversationIDField, messageIDField,
        taskIDField,
    ]
    let agent: String?
    let conversation: String?
    let job: String?
    let clearQueue: Bool?
    let conversationID: String?
    let messageID: String?
    let taskID: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        agent = try door.string(Self.agentField)
        conversation = try door.string(Self.conversationField)
        job = try door.string(Self.jobField)
        clearQueue = try door.bool(Self.clearQueueField)
        conversationID = try door.string(Self.conversationIDField).flatMap { $0.isEmpty ? nil : $0 }
        messageID = try door.string(Self.messageIDField).flatMap { $0.isEmpty ? nil : $0 }
        taskID = try door.string(Self.taskIDField).flatMap { $0.isEmpty ? nil : $0 }
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.agentField.name] = agent.map(JSONValue.string)
        fields[Self.conversationField.name] = conversation.map(JSONValue.string)
        fields[Self.jobField.name] = job.map(JSONValue.string)
        fields[Self.clearQueueField.name] = clearQueue.map(JSONValue.bool)
        fields[Self.conversationIDField.name] = conversationID.map(JSONValue.string)
        fields[Self.messageIDField.name] = messageID.map(JSONValue.string)
        fields[Self.taskIDField.name] = taskID.map(JSONValue.string)
        return fields
    }
}

extension AgentCommsActions {
    static let agentCommunicationActions: [ActionDescriptor] = {
        [
            ActionDescriptor(AgentContactsArgs.self, name: "agent_contacts",
                run: { context, args in
                    try await context.client.impl_agent_contacts(context: context, args: args)
                }, toolClass: .read, description: """
                One short row per contact: name, state and last answered from its thread. details:true includes doors and connection evidence. Set \
                discover true only when the person asks about agents or asks to find agents; ordinary calls reuse observations without discovery.
                """),
            ActionDescriptor(AgentConnectArgs.self, name: "agent_connect",
                preflight: { $0.client.agentHostSetupRefusal(tool: $0.tool, input: $1.wire) },
                approvalReason: { root, canonical, input in
                    SwiftToolDispatcher.hostApprovalReason(tool: "agent_connect", input: input, dataRoot: root, usesCanonicalBody: canonical)
                },
                run: { context, args in
                    let result = try await context.client.impl_agent_connect(context: context, args: args)
                    await AgentDiscoverySession.shared.settle(dataRoot: context.runtime.dataRoot)
                    return result
                }, toolClass: .write, capabilities: [.appDataWrite, .credentialWrite, .otherAppSettingsWrite,
                .toolCall], effectInputPolicy: .agentConnection, description: """
                Connect a participant by name, URL or desktop app. First resolve it with agent.contacts; Codex/Claude may also name providers. Call \
                directly: Trust supplies any required approval card with the exact change. Name alone finds a supported installed host and adds one \
                MCP entry for nativeagent-link with a connection-specific key. Preserves other settings; keeps the newest NativeAgent backup for \
                each owned section beside its file and removes those backups on disconnect. Unknown/uninstalled hosts leave settings unchanged; no \
                app is restarted unless reopen:true. Setup may run one fixed CLI verification probe asking the participant to answer through the entry; \
                this is a message, not task work or an authority grant. Connected requires an authenticated inbound request, not a successful CLI \
                exit. Otherwise stays configured with the cause; without a probe route, the result names any restart needed and waits for first \
                inbound proof without reading the window. Disconnect: disconnect:true, name:peer:<exact id from agent.contacts>; removes that entry \
                and revokes its key. With endpoint, omitted/auto transport discovers supported A2A/NativeAgent cards through bounded same-origin \
                GETs; explicit a2a/nativeAgent saves without probing. Desktop: transport:desktop, app_bundle_id, optional conversation_label; \
                send-only, using existing Mac permissions to type into its chat. Replies require that app’s nativeagent-link mcp entry and its \
                agent_message tool. Reuses exact discovered/desktop routes.
                """),
            ActionDescriptor(AgentMessageArgs.self, name: "agent_message",
                run: { context, args in
                    try await context.client.impl_agent_message(context: context, args: args)
                }, toolClass: .send, capabilities: [.appDataWrite, .externalSend, .networkRead, .networkWrite,
                .processSpawn, .shell, .toolCall], effectInputPolicy: .agentMessage, description: """
                Send a message to an agent and wait up to wait_seconds (default 20, max 120) for a live lane's answer inline; 0 sends and \
                continues. An answered receipt has reply, replied_at and delivery:answered. Timeout preserves queued delivery and the later reply; \
                async lanes return immediately with wait_ignored:lane_is_async. A known agent not yet connected is connected first through its \
                setup gates. Continues your current thread; conversation names a separate one, new_conversation:true starts fresh. While its reply \
                is still coming, a new message queues behind it and goes by itself when that reply settles. Queued or delivered is not done; never \
                auto-resend.
                """),
            ActionDescriptor(AgentReadArgs.self, name: "agent_read",
                run: { context, args in
                    try await context.client.impl_agent_read(context: context, args: args)
                }, toolClass: .read, capabilities: [.networkRead, .toolCall], description: """
                Open a participant’s conversation. Omit protocol IDs: the app uses this conversation’s retained thread and exact reply locator. \
                conversation selects a named conversation. Default: who replied, their words and state; details:true adds receipts. Reading sends \
                nothing and never proves completion. Supported routes collect pending replies without polling. Send-only routes cannot read app \
                windows; standalone routes may lack history. Missing/uncertain evidence stays explicit. wait_seconds returns when the in-flight \
                reply settles; exact recovery IDs and adapter listing/history filters are below.
                """),
            ActionDescriptor(AgentCancelArgs.self, name: "agent_cancel",
                run: { context, args in
                    try await context.client.impl_agent_cancel(context: context, args: args)
                }, toolClass: .write, capabilities: [.networkWrite, .toolCall], description: """
                Stop the reply an agent is working on in your conversation with it, on that agent's own terms: an A2A task cancel or an ACP \
                session cancel. Some routes have no stop (a desktop app window, Grok Bot); the answer says so and any reply \
                still arrives. The conversation records the stop as stopping, stopped, released (the route has no stop but hands the answer back \
                by itself, so the conversation stops waiting on it) or cannot_stop. Messages you send while a reply is in flight queue behind it \
                and go by themselves when it settles; a stop lets them go now, and clear_queue true \
                withdraws them instead. Stopping never resends anything.
                """)
        ]
    }()
}
