import Foundation
import NativeAgentCore
import PersistenceCore
import MindCore
import ProviderRouting
import DeskCore
import NativeAgentShared
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MacNerves
import SenseCore
// Blueprint: | `ChatActions+Turn.swift` | turn action contracts and execution |

struct ContextLookupArgs: DoorArgs {
    static let queryField = DoorFieldDescriptor.string("query", "Capability or feature text to search for. Empty returns the first bounded feature-surface records.")
    static let typeField = DoorFieldDescriptor.string("type", "Optional operation: lookup_feature_surface.")
    static let doorFields = [queryField, typeField]
    let query: String?
    let type: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.string(Self.queryField)
        type = try door.string(Self.typeField)
    }
}

struct ScratchpadReadArgs: DoorArgs {
    static let keyField = DoorFieldDescriptor.string("key", "Optional scratch key. If omitted, returns bounded scratch keys and values.")
    static let sessionIDField = DoorFieldDescriptor.string("session_id", "Optional conversation id; injected by the app for normal chat/Telegram turns.")
    static let doorFields = [keyField, sessionIDField]
    let key: String?
    let sessionID: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        key = try door.string(Self.keyField)
        sessionID = try door.string(Self.sessionIDField)
    }
}

struct ToolResultPageArgs: DoorArgs {
    static let resultHandleField = DoorFieldDescriptor.string("result_handle", "Opaque handle from the bounded_tool_result receipt.").nullable()
    static let resumeField = DoorFieldDescriptor.bool("continue", """
        Continue this turn's last successful read; page is ignored. With query or raw, reads that way: the same read goes on, \
        a different one starts at its page 0. result_handle explicitly changes result. Name result_handle for the first read.
        """).nullable()
    static let pageField = DoorFieldDescriptor.int("page", """
        Zero-based whole-number page index. Omit or null starts at 0; follow next_page while has_more is true. Keep query and \
        raw unchanged while paging.
        """).nullable()
    static let pagesField = DoorFieldDescriptor.int("pages", """
        How many pages to read in this one answer, from page onward; omit to read as many as one answer holds (an explicit \
        raw read takes one). The answer says pages_read and where to go on; follow next_call for the rest.
        """).nullable()
    static let queryField = DoorFieldDescriptor.string("query", """
        Return the lines holding the phrase as written, case-insensitively; only when it is nowhere, the lines holding \
        a word, from sections containing every whitespace-separated word (query_read_as says which). A long line gives a \
        window around the match. Keep query while paging; start at page 0 when changing it. Empty reads all sections whole.
        """).nullable()
    static let rawField = DoorFieldDescriptor.bool("raw", """
        Exact original bytes instead of sections, only for reconstruction or oversized values. Separate 8000-byte pages may \
        split sentences/JSON; concatenate from page 0 through raw_page_count pages.
        """).nullable()
    static let sessionIDField = DoorFieldDescriptor.string("session_id", "Current conversation id; the app fills this in.").nullable()
    static let doorFields: [DoorFieldDescriptor] = [resultHandleField, resumeField, pageField, pagesField, queryField, rawField, sessionIDField]
    let resultHandle: String?
    let resume: Bool?
    let page: DoorNumberLiteral?
    let pages: DoorNumberLiteral?
    let query: String?
    let raw: Bool?
    let sessionID: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        resultHandle = try door.string(Self.resultHandleField)
        resume = try door.bool(Self.resumeField)
        page = try door.numberLiteral(Self.pageField)
        pages = try door.numberLiteral(Self.pagesField)
        query = try door.string(Self.queryField)
        raw = try door.bool(Self.rawField)
        sessionID = try door.string(Self.sessionIDField)
    }
}

struct RequestInteractionArgs: DoorArgs {
    struct SignIn: DoorObjectSchema {
        static let authorizeField = DoorFieldDescriptor.string("authorize", "https authorize URL; may carry extra query parameters.")
        static let deviceField = DoorFieldDescriptor.string("device", """
            https device authorization URL, given instead of authorize for a device sign-in: the card shows the person the \
            code and opens where they enter it.
            """)
        static let tokenField = DoorFieldDescriptor.string("token", "https token URL.", required: true)
        static let clientIDField = DoorFieldDescriptor.string("client_id", required: true)
        static let scopesField = DoorFieldDescriptor.string("scopes", "Space-separated.")
        static let redirectField = DoorFieldDescriptor.string("redirect", "A registered http://127.0.0.1:<port>/<path>; default any port, /callback.")
        static let authField = DoorFieldDescriptor.choice("client_auth", ["body", "basic"], """
            How the client authenticates at the token endpoint: in the body (default) or by HTTP Basic.
            """)
        static let doorFields = NonEmptyFields(authorizeField, deviceField, tokenField, clientIDField, scopesField, redirectField, authField)
        static let constraints: [String: JSONValue] = ["description": .string("""
            For secret:<name> from a service's OAuth sign-in: NativeAgent runs it (code flow with PKCE, loopback redirect; or a \
            device sign-in) and keeps and renews the token. A client secret the service issued is typed by the person on the \
            card, never sent here.
            """)]
        let authorize: String?
        let device: String?
        let token: String
        let clientID: String
        let scopes: String?
        let redirect: String?
        let clientAuth: String?
        let additional: [String: JSONValue]

        init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
            authorize = try door.string(Self.authorizeField)
            device = try door.string(Self.deviceField)
            token = try door.requiredString(Self.tokenField)
            clientID = try door.requiredString(Self.clientIDField)
            scopes = try door.string(Self.scopesField)
            redirect = try door.string(Self.redirectField)
            clientAuth = try door.string(Self.authField)
            additional = door.takeAdditionalFields()
        }
    }

    struct Option: DoorObjectSchema {
        static let idField = DoorFieldDescriptor.string("id", required: true)
        static let labelField = DoorFieldDescriptor.string("label", required: true)
        static let detailField = DoorFieldDescriptor.string("detail")
        static let doorFields = NonEmptyFields(idField, labelField, detailField)
        static let constraints: [String: JSONValue] = [:]
        let option: InlineInteraction.Option

        init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
            let id = try door.requiredString(Self.idField)
            let label = try door.requiredString(Self.labelField)
            let detail = try door.string(Self.detailField)
            let extra = door.takeAdditionalFields()
            option = .init(id: id, label: label, detail: detail ?? extra["description"]?.stringValue)
        }
    }

    static let kindField = DoorFieldDescriptor.choice("kind",
        ["connector", "permission", "model_choice", "api_key", "capability", "choose"],
        "What is needed.", required: true)
    static let targetField = DoorFieldDescriptor.string("target", """
        Canonical id. connector: slack, telegram, mail (Apple Mail), chrome (Chrome extension), iphone (pair iPhone/iPad). \
        permission: calendar, reminders, contacts, mail, messages, notes, music, notify_mac, notify_mobile, spotlight, \
        scheduler (Trust switches); a macOS grant alone: privacy:<grant>, grant one of \(SystemPermissionCapability.requestable); \
        Mac control: shell, file_ops, applescript:<bundle_id> (macOS Automation for one app), jxa, accessibility, system. \
        api_key: openai, anthropic, openrouter, moonshot, meta, or secret:<name> for a keyring secret; sign-in: \
        openai_oauth_direct (ChatGPT), anthropic_oauth_direct (Claude), xai (Grok). capability: image_generation, \
        screen_capture, tts. Image understanding is your settings.image_understanding setting. \
        model_choice: a Providers group id. Omit for choose.
        """)
    static let whyField = DoorFieldDescriptor.string("why", "One sentence: why this is needed, here, now.", required: true)
    static let declineConsequenceField = DoorFieldDescriptor.string("decline_consequence", """
        What happens if they say no. Required for choose; a sensible default is used otherwise.
        """)
    static let alsoNeededField = DoorFieldDescriptor.strings("also_needed", """
        For permission: the other targets this same card asks for, in the forms target takes, so everything still off is one \
        card the person grants once; the card walks them least friction first.
        """)
    static let hostsField = DoorFieldDescriptor.strings("hosts", """
        For secret:<name>: the hosts (api.example.com) a request may carry it to. Where it is already kept for stays granted \
        unless only:true.
        """)
    static let programsField = DoorFieldDescriptor.strings("programs", """
        For secret:<name>: the programs (npx, or an executable's path) it may be handed to; the grant binds each to the file \
        that runs now, and a changed one asks again.
        """)
    static let replaceField = DoorFieldDescriptor.bool("replace", """
        For secret:<name>: ask again though it is kept (expired, revoked, or the person wants a new one); the kept value stays \
        until the new one is.
        """)
    static let removeField = DoorFieldDescriptor.bool("remove", "For secret:<name>: ask the person to remove it from the keyring.")
    static let onlyField = DoorFieldDescriptor.bool("only", """
        For secret:<name>: grant only the hosts and programs named, so it stops going anywhere else it is kept for; the card \
        says which stop.
        """)
    static let signInField = DoorFieldDescriptor.object("sign_in", SignIn.self)
    static let modeField = DoorFieldDescriptor.choice("mode",
            ["read", "write", "read_write"],
            """
                For permission: which axis the blocked call actually needed. Say read or write when that is all it was - omitting \
                this asks for both, which is a wider grant than the work required.
                """
        )
    static let titleField = DoorFieldDescriptor.string("title", "For choose: the question.")
    static let scopeNounField = DoorFieldDescriptor.string("scope_noun", """
        For model_choice: the single piece of work this should apply to, e.g. \"this image\". Supplying it scopes the choice to \
        this request and offers the permanent change as the secondary action.
        """)
    static let optionsField = DoorFieldDescriptor.objects("options", Option.self, description: "For choose and model_choice: the answers, each with a stable id and a label.")
    static let doorFields = [
        kindField, targetField, whyField, declineConsequenceField, alsoNeededField, hostsField, programsField,
        replaceField, removeField, onlyField, signInField, modeField, titleField, scopeNounField, optionsField,
    ]
    let kind: String
    let target: String?
    let why: String
    let declineConsequence: String?
    let alsoNeeded: [String]?
    let hosts: [String]?
    let programs: [String]?
    let replace: Bool?
    let remove: Bool?
    let only: Bool?
    let signIn: SignIn?
    let mode: String?
    let title: String?
    let scopeNoun: String?
    let options: [Option]?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.string(Self.kindField)!
        target = try door.string(Self.targetField)
        why = try door.requiredString(Self.whyField)
        declineConsequence = try door.string(Self.declineConsequenceField)
        alsoNeeded = try door.strings(Self.alsoNeededField)
        hosts = try door.strings(Self.hostsField)
        programs = try door.strings(Self.programsField)
        replace = try door.bool(Self.replaceField)
        remove = try door.bool(Self.removeField)
        only = try door.bool(Self.onlyField)
        signIn = try door.object(Self.signInField, as: SignIn.self)
        mode = try door.string(Self.modeField)
        title = try door.string(Self.titleField)
        scopeNoun = try door.string(Self.scopeNounField)
        options = try door.objects(Self.optionsField, as: Option.self)
    }
}

struct ImageGenerateArgs: DoorArgs {
    static let promptField = DoorFieldDescriptor.string("prompt", """
        Describe the image or the edits, identifying what each reference supplies and what must stay unchanged.
        """, required: true)
    static let sizeField = DoorFieldDescriptor.string("size", """
        Codex: prompt preference, e.g. 16:9 or auto; inspect actual dimensions. OpenAI API: forwarded as size, subject to its \
        model’s limits.
        """)
    static let qualityField = DoorFieldDescriptor.string("quality", """
        low, medium, high or auto; visual quality, not thinking effort. Codex: prompt preference, fulfillment unknown unless \
        reported. OpenAI API: forwarded as quality.
        """)
    static let outputFormatField = DoorFieldDescriptor.string("output_format", """
        png (default), jpeg or webp. Codex: prompt preference; decoded bytes determine extension. OpenAI API: forwarded as \
        output_format.
        """)
    static let backgroundField = DoorFieldDescriptor.string("background", """
        Codex only: auto, opaque or transparent prompt preference; transparency requires PNG/WebP. Inspect alpha. Omit on \
        OpenAI API.
        """)
    static let nField = DoorFieldDescriptor.int("n", "Image count, default 1, clamped to 1–4. Codex requests are independent; OpenAI API receives n.")
    static let timeoutSecondsField = DoorFieldDescriptor.int("timeout_seconds", """
        Codex only: whole run timeout, 30–1800 seconds, default 600. OpenAI API uses a fixed 180-second request timeout.
        """)
    static let referencedImagePathsField = DoorFieldDescriptor.strings("referenced_image_paths", """
        Codex only: up to four authorized local PNG/JPEG/WebP files, 8 MiB each, 20 MiB total; copied and attached to the run. \
        Resupply for each edit. Omit or [] on OpenAI API.
        """)
    static let actionField = DoorFieldDescriptor.string("action", "Codex only: auto (default), generate or edit; edit requires references. Omit on OpenAI API.")
    static let doorFields = [
        promptField, sizeField, qualityField, outputFormatField, backgroundField, nField, timeoutSecondsField,
        referencedImagePathsField, actionField,
    ]
    let prompt: String
    let size: String?
    let quality: String?
    let outputFormat: String?
    let background: String?
    let n: Int?
    let timeoutSeconds: Int?
    let referencedImagePaths: [String]?
    let action: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        prompt = try door.requiredString(Self.promptField)
        size = try door.string(Self.sizeField)
        quality = try door.string(Self.qualityField)
        outputFormat = try door.string(Self.outputFormatField)
        background = try door.string(Self.backgroundField)
        n = try door.numberLiteral(Self.nField)?.wire.exactIntegerValue
        timeoutSeconds = try door.numberLiteral(Self.timeoutSecondsField)?.wire.exactIntegerValue
        referencedImagePaths = try door.strings(Self.referencedImagePathsField)
        action = try door.string(Self.actionField)
    }
}

struct TimeNowArgs: DoorArgs {
    static let doorFields: [DoorFieldDescriptor] = []

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
    }
}

struct RecentTraceSummaryArgs: DoorArgs {
    static let limitField = DoorFieldDescriptor.int("limit", "Maximum events per page, default 10, capped at 50.")
    static let offsetField = DoorFieldDescriptor.int("offset", "Continuation event offset; copy from next_call.")
    static let beforeField = DoorFieldDescriptor.string("before", """
        Continuation anchor timestamp; copy from next_call. Reading continues from the newest retained event at or before it.
        """)
    static let viewField = DoorFieldDescriptor.choice("view", ["receipts", "usage", "model_calls"], """
        Use receipts for compact tool.dispatch end receipts across all conversations unless session_id is explicit; non-read \
        actions precede reads. usage sums recorded model calls across all conversations, defaults since to today, and reports \
        missing measurements and retention coverage. Omit for all event kinds.
        """)
    static let byField = DoorFieldDescriptor.choice("by", ["model", "surface", "day"], "Usage grouping; default model. day uses local calendar dates.")
    static let effectsOnlyField = DoorFieldDescriptor.bool("effects_only", """
        Successful non-read receipts with bounded target/effect previews; excludes previews and explicit no-effect results. \
        Does not prove effects still persist.
        """)
    static let sinceField = DoorFieldDescriptor.string("since", """
        today (local midnight) or an ISO-8601 timestamp with Z or an offset. Reads the complete retained time window without \
        tail scan limits; response pagination still applies.
        """)
    static let completedTurnsField = DoorFieldDescriptor.int("completed_turns", """
        Last N finished turns, capped at 50; limit and the total response budget still apply. Includes completed, failed and \
        cancelled turns.
        """)
    static let kindField = DoorFieldDescriptor.string("kind", "Optional event kind substring, e.g. tool.dispatch or turn.terminal; action names belong in name.")
    static let nameField = DoorFieldDescriptor.string("name", """
        Optional exact action filter, e.g. mac.clipboard_read. For returned values add fields:[name,args,result,receipt].
        """)
    static let statusField = DoorFieldDescriptor.string("status", "Optional exact status filter.")
    static let scopeField = DoorFieldDescriptor.choice("scope", ["conversation", "all"], """
        Which life the read covers. Omitted or conversation: an event read stays in the calling conversation (receipts and usage \
        already span all). all: every conversation and the agent's background life (the mind, attention, abilities; their rows \
        have session_id null). Takes no session_id.
        """)
    static let sessionIDField = DoorFieldDescriptor.string("session_id", """
        Optional exact conversation id filter. Includes sibling events from turns belonging to that conversation. For every \
        conversation and the background life, use scope:all.
        """)
    static let turnIDField = DoorFieldDescriptor.string("turn_id", "Optional exact turn id filter.")
    static let receiptIDField = DoorFieldDescriptor.string("receipt_id", """
        Exact dispatch receipt id, including from an expired result handle or a life row; found in any conversation; reads \
        retained evidence without repeating the operation.
        """)
    static let fieldsField = DoorFieldDescriptor.strings("fields", """
        Optional payload keys, with or without a turn window. Up to 16 keys, 80 characters each; values share an 8 KiB cap.
        """, minItems: 1, maxItems: 16, maxItemLength: 80)
    static let doorFields = [
        limitField, offsetField, beforeField, viewField, byField, effectsOnlyField, sinceField,
        completedTurnsField, kindField, nameField, statusField, scopeField, sessionIDField, turnIDField,
        receiptIDField, fieldsField,
    ]
    let limit: DoorNumberLiteral?
    let offset: DoorNumberLiteral?
    let before: String?
    let view: String?
    let by: String?
    let effectsOnly: Bool?
    let since: String?
    let completedTurns: DoorNumberLiteral?
    let kind: String?
    let name: String?
    let status: String?
    let scope: String?
    let sessionID: String?
    let turnID: String?
    let receiptID: String?
    let fields: [String]?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        limit = try door.numberLiteral(Self.limitField)
        offset = try door.numberLiteral(Self.offsetField)
        before = try door.string(Self.beforeField)
        view = try door.string(Self.viewField)
        by = try door.string(Self.byField)
        effectsOnly = try door.bool(Self.effectsOnlyField)
        since = try door.string(Self.sinceField)
        completedTurns = try door.numberLiteral(Self.completedTurnsField)
        kind = try door.string(Self.kindField)
        name = try door.string(Self.nameField)
        status = try door.string(Self.statusField)
        scope = try door.string(Self.scopeField)
        sessionID = try door.string(Self.sessionIDField)
        turnID = try door.string(Self.turnIDField)
        receiptID = try door.string(Self.receiptIDField)
        fields = try door.strings(Self.fieldsField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.limitField.name] = limit?.wire
        fields[Self.offsetField.name] = offset?.wire
        fields[Self.beforeField.name] = before.map(JSONValue.string)
        fields[Self.viewField.name] = view.map(JSONValue.string)
        fields[Self.byField.name] = by.map(JSONValue.string)
        fields[Self.effectsOnlyField.name] = effectsOnly.map(JSONValue.bool)
        fields[Self.sinceField.name] = since.map(JSONValue.string)
        fields[Self.completedTurnsField.name] = completedTurns?.wire
        fields[Self.kindField.name] = kind.map(JSONValue.string)
        fields[Self.nameField.name] = name.map(JSONValue.string)
        fields[Self.statusField.name] = status.map(JSONValue.string)
        fields[Self.scopeField.name] = scope.map(JSONValue.string)
        fields[Self.sessionIDField.name] = sessionID.map(JSONValue.string)
        fields[Self.turnIDField.name] = turnID.map(JSONValue.string)
        fields[Self.receiptIDField.name] = receiptID.map(JSONValue.string)
        fields[Self.fieldsField.name] = self.fields.map { .array($0.map(JSONValue.string)) }
        return fields
    }
}

extension ChatActions {
    static let turnActions: [ActionDescriptor] = {
        [
            ActionDescriptor(ToolResultPageArgs.self, name: "tool_result_page",
                courier: .resultPage, run: { context, input in
                    await context.client.impl_tool_result_page(turn: context.turn, input: input)
                }, toolClass: .read, capabilities: [.catalogRead, .toolCall],
                description: """
                    Read a retained result without repeating its action, across turns and relaunches. An untrusted-steered turn reads only its \
                    conversation's results; other turns read any handle. Bodies over 4 MiB keep their head and say how many bytes were cut. Follow \
                    next_call; continue:true resumes this turn's last read. Exact result_handle/page also works. Query returns the \
                    lines that match in source order, each with its path, line or offset, the adjacent lines and section_page, the page a \
                    read without query shows its whole section on; it cannot search unread source content. \
                    source_continues means the answer held only part of its source: its next_call reads on, pages never do. Read-only, redacted; \
                    retained for the record's 14-day detail horizon, including after relaunch.
                    """
            ),
            // A request addressed to the person is a question, not an effect: the person's own answer on the card is the decision, so no posture or steer puts
            // a card in front of the card.
            ActionDescriptor(RequestInteractionArgs.self, name: "request_interaction",
                run: { context, input in
                    await context.client.impl_request_interaction(invocation: context.invocation, input: input)
                }, toolClass: .read, capabilities: [.toolCall],
                description: """
                    Raise an inline setup/choice card; required kind and why, with canonical target except choose. Secrets go only in cards, never \
                    chat. api_key supports provider sign-in or keys; reach secret:<name> uses api_key target:secret:<name> with hosts/programs and \
                    optional sign_in. The person supplies the secret on the card; it stays in the keyring and code uses {{secret:<name>}} without \
                    seeing it. Connector cards require an explicit connect/add/set up/enable request; ordinary read/status requests only report the \
                    blocker. Other kinds may request a known missing prerequisite. Cards settle to receipts; configured targets return without a \
                    card. Connector/permission/capability cards are nonblocking: skip the unavailable step and continue. API-key/model/choice cards \
                    stop the turn until the person acts. choose requires title, nonempty options and decline_consequence. Canonical targets and \
                    controls are listed in parameters; unsupported targets refuse. For participants use agent.connect; for helpers bot.create. \
                    Example: {\"kind\":\"connector\",\"target\":\"slack\",\"why\":\"Connect Slack as requested.\",\"decline_consequence\":\"I will \
                    continue without Slack.\"}.
                    """
            ),
            ActionDescriptor(ImageGenerateArgs.self, name: "image_generate",
                run: { context, input in
                    await context.client.dispatchImageGenerate(turn: context.turn, invocation: context.invocation, input: input,
                        makeReference: context.transportMetadata["__make_ref"]?.stringValue, surface: context.surface)
                },
                toolClass: .write, capabilities: [.appDataWrite, .imageGeneration, .networkWrite, .toolCall],
                description: """
                    Generate raster images with the Work account when it can draw, else your ChatGPT sign-in: Codex uses \
                    image_gen.imagegen; OpenAI uses its separately billed image API. Only Codex supports edits/local references here. Provider \
                    and image model are route-owned, never selected by the call's arguments; with neither able to draw, it asks for a Work choice that can. \
                    Requires admitted Full Mac or Trust’s image-generation permission. Saves under data/generated_images/; returns paths, \
                    thumbnails and a receipt.\u{20}
                    """ + CodexImageGenerationHelp.usage
            ),
            ActionDescriptor(ContextLookupArgs.self, name: "context_lookup",
                run: { context, input in
                    try await context.client.impl_context_lookup(args: input)
                }, toolClass: .read, capabilities: [.toolCall],
                description: "Find NativeAgent capabilities and where to use them."
            ),
            ActionDescriptor(ScratchpadReadArgs.self, name: "scratchpad_read",
                run: { context, input in
                    try await context.client.impl_scratchpad_read(args: input)
                }, toolClass: .read,
                description: """
                    Read the current conversation scratchpad written by /scratch controls or app action chat.scratch. The app fills in \
                    session_id when available.
                    """
            ),
            ActionDescriptor(TimeNowArgs.self, name: "time_now",
                run: { _, _ in
                    ClockReply.read([:]) { $0.chat }
                }, toolClass: .read, capabilities: [.toolCall],
                description: """
                    Return the current date and time in multiple representations: ISO-8601 UTC, ISO-8601 local timezone, epoch seconds, and a \
                    human-readable summary including weekday + day of year. Zero inputs.
                    """
            ),
            ActionDescriptor(RecentTraceSummaryArgs.self, name: "recent_trace_summary",
                run: { context, input in
                    try await context.client.impl_recent_trace_summary(turn: context.turn, invocation: context.invocation, input: input)
                }, toolClass: .read, capabilities: [.toolCall],
                description: """
                    Read traces and receipts from the life record. view:receipts returns compact tool-end evidence with action, target, effect \
                    and time; effects_only filters successful non-read receipts, and since accepts today or an ISO-8601 timestamp. completed_turns selects \
                    the last N finished turns, excluding unfinished turns; scan limits are reported. name and turn_id select exact evidence. \
                    Results are bounded to 32 KiB including metadata; follow next_call for continuation. fields reads bounded, secret-redacted \
                    values. Every read carries lives: the app's starts and how each ended (quit, crash, kill), so a restart is never missed.
                    """
            ),
        ]
    }()
}
