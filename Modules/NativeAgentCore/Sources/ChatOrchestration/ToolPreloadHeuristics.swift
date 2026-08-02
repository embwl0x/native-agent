import Foundation
import NativeAgentCore
import PersistenceCore
import MacIntegration

// MARK: - Predictive tool preload (U1 step 7)
//
// Lazy tool loading keeps the per-turn catalog lean, but costs a full model
// round-trip whenever the turn needs a discovery-only group: catalog → model
// calls tool_load → tools usable next iteration. This is a MECHANICAL
// (no-LLM, pure string matching) classifier over the user message that
// predicts which lazy tool groups the turn will need and unions them into
// the current turn's active set BEFORE the first model call.
//
// Invariants (hard constraints from the U1 step-7 brief):
//   - Zero added latency: pure string matching; the only I/O is one trace
//     append, and ONLY on turns with a confident match (no-match turns are
//     byte-for-byte the status quo).
//   - Never bypasses security gating — TWO layers mirror the dispatch
//     gates: (1) candidate names are intersected with the names already
//     present in the turn context's toolSchemas — that list is built by
//     listAvailableToolSchemas() under fullMacToolAccess() policy flags, so
//     a Full-Mac-gated tool (shell/bash/git/...) that the CURRENT policy
//     excludes is never preloaded; (2) Mac Integration tools (mail/calendar/
//     messages/...) are filtered through the SAME
//     MacIntegrationPermissionStore.allows(integration, mode:) check
//     dispatchMacIntegrationTool runs before executing — a policy-denied
//     tool is never preloaded (2026-06-10 review fix; the catalog alone
//     does not encode these per-integration read/write bits). Dispatch-time
//     gates (Full-Mac checks, autonomy gate, MacIntegrationPermissionStore)
//     still run unchanged on every call — preload only skips the tool_load
//     round-trip, never an approval.
//   - Union only: tools are added to the current turn's active set, never
//     evicted. LLM-requested tool_load entries persist in ActiveToolsStore
//     for the session (24h TTL / tool_unload own decay — the turn-end
//     baseline restore was removed 2026-07-25 after it caused session
//     amnesia and a reload round-trip before nearly every tool action).
//   - Cap: at most `maxGroupsPerTurn` groups per turn; on no confident
//     match, preload NOTHING.
//
// Group names + member tools are derived from the REAL lazy surface:
// impl_tool_load's category table (builder/markets/swarm) plus the
// discovery-only members of SwiftToolDispatcher.builtInToolNames. The
// tool_load "memory" category is intentionally ABSENT: all five member
// tools live in alwaysOnCoreNames, so preloading it is a structural no-op
// that would only waste a cap slot.

public enum ToolPreloadHeuristics {
    /// At most this many groups union into the active set per turn.
    public static let maxGroupsPerTurn = 3

    public struct GroupMatch: Equatable, Sendable {
        public let group: String
        public let matchedPatterns: [String]

        public init(group: String, matchedPatterns: [String]) {
            self.group = group
            self.matchedPatterns = matchedPatterns
        }
    }

    public struct Prediction: Equatable, Sendable {
        /// Ranked, capped at `maxGroupsPerTurn`.
        public let groups: [GroupMatch]
        /// Union of the capped groups' member tools (pre-gate candidates).
        public let candidateTools: Set<String>

        public init(groups: [GroupMatch], candidateTools: Set<String>) {
            self.groups = groups
            self.candidateTools = candidateTools
        }

        public var groupNames: [String] { groups.map(\.group) }
        public var matchedPatterns: [String] {
            var seen = Set<String>()
            var out: [String] = []
            for g in groups {
                for p in g.matchedPatterns where seen.insert(p).inserted {
                    out.append(p)
                }
            }
            return out
        }
    }

    struct GroupEntry {
        let group: String
        /// Accepted `tool_load(category:)` spellings. The canonical group name
        /// is always accepted and does not need to be repeated here.
        let aliases: Set<String>
        /// Single-word patterns matched against the tokenized message
        /// (exact token match — "git" does not fire on "digital").
        let tokens: Set<String>
        /// Multi-word / symbol patterns matched as lowercase substrings.
        let phrases: [String]
        let tools: Set<String>
        /// Some compatibility categories load a slightly broader set than
        /// the compact catalog advertises. Keeping that compatibility set on
        /// the same definition prevents the catalog and both loader paths
        /// from growing separate switch tables again.
        let loadTools: Set<String>
        /// Load-only compatibility groups stay out of compact discovery and
        /// deterministic preload classification.
        let advertised: Bool
        let preloadable: Bool

        init(
            group: String,
            aliases: Set<String> = [],
            tokens: Set<String>,
            phrases: [String],
            tools: Set<String>,
            loadTools: Set<String>? = nil,
            advertised: Bool = true,
            preloadable: Bool = true
        ) {
            self.group = group
            self.aliases = aliases
            self.tokens = tokens
            self.phrases = phrases
            self.tools = tools
            self.loadTools = loadTools ?? tools
            self.advertised = advertised
            self.preloadable = preloadable
        }
    }

    /// Table order is the tie-break priority when match counts are equal.
    /// Member lists mirror impl_tool_load's categories where one exists
    /// (builder/markets/swarm); the Full-Mac lists reference the dispatcher
    /// constants directly so the table cannot drift from the catalog.
    static let table: [GroupEntry] = [
        GroupEntry(
            group: "files",
            tokens: [
                "file", "files", "folder", "folders", "directory", "directories",
                "filename", "filenames", "doc", "docs", "document", "documents",
                "documentation", "handoff", "readme",
            ],
            phrases: ["handoff doc", "handoff docs", "project handoff"],
            tools: [
                "read_file", "list_dir", "write_file", "file_excerpt", "grep",
                // The selected chat LLM may express an exact reviewed local
                // copy through Workshop so the second planner call can be
                // removed. This changes only file-intent turns and does not
                // make Workshop hot on ordinary chat.
                "workshop_submit",
            ]
        ),
        GroupEntry(
            group: "research",
            aliases: ["web_search", "news"],
            tokens: [
                "news", "headline", "headlines", "announcement", "announcements",
            ],
            phrases: ["web search", "search the web", "search online", "latest news"],
            tools: [
                "browser.status",
                "browser.open_url",
                "browser.navigate",
                "browser.read_text",
                "browser.read_links",
            ],
            // Headless/Core callers historically used `research` for X
            // search. The installed app intercepts this category and loads
            // the visible Browser group. Preserve the Core compatibility
            // member without advertising or preloading it as Browser tissue.
            loadTools: [
                "browser.status",
                "browser.open_url",
                "browser.navigate",
                "browser.read_text",
                "browser.read_links",
                "x_search",
            ]
        ),
        GroupEntry(
            group: "browser",
            aliases: ["browsing", "visible_browser", "visible-browser", "web", "webpage", "page"],
            tokens: [
                "browser", "web", "webpage", "website", "page", "url",
                "navigate", "screenshot",
            ],
            phrases: [
                "visible browser", "open url", "open website", "open webpage",
                "read page", "read website", "browser screenshot",
            ],
            tools: [
                "browser.status",
                "browser.open_url",
                "browser.navigate",
                "browser.read_text",
                "browser.read_links",
                "browser.screenshot",
            ]
        ),
        GroupEntry(
            group: "art",
            aliases: ["image", "images", "image_generation", "image-generation", "draw"],
            tokens: ["draw", "paint", "illustrate", "artwork"],
            phrases: [
                "generate an image", "generate image", "generate art",
                "make an image", "make image", "make art", "make a picture",
                "create an image", "create image", "create art",
                "draw me", "draw a", "paint a", "illustrate a",
                "image generation", "image gen", "make a poster",
                "create a poster", "make a logo", "create a logo",
            ],
            tools: ["image_generate"]
        ),
        GroupEntry(
            group: "builder",
            aliases: ["coding", "code"],
            tokens: [
                "run", "test", "tests", "build", "compile", "shell", "bash",
                "git", "terminal", "script", "scripts", "patch", "commit", "repo",
            ],
            phrases: [],
            // Exact union impl_tool_load ships for category "builder".
            tools: Set(
                ["write_file"]
                    + SwiftToolDispatcher.fullMacFileToolNames
                    + SwiftToolDispatcher.fullMacSystemToolNames
                    + SwiftToolDispatcher.fullMacBuilderToolNames
                    + SwiftToolDispatcher.fullMacRestartToolNames
            ),
            loadTools: Set(
                ["write_file"]
                    + SwiftToolDispatcher.fullMacFileToolNames
                    + SwiftToolDispatcher.fullMacSystemToolNames
                    + SwiftToolDispatcher.fullMacBuilderToolNames
                    + SwiftToolDispatcher.fullMacRestartToolNames
                    + SwiftToolDispatcher.fullMacEvolutionToolNames
            )
        ),
        GroupEntry(
            group: "markets",
            aliases: ["market"],
            tokens: [
                "stock", "stocks", "market", "markets", "ticker", "tickers",
                "watchlist", "watchlists", "quote", "quotes", "tradingview", "nasdaq",
            ],
            phrases: [],
            tools: ["market_status", "market_watchlists", "tradingview_watchlist", "market_quote"]
        ),
        GroupEntry(
            group: "mail",
            tokens: ["email", "emails", "mail", "inbox", "gmail"],
            phrases: [],
            tools: [
                "mail_list_recent", "mail_search", "mail_send",
                "mail_mark_read", "mail_archive", "mail_delete", "mail_reply",
            ]
        ),
        GroupEntry(
            group: "gmail",
            tokens: ["gmail"],
            phrases: ["google mail"],
            tools: ["gmail_status", "gmail_search", "gmail_read"]
        ),
        GroupEntry(
            group: "calendar",
            tokens: [
                "calendar", "meeting", "meetings", "appointment", "appointments",
                "reminder", "reminders", "remind",
            ],
            phrases: [],
            tools: [
                "mac_calendar_list_upcoming", "mac_calendar_create_event", "mac_calendar_modify_event",
                "mac_reminders_list_due_today", "mac_reminders_create", "mac_reminders_complete",
            ]
        ),
        GroupEntry(
            group: "google_calendar",
            tokens: ["gcal"],
            phrases: ["google calendar"],
            tools: ["google_calendar_status", "google_calendar_list"]
        ),
        GroupEntry(
            group: "notion",
            tokens: ["notion"],
            phrases: ["notion page", "notion database"],
            tools: ["notion_status", "notion_search", "notion_read_page"]
        ),
        GroupEntry(
            group: "messages",
            tokens: ["imessage", "imessages", "sms", "texted"],
            phrases: ["text message"],
            tools: ["messages_recent_threads", "messages_send"]
        ),
        GroupEntry(
            group: "notes",
            tokens: ["notes"],
            phrases: ["apple notes"],
            tools: ["notes_search", "notes_create", "notes_update"]
        ),
        GroupEntry(
            group: "contacts",
            tokens: ["contact", "contacts"],
            phrases: ["phone number", "address book"],
            tools: ["contacts_search", "contacts_create_or_update", "contacts_delete"]
        ),
        GroupEntry(
            group: "music",
            tokens: ["music", "song", "songs", "playlist", "playlists"],
            phrases: [],
            tools: [
                "music_now_playing", "music_control", "music_search_library",
                "music_list_library", "music_list_playlists",
            ]
        ),
        GroupEntry(
            group: "x",
            tokens: ["tweet", "tweets", "twitter", "retweet"],
            phrases: ["x.com"],
            tools: ["x_status", "x_me", "x_search", "x_timeline", "x_user_tweets"]
        ),
        GroupEntry(
            group: "github",
            aliases: ["git_hub", "repos", "repositories"],
            tokens: ["github"],
            phrases: [
                "pull request", "pull requests", "requested review", "requested reviews",
                "failed ci", "github issue", "github issues", "github project", "hermes github",
            ],
            tools: [
                "github_status", "github_list_repos", "github_list_issues", "github_search",
                "github_list_pull_requests", "github_get_issue", "github_get_pull_request",
                "github_pull_request_files", "github_pull_request_activity",
                "github_discover_tracking", "github_project_digest", "github_mutate",
            ],
            // Visibility mutation remains available through explicit category
            // loading for compatibility, but is not automatically preloaded
            // or advertised as routine GitHub readiness.
            loadTools: [
                "github_status", "github_list_repos", "github_list_issues", "github_search",
                "github_list_pull_requests", "github_get_issue", "github_get_pull_request",
                "github_pull_request_files", "github_pull_request_activity",
                "github_discover_tracking", "github_project_digest", "github_mutate",
                "github_set_repo_visibility",
            ]
        ),
        GroupEntry(
            group: "slack",
            aliases: ["workspace_chat", "team_chat"],
            tokens: ["slack", "channel", "channels", "workspace"],
            phrases: ["post to slack", "send to slack", "slack channel"],
            tools: ["slack_status", "slack_list_channels", "slack_search_messages", "slack_post_message"]
        ),
        GroupEntry(
            group: "swarm",
            aliases: ["swarms", "subagent", "subagents"],
            tokens: ["swarm", "swarms", "subagent", "subagents"],
            phrases: ["sub-agent"],
            tools: ["agent_swarm"]
        ),
        GroupEntry(
            group: "persona",
            tokens: ["persona"],
            phrases: ["soul.md", "voice.md", "growth.md", "agents.md"],
            tools: ["get_persona_doc", "persona_read", "persona_write", "persona_append_section"]
        ),
        // Agent Desk — the things the user asks the configured agent to track. The desk_*
        // tools are lazy (builtInToolNames); preload them on desk/tracking intent
        // so a "keep track of X" turn drives them SAME-turn (the live-test UX bug
        // Agent caught: manual tool_load only lands them the next turn).
        // Conservatively scoped — no bare "track"/"remind" tokens (those carry
        // other intents: on-track, reminders→calendar); desk intent rides
        // specific phrases + the "desk" token.
        GroupEntry(
            group: "desk",
            tokens: ["desk"],
            phrases: [
                "keep track", "keeping track", "kept track", "keep an eye on",
                "don't let me forget", "dont let me forget", "do not let me forget",
                "track this", "track that", "add to the desk", "put on the desk",
                "agent's desk", "my desk", "desk item", "kept list",
                // Nag-lane trigger language (wave 3): how the user actually
                // flips the switch in chat — without these, desk_nag_control
                // is reachable only via an explicit tool_load next turn.
                "stay on me", "keep on me", "nag me", "stop nagging",
                "go quiet", "quiet down about",
            ],
            tools: [
                // desk_read is ALWAYS-ON (alwaysOnCoreNames, 2026-06-29 User's
                // pull flow) — preload groups must stay disjoint from the
                // always-on core, so only the nine mutations ride the group.
                "desk_add_item", "desk_set_status", "desk_update_item",
                "desk_note", "desk_add_ref", "desk_set_cadence", "desk_set_notify",
                "desk_close", "desk_archive",
                // Sequencing mutations ride the same tracking-intent group —
                // "this is blocked on that" / "park it until Friday" / "break
                // this idea down" is the same capture flow, not a separate
                // tool_load.
                "desk_blocked_on", "desk_defer", "desk_breakdown",
                // Nag control rides the same group: "stay on me about X" is
                // tracking intent through and through (wave-3 open item #1).
                "desk_nag_control",
                // Workshop volition tools ride the same tracking-intent group so
                // "open a pursuit" / progress logging is reachable without a
                // separate tool_load (2026-07-11 review LOW).
                "desk_open_pursuit", "desk_work_log",
            ]
        ),
        // Compatibility groups that remain accepted by tool_load but do not
        // belong in compact discovery because their members are always-on or
        // have no deterministic preload classifier.
        GroupEntry(
            group: "context",
            aliases: ["trace", "scratch"],
            tokens: [],
            phrases: [],
            tools: ["context_lookup", "scratchpad_read", "recent_trace_summary"],
            advertised: false,
            preloadable: false
        ),
        GroupEntry(
            group: "memory",
            aliases: ["recall", "session"],
            tokens: [],
            phrases: [],
            tools: ["recall_memory", "recall_search", "search_kg", "search_chat_history", "session_search"],
            advertised: false,
            preloadable: false
        ),
        GroupEntry(
            group: "agentmail",
            aliases: ["mail_agent", "agent_mail"],
            tokens: [],
            phrases: [],
            tools: ["agentmail_list", "agentmail_read", "agentmail_send"],
            advertised: false,
            preloadable: false
        ),
    ]

    /// Tokens that must appear as a STANDALONE whitespace-delimited word
    /// (punctuation-trimmed) — never as a fragment of a path/underscore
    /// token. Live false positive 2026-06-10 22:52: the alphanumeric-
    /// fragment tokenizer split the path token "agent_inbox" into
    /// agent+inbox and preloaded the whole mail group on a repo-file
    /// question. "docs/agent_inbox/from_claude.md" must not read as mail
    /// intent; "check my inbox" still does.
    static let standaloneOnlyTokens: Set<String> = ["inbox"]

    /// Generic markers used instead of the matching user text — the traces
    /// file is privacy-bound (static-table patterns only, never user values).
    static let pathSignalMarker = "path-like-token"
    static let extensionSignalMarker = "file-extension"
    static let webAddressSignalMarker = "web-address-token"
    static let builderScriptSignalMarker = "script-file-token"

    // Builder evidence gate (2026-06-10 review fix): the builder union is
    // LARGE (the whole Full-Mac shell/git/build surface) and its trigger
    // verbs are everyday English — "run that by me" / "test this idea" must
    // not expand the tools array. The group matches ONLY on >=2 independent
    // weak token signals, or ONE strong signal: an unambiguous compound
    // phrase, the xcodebuild token, or an explicit script-file token
    // (*.sh / *.py).
    static let builderStrongPhrases: [String] = [
        "run the test", "run tests", "run the build", "test suite",
        "swift build", "swift test", "swift package",
        "git commit", "git push", "git pull", "git status", "git diff",
        "git log", "git rebase", "git merge", "git stash",
        "last commit", "since last commit", "since the last commit",
        "repo status", "repo changes", "repository changes",
        "repo state", "repository state", "repo stands", "repository stands",
        "where the repo stands", "where the repository stands",
        "shell command", "bash command", "shell script",
    ]
    static let builderStrongTokens: Set<String> = ["xcodebuild"]
    static let builderScriptExtensions: Set<String> = ["sh", "py"]

    private static let knownFileExtensions: Set<String> = [
        "swift", "py", "md", "json", "txt", "js", "ts", "html", "css",
        "yml", "yaml", "sh", "csv", "log", "xml", "plist", "toml",
        "rs", "go", "java", "c", "h", "cpp", "m", "mm",
    ]

    // MARK: Classification (pure)

    /// Compile one readiness decision from both the message classifier and
    /// high-confidence groups already proved by the deterministic resident
    /// route. Route hints are closed group names, never model output, and only
    /// make schemas visible; dispatch authority remains unchanged.
    public static func predict(
        userMessage: String,
        residentGroupHints: [String] = []
    ) -> Prediction? {
        let lower = userMessage.lowercased()
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = tokenSet(lower)
        let rawTokens = lower.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let webSignals = webAddressSignals(rawTokens: rawTokens)
        // Whole whitespace-delimited words (punctuation-trimmed) for the
        // standalone-only patterns — "agent_inbox" / "docs/agent_inbox/"
        // stay single words here and never equal "inbox".
        let standaloneWords = Set(rawTokens.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:)('\"`"))
        })

        var matches: [GroupMatch] = []
        for entry in table where entry.preloadable {
            var hits: [String] = []
            for t in entry.tokens.sorted() {
                let hit = standaloneOnlyTokens.contains(t)
                    ? standaloneWords.contains(t)
                    : tokens.contains(t)
                if hit { hits.append(t) }
            }
            for p in entry.phrases where lower.contains(p) { hits.append(p) }
            if entry.group == "files" {
                hits.append(contentsOf: fileSignals(rawTokens: rawTokens))
            }
            if entry.group == "research", !webSignals.isEmpty {
                // Direct URL/domain turns should stay browser-shaped. The
                // research group exists for plain news/search wording where
                // there is no address token to preload the browser group.
                hits.removeAll()
            }
            if entry.group == "browser" {
                hits.append(contentsOf: webSignals)
            }
            if entry.group == "builder" {
                hits = builderEvidence(
                    weakHits: hits, lower: lower, tokens: tokens, rawTokens: rawTokens
                )
            }
            if !hits.isEmpty {
                matches.append(GroupMatch(group: entry.group, matchedPatterns: hits))
            }
        }
        let knownGroups = Set(table.lazy.filter(\.preloadable).map(\.group))
        var hintedGroups = Set(residentGroupHints.filter { knownGroups.contains($0) })
        // Bridge-tagged turns are agent-to-agent WORK traffic by construction:
        // the "[from: <sender>, via bridge]" prefix is machine-affixed by
        // ClaudeBridge, and every such turn (codex completion relays, claude
        // corrections, wake prompts) asks this session to verify something —
        // git forensics, file reads, repo state. Their bodies rarely carry
        // builder-strong lexical evidence ("poke him" → she git-logs), which
        // is exactly the miss class of 2026-07-25: 29 zero-candidate turns
        // followed by manual bash/git_*/read_file loads. Hinting the working
        // set is schema visibility only — dispatch gates are unchanged, and
        // a spoofed prefix in ordinary chat costs nothing but prompt bytes.
        let isBridgeTurn = trimmed.hasPrefix("[from: ") && trimmed.contains("via bridge]")
        let bridgeGroups: Set<String> = isBridgeTurn
            ? Set(["builder", "files", "github"].filter { knownGroups.contains($0) })
            : []
        hintedGroups.formUnion(bridgeGroups)
        for group in hintedGroups.sorted() {
            // Trace honesty: a bridge-derived hint labels itself; only groups
            // the deterministic route actually proved say resident-route.
            let marker = Set(residentGroupHints).contains(group)
                ? "resident-route:\(group)"
                : "bridge-sender:\(group)"
            if let index = matches.firstIndex(where: { $0.group == group }) {
                var patterns = matches[index].matchedPatterns
                if !patterns.contains(marker) { patterns.append(marker) }
                matches[index] = GroupMatch(group: group, matchedPatterns: patterns)
            } else {
                matches.append(GroupMatch(group: group, matchedPatterns: [marker]))
            }
        }
        guard !matches.isEmpty else { return nil }

        // Rank: route-owned readiness first, then match count, then stable
        // table order. A deterministic route should not lose a two-group cap
        // to a weaker parallel lexical guess.
        let ranked = matches.enumerated()
            .sorted { a, b in
                // Explicitly NAMED services outrank everything (2026-07-19
                // Continuum incident): "Look through my repo on GitHub —
                // files, README…" matched builder (resident hint) + files
                // (2 tokens) + github (1 token) and the 2-group cap EVICTED
                // the one service the user literally named — the model then
                // had to tool_catalog its way back. A group matched via its
                // own name token is the user's explicit intent, not a
                // lexical guess.
                let aNamed = a.element.matchedPatterns.contains(a.element.group)
                let bNamed = b.element.matchedPatterns.contains(b.element.group)
                if aNamed != bNamed { return aNamed }
                let aHinted = hintedGroups.contains(a.element.group)
                let bHinted = hintedGroups.contains(b.element.group)
                if aHinted != bHinted { return aHinted }
                if a.element.matchedPatterns.count != b.element.matchedPatterns.count {
                    return a.element.matchedPatterns.count > b.element.matchedPatterns.count
                }
                return a.offset < b.offset
            }
            .map(\.element)
        let capped = Array(ranked.prefix(maxGroupsPerTurn))

        var candidates = Set<String>()
        let cappedNames = Set(capped.map(\.group))
        for entry in table where cappedNames.contains(entry.group) {
            candidates.formUnion(entry.tools)
        }
        return Prediction(groups: capped, candidateTools: candidates)
    }

    /// Compact discovery index shared by the Core and app-owned catalog
    /// overlays. It exposes exact loadable names by group without serializing
    /// every tool description and JSON schema into a model result.
    public static func groupIndex(
        availableToolNames: Set<String>
    ) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for entry in table where entry.advertised {
            let names = entry.tools.intersection(availableToolNames).sorted()
            if !names.isEmpty { result[entry.group] = names }
        }
        return result
    }

    /// Canonical category resolver shared by compact discovery and both
    /// Swift tool-load paths. It is deliberately presentation-only: callers
    /// still intersect with their exact available inventory and every tool
    /// still revalidates policy at dispatch time.
    public static func loadGroup(
        forCategory rawCategory: String
    ) -> (group: String, tools: Set<String>)? {
        let category = rawCategory
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !category.isEmpty,
              let entry = table.first(where: {
                  $0.group == category || $0.aliases.contains(category)
              }) else { return nil }
        return (entry.group, entry.loadTools)
    }

    public static var knownLoadCategories: [String] {
        table.map(\.group).sorted()
    }

    /// Gate reuse + union-only hygiene. `availableToolNames` MUST be the
    /// names from the turn context's toolSchemas (built by
    /// listAvailableToolSchemas() under fullMacToolAccess() policy flags) —
    /// the intersection is what keeps Full-Mac policy-locked groups out.
    /// NOTE: Mac Integration read/write policy is NOT encoded in the catalog
    /// (denied tools still list; dispatch returns a structured `denied`
    /// envelope) — preloadIfConfident applies that second gate via
    /// filterByMacIntegrationPolicy.
    public static func preloadableNames(
        prediction: Prediction,
        availableToolNames: Set<String>,
        alreadyActive: Set<String>
    ) -> Set<String> {
        prediction.candidateTools
            .intersection(availableToolNames)
            .subtracting(SwiftToolDispatcher.alwaysOnCoreNames)
            .subtracting(alreadyActive)
    }

    /// Mirror of the dispatch-time Mac Integration gate
    /// (ChatOrchestrationClient.dispatchMacIntegrationTool →
    /// MacIntegrationPermissionStore.shared.allows(integration, mode:)).
    /// One entry per Mac Integration tool in the group table, carrying the
    /// EXACT (integration, mode) pair its dispatch case passes to the guard.
    /// Keep in lockstep with the `case "<tool>":` table in
    /// ChatOrchestrationClient.swift.
    static let macIntegrationGates: [String: (integration: String, mode: MacIntegrationPermissionMode)] = [
        // calendar group
        "mac_calendar_list_upcoming": (MacIntegrationID.calendar, .read),
        "mac_calendar_create_event": (MacIntegrationID.calendar, .write),
        "mac_calendar_modify_event": (MacIntegrationID.calendar, .write),
        "mac_reminders_list_due_today": (MacIntegrationID.reminders, .read),
        "mac_reminders_create": (MacIntegrationID.reminders, .write),
        "mac_reminders_complete": (MacIntegrationID.reminders, .write),
        // mail group
        "mail_list_recent": (MacIntegrationID.mail, .read),
        "mail_search": (MacIntegrationID.mail, .read),
        "mail_send": (MacIntegrationID.mail, .write),
        "mail_mark_read": (MacIntegrationID.mail, .write),
        "mail_archive": (MacIntegrationID.mail, .write),
        "mail_delete": (MacIntegrationID.mail, .write),
        "mail_reply": (MacIntegrationID.mail, .write),
        // messages group
        "messages_recent_threads": (MacIntegrationID.messages, .read),
        "messages_send": (MacIntegrationID.messages, .write),
        // notes group
        "notes_search": (MacIntegrationID.notes, .read),
        "notes_create": (MacIntegrationID.notes, .write),
        "notes_update": (MacIntegrationID.notes, .write),
        // contacts group
        "contacts_search": (MacIntegrationID.contacts, .read),
        "contacts_create_or_update": (MacIntegrationID.contacts, .write),
        "contacts_delete": (MacIntegrationID.contacts, .write),
        // music group
        "music_now_playing": (MacIntegrationID.music, .read),
        "music_search_library": (MacIntegrationID.music, .read),
        "music_list_library": (MacIntegrationID.music, .read),
        "music_list_playlists": (MacIntegrationID.music, .read),
        "music_control": (MacIntegrationID.music, .write),
        // Not in any preload pattern group, but the table doubles as the
        // parallel-dispatch write veto (U1 step 6) — it must cover EVERY
        // dispatchMacIntegrationTool case, not just preloadable ones
        // (gpt-5.5 review, 2026-06-10: scheduler_list_jobs gates on .write
        // — scheduler has no read axis — yet its "list" name walked the
        // positive read-signal branch into the parallel set).
        "mac_notify": (MacIntegrationID.notifyMac, .write),
        "mac_spotlight_search": (MacIntegrationID.spotlight, .read),
        "scheduler_list_jobs": (MacIntegrationID.scheduler, .write),
        "scheduler_create_job": (MacIntegrationID.scheduler, .write),
    ]

    /// Second security gate (2026-06-10 review fix): drop every candidate
    /// whose Mac Integration policy bit is OFF, using the SAME
    /// `allows(integration, mode:)` check dispatchMacIntegrationTool runs
    /// before executing the tool. Without this, e.g. `mail_send` preloaded
    /// on an "email" match even with Mail write off — dispatch still denied
    /// it, but the "policy-denied tool is never preloaded" invariant was
    /// false. Tools without a gate entry (not Mac Integration tools) pass
    /// through untouched.
    static func filterByMacIntegrationPolicy(
        _ names: Set<String>,
        permissions: MacIntegrationPermissionStore
    ) async -> Set<String> {
        var out: Set<String> = []
        out.reserveCapacity(names.count)
        for name in names {
            if let gate = macIntegrationGates[name] {
                if await permissions.allows(gate.integration, mode: gate.mode) {
                    out.insert(name)
                }
            } else {
                out.insert(name)
            }
        }
        return out
    }

    // MARK: Orchestration (turn-scoped union + one trace row, match turns only)

    /// Returns the active set to feed applyLazyToolFilter: unchanged on
    /// no-match, `activeTools ∪ preloaded` on a confident match. This is
    /// intentionally request-scoped: callers bind the returned set through
    /// `LLMCallContext.turnActiveTools` so first-call schemas and dispatch
    /// agree without growing `ActiveToolsStore`. Explicit `tool_load` remains
    /// the only durable session load path.
    public static func preloadIfConfident(
        userMessage: String,
        sessionId: String,
        activeTools: Set<String>,
        availableToolNames: Set<String>,
        surface: String,
        store: ActiveToolsStore = .shared,
        permissions: MacIntegrationPermissionStore = .shared,
        dataRoot: URL
    ) async -> Set<String> {
        guard let prediction = predict(userMessage: userMessage) else { return activeTools }
        return await preloadIfConfident(
            prediction: prediction,
            sessionId: sessionId,
            activeTools: activeTools,
            availableToolNames: availableToolNames,
            surface: surface,
            store: store,
            permissions: permissions,
            dataRoot: dataRoot
        )
    }

    public static func preloadIfConfident(
        prediction: Prediction?,
        sessionId: String,
        activeTools: Set<String>,
        availableToolNames: Set<String>,
        surface: String,
        store: ActiveToolsStore = .shared,
        permissions: MacIntegrationPermissionStore = .shared,
        dataRoot: URL
    ) async -> Set<String> {
        guard let prediction else { return activeTools }
        let catalogGated = preloadableNames(
            prediction: prediction,
            availableToolNames: availableToolNames,
            alreadyActive: activeTools
        )
        // Dispatch-gate mirror: Mac Integration policy denials drop out here
        // so a policy-denied tool is never preloaded (see header invariant).
        let names = await filterByMacIntegrationPolicy(catalogGated, permissions: permissions)
        guard !names.isEmpty else { return activeTools }
        _ = store
        _ = sessionId
        await appendPreloadTraceRow(
            prediction: prediction,
            tools: names,
            surface: surface,
            dataRoot: dataRoot
        )
        return activeTools.union(names)
    }

    // MARK: - Helpers

    private static func tokenSet(_ lower: String) -> Set<String> {
        Set(
            lower.unicodeScalars
                .split(whereSeparator: { !CharacterSet.alphanumerics.contains($0) })
                .map { String(String.UnicodeScalarView($0)) }
        )
    }

    /// Builder evidence gate — see the statics above. Returns the final
    /// matched-pattern list for the builder group: empty unless the message
    /// carries at least one STRONG signal (compound phrase / xcodebuild /
    /// explicit *.sh / *.py script token that is not part of a URL). Weak
    /// token signals are recorded for the trace but can NEVER trigger the
    /// match on their own — the 2-weak-token rule was dropped (gpt-5.5
    /// delta re-review, 2026-06-10: "run a test in your head" matched via
    /// run+test). Preload is an optimization: a false negative costs the
    /// status-quo tool_load round trip; a false positive inflates the
    /// Anthropic prefix on every iteration of the turn. Strong-only is the
    /// right side of that asymmetry. The script token records a generic
    /// marker, never the user's filename (trace privacy).
    static func builderEvidence(
        weakHits: [String],
        lower: String,
        tokens: Set<String>,
        rawTokens: [Substring]
    ) -> [String] {
        var strong: [String] = []
        for p in builderStrongPhrases where lower.contains(p) { strong.append(p) }
        for t in builderStrongTokens.sorted() where tokens.contains(t) { strong.append(t) }
        let hasScriptToken = rawTokens.contains { raw in
            // URL-safe: a scheme-bearing token ("https://…/deploy.sh") is a
            // link, not a local script intent (delta re-review fix).
            guard !raw.contains("://") else { return false }
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:)('\"`"))
            guard let dot = token.lastIndex(of: "."), dot != token.startIndex else { return false }
            return builderScriptExtensions.contains(String(token[token.index(after: dot)...]))
        }
        if hasScriptToken { strong.append(builderScriptSignalMarker) }
        guard !strong.isEmpty else { return [] }
        var out = weakHits
        for s in strong where !out.contains(s) { out.append(s) }
        return out
    }

    /// Mechanical file-intent signals: a path-shaped token or a known file
    /// extension. A bare word pair such as `inner/body` or `and/or` is prose,
    /// not a local path. Emits generic markers, never the user's token.
    private static func fileSignals(rawTokens: [Substring]) -> [String] {
        var signals: [String] = []
        var sawPath = false
        var sawExtension = false
        for raw in rawTokens {
            if sawPath && sawExtension { break }
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:)('\"`"))
            if token.count < 3 { continue }
            if isWebAddressToken(token) { continue }
            if !sawPath,
               UserMessageIntentSignals.isLikelyLocalPathToken(token) {
                signals.append(pathSignalMarker)
                sawPath = true
            }
            if !sawExtension,
               let dot = token.lastIndex(of: "."),
               dot != token.startIndex,
               knownFileExtensions.contains(String(token[token.index(after: dot)...])) {
                signals.append(extensionSignalMarker)
                sawExtension = true
            }
        }
        return signals
    }

    /// URL/domain-shaped tokens without a scheme, such as
    /// `openai.com/news`, are browser intent, not local file paths. The
    /// signal stays generic for trace privacy.
    private static func webAddressSignals(rawTokens: [Substring]) -> [String] {
        for raw in rawTokens {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:)('\"`"))
            if isWebAddressToken(token) {
                return [webAddressSignalMarker]
            }
        }
        return []
    }

    private static func isWebAddressToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return true
        }
        guard lower.rangeOfCharacter(from: .letters) != nil else { return false }
        if lower.contains("://") { return true }
        let host = String(lower.split(separator: "/", maxSplits: 1).first ?? "")
        guard host.contains(".") else { return false }
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Same feed, same row shape, same flock as ChatToolDispatchTracer
    /// ({id, kind, title, status, payload, createdAt} into
    /// <dataRoot>/traces/events.jsonl). Payload carries static-table
    /// patterns + tool/group names only — never user text. Non-fatal: an
    /// IO failure logs to stderr and the turn proceeds. No trim here — the
    /// dispatch tracer trims this file opportunistically and preload writes
    /// at most one row per turn.
    static func appendPreloadTraceRow(
        prediction: Prediction,
        tools: Set<String>,
        surface: String,
        dataRoot: URL
    ) async {
        let tracesPath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("tool.preload"),
            "title": .string(prediction.groupNames.joined(separator: ",")),
            "status": .string("ok"),
            "payload": .object([
                "groups": .array(prediction.groupNames.map { .string($0) }),
                "matchedPatterns": .array(prediction.matchedPatterns.map { .string($0) }),
                "tools": .array(tools.sorted().map { .string($0) }),
                "surface": .string(surface),
            ]),
            "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(tracesPath) {
                try await persistence.appendJSONL(row, to: tracesPath)
            }
        } catch {
            FileHandle.standardError.write(
                Data("ToolPreloadHeuristics: trace append failed: \(error)\n".utf8)
            )
        }
    }
}
