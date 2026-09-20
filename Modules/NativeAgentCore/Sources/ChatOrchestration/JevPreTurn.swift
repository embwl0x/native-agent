import Foundation
import PersistenceCore
import TrustCenter

/// Lane 1 — the pre-turn brief.
///
/// One call, fired the moment the turn's identity exists and awaited before
/// the context is built, so what it finds can ride this turn rather than the
/// next one. It produces ONE thing: at most three short lines of context, and
/// only when there is something actionable to say. Nothing reaches the agent
/// when nothing is useful — there is no "all checks passed" line.
///
/// Tool-family preload is SHADOW. The lane still asks a noul per family and
/// still records which family it would have loaded ahead, but nothing is
/// promoted into the turn's tools from here: the drive showed no demonstrated
/// benefit, and schemas the model never calls are not free. The rows stay so
/// the lane can be measured before it is either revived or dropped.
///
/// What deliberately does NOT reach the agent: whether a card looks likely
/// (cards follow this app's real permission rules, never a guess) and any
/// urgency below a high, confident reading (no invented urgency). Both are in
/// the log either way.
enum JevPreTurn {

    struct Brief: Sendable {
        /// The family this lane WOULD have loaded ahead — the strongest one
        /// past the load-ahead tier with the request gate met. Log-only: the
        /// preload is in shadow and nothing is promoted from it.
        var wouldPreloadFamily: String?
        /// The strongest family at the suggest tier, whether or not it reached
        /// the load-ahead tier. Log-only — nothing mechanical reads this.
        var suggestedFamily: String?
        var suggestedScore: Double?
        /// Every family at the suggest tier, strongest first, as
        /// `[id, score]` pairs. Log-only.
        var familyScores: [[String]] = []
        /// At most three lines, already worded for the agent.
        var lines: [String] = []
        var turnID: String
        var sessionID: String
        /// Whether the lines were actually appended to this turn's context —
        /// the last point this lane can observe, not proof the model read
        /// them. Set by the caller that appends them: a brief whose context
        /// build produced nothing has lines that reached nobody.
        var linesDelivered: Bool = false
    }

    /// A family is worth naming in the log at this much.
    private static let suggestTier = 0.30
    /// A family would have been worth having ready before the first attempt at
    /// this much. Log-only since the preload went to shadow.
    private static let loadAheadTier = 0.50
    /// `has_request` gated the preload: a message that asks for nothing needs
    /// nothing loaded ahead of it. Still recorded, still mechanically inert.
    private static let requestGate = 0.50

    /// One noul PER FAMILY, asked in the single pre-turn call.
    ///
    /// This replaced a single `choice` over all twenty families plus `none`
    /// and `need_context`. That question folded: it answered `none 0.91` on
    /// "Read the file at ... then remember ...", a message naming two families
    /// outright, and the shadow tests showed the same collapse toward `none`
    /// and `need_context` generally. Twenty independent yes/no readings do not
    /// compete with each other, so a message needing two families scores both,
    /// and the lane stops having to pick a winner it was never able to pick.
    ///
    /// `none` and `need_context` are gone with it: "no family scored" IS the
    /// none answer, and it needs no option of its own.
    ///
    /// The prefix matters — `JevAnswers` folds `family.*` into one log field.
    private static let familyKeyPrefix = "family."

    static func familyQuestions() -> [String: JevQuestion] {
        var questions: [String: JevQuestion] = [:]
        for id in JevToolCatalog.purposesByID.keys {
            questions[familyKeyPrefix + id] = .noul(
                instructions: JevInstructions(
                    question: "Does the person's latest `message`, given `recent`, need the `\(id)` family?",
                    compare: ["`message`", "`recent`", "`tools.\(id)`"],
                    focus: "Judge the requested action, not topics mentioned in a consultation or report. "
                        + "Respect explicit read-only/no-intervention constraints. Answer for THIS family "
                        + "alone; a message may need more than one."
                ),
                criteria: familyCriteria[id]
            )
        }
        return questions
    }

    /// Concrete boundaries from JevToolCatalog's family members, not tool-loading rules.
    private static let familyCriteria: [String: JevNoulCriteria] = [
        "files": familyCriteria(
            what: "The request needs reading, writing, searching or listing files on disk",
            notFor: "A document already pasted into the conversation, or a page on a remote service",
            example: "Read the README in this project folder",
            counterexample: "Summarize the document I pasted above"
        ),
        "shell_builder": familyCriteria(
            what: "The request needs shell commands, patches, local git or working-tree inspection, builds, tests, "
                + "app installation or restart, system information, or listing remote nodes and running commands on them",
            notFor: "Discussing a build report or explaining a command without running it",
            example: "Run swift build in this checkout",
            counterexample: "Explain this pasted compiler error; do not run anything"
        ),
        "mac_control": familyCriteria(
            what: "The request needs observing, watching, waiting for or operating the Mac's screen, windows, menus, "
                + "apps or clipboard, checking accessibility status, waking the display, reading app-usage activity, "
                + "or sending Mac or mobile notifications",
            notFor: "Discussing a screenshot already supplied, or reading the agent app's own settings",
            example: "Look at the window I have open",
            counterexample: "Does the screenshot above look readable?"
        ),
        "memory_recall": familyCriteria(
            what: "The request needs recalling, listing, saving, correcting or forgetting long-term memory, "
                + "searching or rebuilding the knowledge graph, reading the dream diary, or reviewing pending memory moments",
            notFor: "Using a fact already in the current exchange or finding the exact text of an old chat",
            example: "Remember for next time that I prefer morning meetings",
            counterexample: "What preference did I just tell you above?"
        ),
        "chat_history": familyCriteria(
            what: "The request needs searching or reading chat sessions, transcripts, saved shelf entries, "
                + "the session scratchpad or recent turn-trace summaries",
            notFor: "Rereading messages already in context or saving a fact to long-term memory",
            example: "Find the exact reply you sent in last week's chat about the release",
            counterexample: "Remember my release preference for next time"
        ),
        "web_research": familyCriteria(
            what: "The request needs fetching a public web page for online evidence",
            notFor: "General knowledge or text already supplied; private inboxes and service records",
            example: "Read this public documentation URL and summarize it",
            counterexample: "Explain the documentation excerpt I pasted above"
        ),
        "mail": familyCriteria(
            what: "The request needs reading, searching, sending, replying to, archiving, deleting or marking "
                + "actual email as read, or checking the Gmail connection",
            notFor: "Drafting email text in chat, physical mail, Slack posts or iMessages",
            example: "Find the invoice email in my inbox",
            counterexample: "Draft a reply to this pasted email; do not send it"
        ),
        "calendar_reminders": familyCriteria(
            what: "The request needs listing, creating, modifying or deleting calendar events, creating or "
                + "completing reminders, listing reminders due today, or checking the Google Calendar connection",
            notFor: "Discussing a possible schedule or tracking ongoing work on the Desk",
            example: "What events are on my calendar tomorrow?",
            counterexample: "Would a morning meeting be better than an afternoon one?"
        ),
        "slack": familyCriteria(
            what: "The request needs Slack channel discovery, message search, posting or connection status",
            notFor: "Discussing a pasted Slack message or drafting text without posting",
            example: "Search Slack for the release announcement",
            counterexample: "Rewrite this pasted Slack announcement; keep the draft here"
        ),
        "messaging": familyCriteria(
            what: "The request needs reading iMessage threads or sending a text message",
            notFor: "Email, Slack, messages to another agent or a draft kept in this conversation",
            example: "Text Alex that I am running ten minutes late",
            counterexample: "Ask the coding agent for its progress"
        ),
        "github": familyCriteria(
            what: "The request needs GitHub repository content, commits, issues, pull requests, notifications, "
                + "search, tracking discovery, project digests, mutations, visibility changes or connection status",
            notFor: "Local git commands or discussion of a pull request already pasted into the conversation",
            example: "Read the latest comments on this GitHub pull request",
            counterexample: "Show the uncommitted diff in this local checkout"
        ),
        "persona_self": familyCriteria(
            what: "The request needs reading or editing the agent's persona documents, listing, reading or saving "
                + "skills, inspecting the agent or runtime, or finding NativeAgent capabilities and where to use them",
            notFor: "Ordinary conversation about the agent's opinions, feelings or identity",
            example: "Read your saved skill for writing release notes",
            counterexample: "What do you think of the idea I just described?"
        ),
        "desk_bots_studio": familyCriteria(
            what: "The request needs reading or managing Desk items, references, pursuits, work logs and follow-ups, "
                + "creating, managing, running or asking standing bots, submitting or checking Workshop work, "
                + "or consulting, reading or curating Studio taste, journal, canon and shelf records",
            notFor: "Generic task discussion, an Apple Notes entry or a dated calendar reminder",
            example: "Add this follow-up to your Desk",
            counterexample: "Create an Apple Notes note with this shopping list"
        ),
        "agent_messaging": familyCriteria(
            what: "The request needs discovering or connecting agent contacts, messaging or invoking another agent, "
                + "reading its replies, running a swarm, checking delegated work, or reading or posting to the cross-agent task ledger",
            notFor: "Mentioning another agent in a report or asking this agent for its own opinion",
            example: "Ask Codex how the build is going",
            counterexample: "Codex finished the build; thanks for helping"
        ),
        "settings_selfadmin": familyCriteria(
            what: "The request needs discovering, listing, loading or unloading tools, paging a tool result, "
                + "reading the current date/time or the agent's inner state, asking the decision service for a typed "
                + "second opinion, creating or listing scheduled jobs, proposing, checking or withdrawing evolution "
                + "proposals, or asking the person for a connection, permission, model, API key, capability or bounded choice",
            notFor: "Explaining settings already shown, calendar appointments or operating another Mac app",
            example: "What time is it?",
            counterexample: "What appointments are on my calendar tomorrow?"
        ),
        "image": familyCriteria(
            what: "The request needs generating a new image or editing an existing image",
            notFor: "Looking at the current screen or describing an image already supplied",
            example: "Generate an illustration of a fox in the snow",
            counterexample: "Describe the illustration I attached"
        ),
        "mac_apps": familyCriteria(
            what: "The request needs Apple Notes, Music or Contacts content or operations",
            notFor: "General discussion of notes or music, long-term agent memory or screen clicks",
            example: "Find Alex's phone number in Contacts",
            counterexample: "Remember Alex's phone number for future conversations"
        ),
        "market_finance": familyCriteria(
            what: "The request needs market quotes, local or TradingView watchlists, or market-source configuration and readiness",
            notFor: "General discussion of money, arithmetic on supplied prices or placing trades",
            example: "Get the current AAPL quote",
            counterexample: "What is the total cost of three items at ten dollars each?"
        ),
        "notion": familyCriteria(
            what: "The request needs searching or reading Notion pages or checking its connection",
            notFor: "Text already pasted from Notion, local files or creating and editing Notion pages",
            example: "Find and read the launch plan in Notion",
            counterexample: "Summarize the Notion page text pasted above"
        ),
        "social_x": familyCriteria(
            what: "The request needs reading or searching X/Twitter posts, timelines or account information, or checking its connection",
            notFor: "Drafting a post in chat, posting or sending DMs, or the letter x in another context",
            example: "Read the latest posts in my X timeline",
            counterexample: "Draft a tweet about this release; keep it here"
        ),
    ]

    private static func familyCriteria(
        what: String, notFor: String, example: String, counterexample: String
    ) -> JevNoulCriteria {
        JevNoulCriteria(
            yes: JevOption(what: what, notFor: notFor, examples: [example]),
            no: JevOption(
                what: "The request can be completed without this family's operations",
                notFor: "A request needing this family alongside another family",
                examples: [counterexample]
            )
        )
    }

    /// Turn start: open the per-turn memo, then run the brief if lane 1 is on.
    ///
    /// ONE task, started beside the context build and awaited before the
    /// turn's context is final, so its lines can ride this turn. It has no
    /// mechanical effect: the tool-family scores are shadow, log-only.
    ///
    /// The memo is opened FIRST and unconditionally (a key present is the only
    /// condition): the tool-call lane reads it and must work with the pre-turn
    /// lane switched off. There is no minimum message length for the memo
    /// either — a two-letter message still dispatches tools, and a memo that
    /// was never opened would silence the tool-call lane for the whole turn.
    static func openTurn(
        message: String,
        sessionID: String,
        turnID: String,
        runID: String,
        surface: String,
        fromAgent: Bool = false,
        history: SessionHistoryReader,
        dataRoot: URL
    ) async throws -> Brief? {
        guard JevSettings.isConfigured(dataRoot: dataRoot) else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let recent = await lastExchange(sessionID: sessionID, runID: runID, history: history)
        await JevTurnMemo.shared.open(
            turnID: turnID, message: trimmed, recent: recent, sessionID: sessionID
        )
        return try await brief(
            message: trimmed, recent: recent, sessionID: sessionID,
            turnID: turnID, runID: runID, surface: surface,
            fromAgent: fromAgent, dataRoot: dataRoot
        )
    }

    /// Did this turn's message come from another agent?
    ///
    /// TRANSPORT METADATA ONLY. `originProvenance` is the out-of-band record
    /// the bridge stamps from its own lane table — the route it selected, never
    /// anything in the body — and `authored` is a closed two-case enum for
    /// exactly this reason. The peer-bridge surface is the same kind of fact,
    /// chosen by the transport before the turn exists. A message that SAYS it
    /// is from an agent, in any wording, cannot reach either one.
    static func messageCameFromAgent(surface: String) -> Bool {
        if ChatPersistenceContext.originProvenance?.authored == .agent { return true }
        return PeerTurnEffectPolicy.isPeerBridge(surface: surface)
    }

    // MARK: - Peer-update triage
    //
    // Asked only on a turn whose message came from another agent, in the SAME
    // single pre-turn call. One line, and only when there is a real gap.
    //
    // Nine ATOMIC nouls, not three choices. A choice makes the model pick one
    // winner across judgements that are not rivals: an update that claims
    // completion AND asks this agent a question had to be one or the other,
    // and "what is still missing" hid WHO owes the step inside the same pick
    // as WHAT is owed. One judgement per question, each with its own two ends
    // spelled out, and the line is composed here in code.

    /// The path every triage question reads, plus this agent's own profile.
    private static let updatePath = "`message`"

    static let triageQuestions: [String: JevQuestion] = [
        // --- What kind of update this is. Four independent readings; an
        // update can be several of them at once, and often is.
        "claims_completion": .noul(
            instructions: JevInstructions(
                question: "Does `message`, which came from another agent, state that a piece of "
                    + "work is finished, fixed or working?",
                inspect: updatePath,
                focus: "Judge the claim that is made, not whether it is true.",
                readsAgentProfile: true
            ),
            criteria: JevNoulCriteria(
                yes: JevOption(what: "It states a piece of work is finished, fixed or working"),
                no: JevOption(
                    what: "It makes no such statement",
                    notFor: "work under way that is not finished"
                )
            )
        ),
        "reports_blocker": .noul(
            instructions: JevInstructions(
                question: "Does `message` report something stuck that needs this agent to move?",
                inspect: updatePath,
                readsAgentProfile: true
            ),
            criteria: JevNoulCriteria(
                yes: JevOption(what: "It reports something stuck that needs this agent to move"),
                no: JevOption(what: "Nothing in it is stuck on this agent")
            )
        ),
        "asks_this_agent": .noul(
            instructions: JevInstructions(
                question: "Does `message` ask this agent something and wait on the answer?",
                inspect: updatePath,
                readsAgentProfile: true
            ),
            criteria: JevNoulCriteria(
                yes: JevOption(what: "It asks this agent something and waits on the answer"),
                no: JevOption(
                    what: "It asks this agent nothing it waits on",
                    notFor: "a rhetorical question, or one it answers itself"
                )
            )
        ),
        // Each gap reading asks what `message` EXPLICITLY asks for. "Still owed after
        // this update" invited an inference: on the first live turns a bare
        // "done and working" read as a look owed (0.77) and a question put to
        // this agent read as needing the person (0.83). Worded this way, tested
        // live on the same cases, they separate at 0.03 / 0.96 and 0.06 / 0.95.
        "needs_the_person": .noul(
            instructions: JevInstructions(
                question: "Does `message` say that something must wait for the HUMAN the agents work for?",
                inspect: updatePath,
                focus: "The human is a third party here: not this agent and not the agent that sent "
                    + "`message`.",
                readsAgentProfile: true
            ),
            criteria: JevNoulCriteria(
                yes: JevOption(
                    what: "`message` says a decision, permission or judgement must come from the human",
                    examples: ["that is the person's call", "ask them whether to publish"]
                ),
                no: JevOption(
                    what: "Nothing in `message` waits on the human",
                    notFor: "a question put to THIS agent; this agent being asked for its own opinion"
                )
            )
        ),
        // --- What supports the main claim. Two independent readings: what the
        // update POINTS AT, and what this agent has ALREADY SEEN for itself.
        "names_checkable_evidence": .noul(
            instructions: JevInstructions(
                question: "Does `message` name evidence for its MAIN claim that could be checked?",
                inspect: updatePath,
                focus: "Judge the support, not whether the claim sounds plausible.",
                readsAgentProfile: true
            ),
            criteria: JevNoulCriteria(
                yes: JevOption(
                    what: "It names a commit, diff, receipt, screenshot or file that could be checked",
                    notFor: "a claim that something WORKS supported only by a diff, which shows "
                        + "change, not behaviour; a claim about interaction supported only by a "
                        + "screenshot, which shows appearance"
                ),
                no: JevOption(
                    what: "The claim rests on the sending agent's own account and nothing else"
                )
            )
        ),
        "own_tool_result_shows_it": .noul(
            instructions: JevInstructions(
                question: "Does THIS agent's own tool result in `recent` already establish the "
                    + "MAIN claim `message` makes?",
                compare: [updatePath, "`recent`"],
                focus: "Judge the support, not whether the claim sounds plausible.",
                readsAgentProfile: true
            ),
            criteria: JevNoulCriteria(
                yes: JevOption(
                    what: "`recent` shows THIS agent's own tool result establishing the claim",
                    notFor: "any account in words, from either agent, that something was checked, "
                        + "passed or works; this agent having relayed, repeated or agreed with the report"
                ),
                no: JevOption(
                    what: "`recent` shows no such tool result of this agent's own",
                    notFor: "reading the absence of tool results in `recent` as evidence that "
                        + "nothing was checked; when `recent` does not carry this agent's tool "
                        + "results at all, the answer is unknown rather than no"
                )
            )
        ),
        // --- Who owes the next step. Three independent readings, because
        // ownership belongs to each action and not to the whole message: an
        // update can hand this agent a look AND say what the sender will do
        // next, and the sender's step does not cancel the agent's.
        "needs_this_agents_look": .noul(
            instructions: JevInstructions(
                question: "Does `message` explicitly ASK this agent to look at, open, read or accept "
                    + "something?",
                inspect: updatePath,
                focus: "Only what `message` itself asks for. A finished piece of work does not by "
                    + "itself ask for a look.",
                readsAgentProfile: true
            ),
            criteria: JevNoulCriteria(
                yes: JevOption(
                    what: "`message` explicitly asks this agent to look at, open, read, feel or accept "
                        + "something",
                    examples: ["please check the screen", "tell me if this reads right"]
                ),
                no: JevOption(
                    what: "`message` asks this agent for no look",
                    notFor: "a bare report that something is done, even when this agent usually "
                        + "accepts such work"
                )
            )
        ),
        "this_agent_owes_followup": .noul(
            instructions: JevInstructions(
                question: "Does `message` explicitly ASK this agent to do, write, build, send or fix "
                    + "something?",
                inspect: updatePath,
                focus: "Work to do, not something to look at and not a question to answer.",
                readsAgentProfile: true
            ),
            criteria: JevNoulCriteria(
                yes: JevOption(
                    what: "`message` asks this agent to produce or change something",
                    examples: ["please write the three lines and send them back"]
                ),
                no: JevOption(
                    what: "`message` asks this agent for no work",
                    notFor: "a request to look at or accept something; a question put to this agent; "
                        + "a step the sender says it will take itself"
                )
            )
        ),
        "sender_will_do_next_step": .noul(
            instructions: JevInstructions(
                question: "Does the sending agent say it will take the next step itself?",
                inspect: updatePath,
                readsAgentProfile: true
            ),
            criteria: JevNoulCriteria(
                yes: JevOption(
                    what: "The remaining step belongs to the sending agent, which has said what it "
                        + "will do next"
                ),
                no: JevOption(what: "The sending agent names no next step of its own")
            )
        ),
    ]

    /// Confidence a triage reading needs before it is used in the line.
    private static let triageBar = 0.6
    /// A reading this low is a confident no. Between this and the bar the
    /// question is simply not settled, and nothing is said either way.
    private static let triageFloor = 0.3

    /// The one triage line, or nil when there is no gap to name.
    ///
    /// A gap is SOMETHING STILL OWED HERE — this agent's look, a follow-up
    /// this agent owes, or the person's decision — read at the bar. A clearly
    /// attributed completion report is not a gap merely because this agent has
    /// not independently checked it; warning on that alone made the line fire
    /// on work that was simply done.
    ///
    /// Each gap stands on its own. `sender_will_do_next_step` is asked and
    /// logged and has NO say in whether the line is emitted: "I'll read the
    /// log; please check the screen" carries the sender's next step and a look
    /// owed by this agent, and the sender's step must not swallow the agent's
    /// gap. The one distinction that matters is inside the questions
    /// themselves — `this_agent_owes_followup` says BY THIS AGENT and excludes
    /// work the sender says it will do itself.
    ///
    /// Kind and support ride along as context clauses when the line is
    /// emitted, and every noul is logged either way.
    static func triageLine(_ answers: JevAnswers) -> String? {
        func at(_ id: String) -> Bool { (answers.noul(id) ?? 0) >= triageBar }
        let look = at("needs_this_agents_look")
        let followUp = at("this_agent_owes_followup")
        let person = at("needs_the_person")
        // The only thing that opens the line: a gap owed HERE.
        guard look || followUp || person else { return nil }

        var clauses: [String] = []
        let completion = at("claims_completion")
        let blocker = at("reports_blocker")
        if completion { clauses.append("completion claim") }
        if blocker { clauses.append("blocker") }
        if completion || blocker, let support = supportClause(answers) { clauses.append(support) }
        // Each clause names the owner of what is missing, because "still
        // missing" alone says neither whose action it is nor whose move.
        if look { clauses.append("your look is still owed") }
        if followUp { clauses.append("you still owe a follow-up") }
        if person { clauses.append("the person's decision is still needed") }
        return "Update triage: " + clauses.joined(separator: "; ") + "."
    }

    /// What supports the claim, or nil when that is not settled.
    ///
    /// "My own tool result shows it" needs actual supporting context to read;
    /// when `recent` does not carry it the honest answer is UNKNOWN, and an
    /// unknown must not come out as "nothing checked". So only a confident
    /// reading speaks: a confident yes on either question, or a confident no
    /// on both. Anything between them says nothing at all.
    private static func supportClause(_ answers: JevAnswers) -> String? {
        guard let checked = answers.noul("own_tool_result_shows_it"),
              let named = answers.noul("names_checkable_evidence") else { return nil }
        if checked >= triageBar { return nil }
        if named >= triageBar { return "linked evidence not yet checked" }
        if named <= triageFloor, checked <= triageFloor { return "reported only, nothing checked" }
        return nil
    }

    /// Fire the brief. Returns nil whenever the lane is off, the key is
    /// missing, or anything at all goes wrong. Cancellation propagates.
    static func brief(
        message trimmed: String,
        recent: [String],
        sessionID: String,
        turnID: String,
        runID: String,
        surface: String,
        fromAgent: Bool = false,
        dataRoot: URL
    ) async throws -> Brief? {
        guard JevSettings.isEnabled(.preTurn, dataRoot: dataRoot) else { return nil }
        guard trimmed.count >= 3 else { return nil }

        let state: [String: JSONValue] = [
            "message": .string(trimmed.jevTruncated(2000)),
            "recent": .array(recent.map(JSONValue.string)),
            "tools": .object(JevToolCatalog.purposesByID.mapValues(JSONValue.string)),
            "surface": .string(surface),
        ]
        var questions: [String: JevQuestion] = familyQuestions()
        // `load_ahead` is gone: it asked about "that family" when there is no
        // longer a single one, and the per-family noul already carries the
        // strength that question was trying to add. `has_request` is the gate
        // in its place.
        for (id, question) in [
            "has_request": JevQuestion.noul(
                instructions: JevInstructions(question: "Does `message`, interpreted using `recent`, ask for something to be done or answered?")
            ),
            "has_status_update": .noul(
                instructions: JevInstructions(question: "Does `message` contain a status update, result or changed circumstance, "
                    + "independently of whether it ALSO contains a request? Interpret using `recent`.")
            ),
            "memory": .noul(
                instructions: JevInstructions(question: "Would something saved in long-term memory from an earlier conversation "
                    + "change how this turn should be answered? Remembering what is already in `recent` is not that.")
            ),
            "card_likely": .noul(
                instructions: JevInstructions(question: "Is completing `message` likely to change something outside this conversation, "
                    + "such that the person would expect to be asked first?")
            ),
            "no_tools_needed": .noul(
                instructions: JevInstructions(
                    question: "Can `message`, interpreted with `recent`, be answered well with no tool at all?",
                    compare: ["`message`", "`recent`"],
                    focus: "Judge whether the requested answer or action needs anything beyond the supplied context."
                ),
                criteria: JevNoulCriteria(
                    yes: JevOption(
                        what: "Conversation, opinion, affection or an answer using only what is already in context",
                        notFor: "Requests needing a fresh fact, a file, the screen, a message sent or a change made",
                        examples: ["Thanks, that helped", "Summarize the text I pasted above"]
                    ),
                    no: JevOption(
                        what: "Completing the request needs new evidence or an action through a tool",
                        notFor: "Merely mentioning a tool or service, or drafting text to keep in this conversation",
                        examples: ["Read the file in my project folder", "Send Alex this message"]
                    )
                )
            ),
            "urgency": .score(
                instructions: JevInstructions(question: "How urgent is `message` for the agent to act on now?"),
                levels: [
                    "idle chat, no action wanted",
                    "a request that can wait for the next natural pause",
                    "a request to act now",
                    "a blocker the person is waiting on this second",
                ]
            ),
        ] { questions[id] = question }
        // Same single call: the triage questions ride it, and only when the
        // transport says this message came from another agent.
        if fromAgent {
            for (id, question) in triageQuestions { questions[id] = question }
        }

        let context = JevLogContext(sessionID: sessionID, turnID: turnID, runID: runID)
        guard let answers = try await JevClient.shared.ask(
            lane: .preTurn, state: state, questions: questions,
            summary: trimmed, dataRoot: dataRoot, context: context
        ) else { return nil }

        var brief = Brief(turnID: turnID, sessionID: sessionID)
        let request = answers.noul("has_request") ?? 0

        // The families that scored, strongest first. Ties break on name so the
        // same reading always produces the same row.
        let ranked = JevToolCatalog.purposesByID.keys
            .compactMap { id -> (id: String, score: Double)? in
                guard let score = answers.noul(familyKeyPrefix + id) else { return nil }
                return (id, score)
            }
            .filter { $0.score >= suggestTier }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }

        // Two tiers, both log-only now. The suggest tier names the strongest
        // family; the load-ahead tier, with the `has_request` gate, records
        // what this lane WOULD have loaded ahead. Neither promotes anything —
        // the preload is in shadow until the rows show it earns its bytes.
        if let top = ranked.first {
            brief.suggestedFamily = top.id
            brief.suggestedScore = top.score
            if top.score >= loadAheadTier, request >= requestGate {
                brief.wouldPreloadFamily = top.id
            }
        }
        brief.familyScores = ranked.map { [$0.id, JevAnswers.round2($0.score)] }

        // Lines. Ordered by how much they change what the agent should do, cut
        // at three, and each one says what to do rather than scoring the person.
        var lines: [String] = []
        // The triage line goes FIRST and counts toward the same cap of three:
        // on a turn that came from another agent it is the line most likely to
        // change what happens next.
        if fromAgent, let triage = triageLine(answers) { lines.append(triage) }
        // ANOTHER AGENT'S message only. On the person's own messages this fired
        // on affection, jokes and thinking aloud: a person sharing something is
        // an invitation to engage, not an absence of work to classify. Both
        // nouls are still asked and logged on every turn.
        let status = answers.noul("has_status_update") ?? 0
        if fromAgent, status >= 0.7, request <= 0.3 {
            lines.append("This reads as a status update rather than a request; answering it may be the whole job.")
        }
        if (answers.noul("memory") ?? 0) >= 0.7 {
            lines.append("Something saved in an earlier conversation likely bears on this; recall before answering.")
        }
        if let urgency = answers.score("urgency"), urgency >= 2.5,
           (answers.scoreConfidence("urgency") ?? 0) >= 0.7 {
            lines.append("The person is waiting on this now.")
        }
        brief.lines = Array(lines.prefix(3))
        return brief
    }

    /// The brief's lines as ONE line of runtime context for THIS turn.
    ///
    /// It rides the turn's DYNAMIC system segment, appended to the context
    /// that was just built — not the session directive. The directive is a
    /// durable one-shot the conversation is owed; a hint that is only worth
    /// saying on this turn has no business occupying it, and a turn that never
    /// reaches the model would otherwise leave the hint behind to surface on
    /// some later, unrelated turn. Nil when there is nothing useful to say.
    static func runtimeLine(_ brief: Brief?) -> String? {
        guard let brief, !brief.lines.isEmpty else { return nil }
        return "A pre-turn check suggests, as hints only, nothing decided: "
            + brief.lines.joined(separator: " ")
    }

    /// Close the pre-turn row with what the turn ACTUALLY dispatched, which is
    /// the only way to read the log and see whether a suggested family was the
    /// right one.
    static func closeTurn(
        _ brief: Brief?,
        dispatched: [String],
        sessionID: String,
        turnID: String,
        runID: String,
        dataRoot: URL
    ) async {
        await JevTurnMemo.shared.close(turnID: turnID)
        guard let brief else { return }
        let names = Array(Set(dispatched)).sorted()
        let families = Array(Set(names.compactMap(JevToolCatalog.family(forTool:)))).sorted()
        // What was told, on a row that had only ever carried what was answered.
        // Nothing told leaves the row exactly as it was.
        var told: [String: JSONValue] = [:]
        if let line = runtimeLine(brief) {
            told = JevLog.delivery(
                told: line, sourceTurn: turnID, reachedAgent: brief.linesDelivered
            )
        }
        JevLog.shared.note(
            lane: .preTurn,
            summary: "turn dispatched \(names.count) tool(s)",
            context: JevLogContext(
                sessionID: sessionID, turnID: turnID, runID: runID,
                acted: names.isEmpty ? "no tools" : names.joined(separator: ",")
            ),
            dataRoot: dataRoot,
            extra: told.merging([
                "suggested_family": .string(brief.suggestedFamily ?? ""),
                "suggested_score": .string(brief.suggestedScore.map(JevAnswers.round2) ?? ""),
                // What the shadow preload WOULD have loaded ahead. Nothing was.
                "would_preload_family": .string(brief.wouldPreloadFamily ?? ""),
                "family_scores": .array(brief.familyScores.map { pair in
                    .array(pair.map(JSONValue.string))
                }),
                "dispatched_families": .array(families.map(JSONValue.string)),
                "lines": .array(brief.lines.map(JSONValue.string)),
            ]) { delivered, _ in delivered }
        )
    }

    /// Two user and two agent messages, truncated. The minimum data rule: the
    /// last exchange, never the transcript.
    static func lastExchange(
        sessionID: String,
        runID: String,
        history: SessionHistoryReader
    ) async -> [String] {
        let rows = (try? await history.messages(
            forSessionId: sessionID, limit: 40, excludingRunId: runID
        )) ?? []
        let users = rows.filter { $0.role == "user" }.suffix(2)
        let agents = rows.filter { $0.role == "assistant" }.suffix(2)
        return (users + agents)
            .sorted { $0.timestamp < $1.timestamp }
            .map { "\($0.role == "user" ? "person" : "agent"): \($0.content.jevTruncated(600))" }
    }
}
