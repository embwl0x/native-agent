import ChatTurnContracts
import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import ToolRegistry
// Blueprint: | `BuiltInToolSchemaFactory+CoreSchemas.swift` | `BuiltInToolSchemaFactory`: `coreSchemas`, unchanged `context_expand` descriptor |

extension BuiltInToolSchemaFactory {
    func inboxOptionsSchema() -> JSONValue {
        let root = PersistenceCore.defaultDataRoot()
        let handles = ((try? AgentPeerStore(dataRoot: root).list()) ?? []).flatMap { $0.handles ?? [] }
        let keys = Set(handles.flatMap { AgentConversationRouting.supportedOptions(agent: $0, dataRoot: root) ?? [] })
        return ToolSchema.obj([("type", .string("object")), ("additionalProperties", .bool(false)), ("properties", .object(
            Dictionary(uniqueKeysWithValues: keys.map { key in
                let property = ["fast", "pair_reviewer"].contains(key) ? ToolSchema.boolSchema()
                    : key == "timeout_seconds" ? ToolSchema.intSchema("Door's run limit, 60–3600 seconds.", minimum: 60, maximum: 3600)
                    : ToolSchema.strSchema("Declared by the contact's inbox door.")
                return (key, property)
            })))])
    }

    private static let canonicalContextExpandSchema = LLMToolSchema(
        name: "context_expand",
        toolClass: .read, capabilities: ["tool_call"],
        description: "Read deeper context by its offered atom id or a history: id from a replayed receipt. Context atoms are pinned to this turn's generation; history receipts are read from the current conversation.",
        parametersJSON: (try? JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "atom_id": .object([
                    "type": .string("string"),
                    "description": .string("Offered context atom id or history: id from a replayed receipt."),
                ]),
                "max_characters": .object([
                    "type": .string("integer"),
                    "description": .string("Optional bounded character limit."),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "description": .string("Optional character offset, default 0. Continue with next_offset until null."),
                ]),
            ]),
            "required": .array([.string("atom_id")]),
        ]).serializedData(pretty: false)) ?? Data("{}".utf8)
    )

    func coreSchemas() -> [LLMToolSchema?] {
        let mailReplyFields: [(String, JSONValue)] = [
            ("subject", ToolSchema.strSchema("Subject for legacy matching; omit when using the exact message locator.")),
            ("message_id", ToolSchema.intSchema("Exact positive inbox message ID from the latest read.", minimum: 1)),
            ("expected_message_id", ToolSchema.strSchema("Exact RFC message identifier paired with message_id.")),
            ("expected_account", ToolSchema.strSchema("expected_account from the same row, when it has one.")),
            ("expected_account_id", ToolSchema.strSchema("expected_account_id from the same row.")),
            ("position", ToolSchema.intSchema("position from the same row: finds the message fast.", minimum: 1)),
            ("body", ToolSchema.strSchema("Reply body (required).")),
            ("sender", ToolSchema.strSchema("Optional sender filter — disambiguates when multiple messages share the subject.")),
            ("reply_all", ToolSchema.boolSchema("Reply to all recipients. Defaults to false.")),
        ]
        func mailBatchItemsSchema(effects: Bool, markReadOnly: Bool = false) -> JSONValue {
            var fields: [(String, JSONValue)] = [
                ("name", ToolSchema.strSchema("Observed workspace name, such as mail.3. Omit locator fields when using a name.")),
                ("message_id", ToolSchema.intSchema("Exact positive message_id from the selected row.")),
                ("expected_message_id", ToolSchema.strSchema("RFC identifier from that row; may be empty only for reads.")),
                ("expected_account", ToolSchema.strSchema("Exact expected_account from that row; required with a locator.")),
                ("expected_account_id", ToolSchema.strSchema(effects ? "expected_account_id from that row, passed along as its identity."
                    : "expected_account_id from that row; Mail's index checks the account with it.")),
                ("position", ToolSchema.intSchema("Position hint from the same row.")),
                ("scope", ToolSchema.strSchema("Same mailbox scope: inbox or sent for reads; inbox for actions.")),
            ]
            if markReadOnly { fields.removeFirst() }
            else if effects {
                fields += [
                    ("mark_read", ToolSchema.boolSchema("true to mark this message read; omit to leave it unchanged.")),
                    ("flagged", ToolSchema.boolSchema("true to flag, false to unflag; omit to leave it unchanged.")),
                    ("archive", ToolSchema.boolSchema("true to move this message to its own account's Archive, after other requested actions.")),
                ]
            } else {
                fields.append(("body_offset", ToolSchema.intSchema("Body continuation from this item's body_end, up to 2000000; omit initially.")))
            }
            return ToolSchema.obj([
                ("type", .string("array")), ("minItems", .int(1)), ("maxItems", .int(markReadOnly ? 50 : 10)),
                ("items", ToolSchema.obj([("type", .string("object")), ("properties", ToolSchema.obj(fields)), ("additionalProperties", .bool(markReadOnly))])),
            ])
        }
        let mailOffsetSchema = ToolSchema.obj([
            ("description", .string("Live mailbox continuation returned as next_offset; copy it unchanged; omit initially.")),
            ("anyOf", .array([
                ToolSchema.obj([("type", .string("integer")), ("minimum", .int(0)), ("maximum", .int(10000))]),
                ToolSchema.obj([("type", .string("object")), ("additionalProperties", ToolSchema.intSchema("", minimum: 0))]),
            ])),
        ])
        let schemas: [LLMToolSchema?] = [
            requestedSchema(
                name: "maps_search",
                toolClass: .read, capabilities: ["network_read", "safe_read", "tool_call"],
                description: "Find businesses or places near an address or place name with MapKit. Returns the resolved center and matching places within the radius, sorted by straight-line distance in locale miles/km, with name, full address, phone, URL, category and coordinates when available. Results may not include every place. Does not open Maps or change the screen.",
                parametersJSON: ToolSchema.params(properties: [
                    ("query", ToolSchema.strSchema("Kind of business, place name or search terms.")),
                    ("near", ToolSchema.strSchema("Center address or place name; include city/region to disambiguate.")),
                    ("radius_miles", numSchema("Positive search radius in miles; defaults to 25, capped at 100.", minimum: 0, maximum: 100)),
                    ("limit", ToolSchema.intSchema("Maximum places returned; defaults to 8, capped at 20.", minimum: 1, maximum: 20)),
                ], required: ["query", "near"])
            ),
            requestedSchema(
                name: "maps_route",
                toolClass: .read, capabilities: ["network_read", "safe_read", "tool_call"],
                description: "Read a MapKit route between two addresses or place names: distance, expected travel time and up to five key steps in route order. Returns the resolved endpoints so you can check the locations. Optional fraction names a point along route distance (0.5 is halfway), reverse-geocoded to a nearby place. Automobile by default; walking is also supported. Does not open Maps or change the screen.",
                parametersJSON: ToolSchema.params(properties: [
                    ("origin", ToolSchema.strSchema("Origin address or place name; include city/region to disambiguate.")),
                    ("destination", ToolSchema.strSchema("Destination address or place name; include city/region to disambiguate.")),
                    ("transport", ToolSchema.enumStringSchema(["automobile", "walking"], "Transport; defaults to automobile.")),
                    ("fraction", numSchema("Optional point along route distance, from 0 through 1; 0.5 is halfway.", minimum: 0, maximum: 1)),
                ], required: ["origin", "destination"])
            ),
            requestedSchema(
                name: "web_search",
                toolClass: .read,
                description: "Search the web through SearXNG: its results, or its failure said plainly. On a Mac without SearXNG the result hands you browser_search, the same search in Chrome (or your own browser), to run and read. categories=news (or it, science) searches that SearXNG category. time_range=day|week|month|year asks for recent pages. Returns titles, URLs and snippets, the route and its time.",
                parametersJSON: ToolSchema.params(properties: [
                    ("query", ToolSchema.strSchema()),
                    ("categories", ToolSchema.strSchema("Optional SearXNG category, such as news, it or science.")),
                    ("time_range", ToolSchema.enumStringSchema(["day", "week", "month", "year"], "Optional recency: pages from the past day, week, month or year.")),
                ], required: ["query"])
            ),
            requestedSchema(
                name: "read_page",
                toolClass: .read,
                description: "Read public http(s) privately, without a browser, signed-in session or consent. Returns readable text, requested/final URL, content type, extraction outcome and omissions from the 1 MB response bound (32 MB for a PDF). HTML, text and PDF text stay available for tool-output paging; other binary formats are unsupported. source_receipt.path locates the limited-retention JSON receipt; files.read requires normal file permissions. A missing receipt proves neither an empty source nor a need to refetch.",
                parametersJSON: ToolSchema.params(properties: [
                    ("url", ToolSchema.strSchema("Public http(s) URL to read.")),
                ], required: ["url"])
            ),
            requestedSchema(
                name: "read_file",
                toolClass: .read,
                description: "Read a regular workspace/user-approved file; pipes/devices/sockets return unsupported_file_type. Text: byte windows (bytes=source size; offset/returned_bytes=current window; max_bytes=limit); follow next/has_more. Images: PNG/JPEG/WebP/GIF/HEIC/TIFF/BMP pixels, not OCR; ≤8 MiB/40 MP, first frame oriented/resized to 2048 px. Folder+match: ≤8 files. Read image paths to view; names/consult refs are not viewing. Relative paths use the canonical workspace; verified development checkouts also allow repo-relative paths. Full Mac file access admits absolute Mac paths except NativeAgent trust/secrets/provider paths; /documents/... maps to ~/Documents/.... Long handoff Markdown defaults to a compact leading window unless max_bytes is explicit.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("path", ToolSchema.strSchema("Workspace-relative path such as 'project/file.txt', a repo-relative path only when a verified source checkout exists, or an absolute/~/ path under a Trust workspace root. Persona files must use app persona.doc or persona.read. In Full Mac mode, /documents/<name> maps to the current user's ~/Documents/<name>.")),
                        ("match", ToolSchema.strSchema("Glob for a folder path, e.g. '*-r4-*.png'.")),
                        ("query", ToolSchema.strSchema("Search the whole text source for complete lines containing every whitespace-separated term, case-insensitively. Returns records with line positions and full-source coverage, in source order. Pages fit 24000 serialized bytes; a larger single record is refused, never split. Continue only with next; max_bytes and offset are byte-mode arguments.")),
                        ("start_line", ToolSchema.intSchema("Search continuation's 1-based source line; omit initially and copy next unchanged.")),
                        ("max_lines", ToolSchema.intSchema("Matching lines per search page, default 80, capped at 240.")),
                        ("max_bytes", ToolSchema.intSchema("Optional source byte window: capped at 200,000 bytes; long handoff Markdown defaults to 12,000 bytes when omitted. This is a file-read limit, not a one-response guarantee: large results are delivered through result.page. UTF-8 characters stay whole; use at least 4 bytes to ensure progress.")),
                        ("offset", ToolSchema.intSchema("Byte offset, default 0. Continue with returned next arguments; positive offsets require version and a UTF-8 boundary.")),
                        ("version", ToolSchema.strSchema("Omit initially; copy next unchanged. file_changed means restart without version at offset 0 (bytes) or start_line 1 (search); never combine versions.")),
                    ],
                    required: ["path"]
                )
            ),
            requestedNames?.contains("context_expand") != false
                ? Self.canonicalContextExpandSchema
                : nil,
            requestedSchema(
                name: "list_dir",
                toolClass: .read,
                description: "List/filter immediate names in an approved folder. sort:size reads allocated disk usage for the folder and its children within a time budget, naming partial paths and lower bounds. Ordinary listings return bounded pages and next arguments; read selected text with files.excerpt. Public/app-only relative paths use the canonical workspace; verified development checkouts also accept repo-relative paths. Full Mac permits absolute paths except NativeAgent trust/secrets/provider paths.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("path", ToolSchema.strSchema("Directory path; omitted or empty lists the folder relative paths start from, as '.' does. In Full Mac mode, /documents/<name> maps to the current user's ~/Documents/<name>; a file_not_found result is a path miss, not a trust denial.")),
                        ("name_contains", ToolSchema.strSchema("Optional literal filename substring, not glob or regex; empty means all names.")),
                        ("sort", ToolSchema.enumStringSchema(["name", "newest", "added", "size"], "Ordering: name (default, folders first), newest (added then modified date), added (date added only to this folder, for install/download recency, including app bundles; rows include added_at; unknown dates sort last), or size (observed allocated bytes descending). Size scans return total allocated_bytes, size_complete, per-child sizes and partial_paths; incomplete sizes are lower bounds. Size scans cannot be paged; narrow path for more detail.")),
                        ("time_budget_seconds", ToolSchema.intSchema("Disk usage scan budget for sort:size, default 5, range 1–20 seconds; checked between metadata reads.")),
                        ("case_sensitive", ToolSchema.boolSchema("Whether filename matching is case-sensitive; default false (case-insensitive).")),
                        ("max_entries", ToolSchema.intSchema("Entries per page, default and maximum 200; minimum 1.")),
                        ("offset", ToolSchema.intSchema("Start at 0. For continuation pass the returned next arguments unchanged.")),
                        ("snapshot", ToolSchema.strSchema("Omit or empty on first page. Required with positive offset; copied from next. directory_changed means restart at offset 0 without snapshot.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "file_info",
                toolClass: .read,
                description: "Read one approved path's name, directory and regular flags, size in bytes and modified ISO 8601 date. Does not follow the final symbolic link. Uses the same file access as files.list.",
                parametersJSON: ToolSchema.params(properties: [("path", ToolSchema.strSchema("File or folder path, under the same approved roots as files.list."))], required: ["path"])
            ),
            requestedSchema(
                name: "write_file",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Create or write a UTF-8 file, creating missing parent folders automatically; append is optional. Ordinary project work belongs in NativeAgent's canonical workspace/ (public installs: ~/Library/Application Support/NativeAgent/workspace). Without Full Mac, stay within that workspace or a user-added Trust workspace root. Active Full Mac file access permits broader Mac writes except NativeAgent trust/secrets/provider paths and protected system mutations.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("path", ToolSchema.strSchema("A relative path such as project/file.txt (resolved inside the canonical NativeAgent workspace), workspace/project/file.txt, or an absolute/~/ path inside another Trust workspace root. Full Mac mode also accepts broader Mac paths, but intentional build/project artifacts belong in the canonical workspace rather than /tmp.")),
                        ("content", ToolSchema.strSchema("Content to write.")),
                        ("append", ToolSchema.boolSchema("Append instead of replacing the file.")),
                        ("expected_content_sha256", ToolSchema.strSchema("Optional SHA-256 of the complete existing UTF-8 file, up to 64 KiB. Before replacement, refuse a missing or changed file with file_changed. Not supported with append.")),
                    ],
                    required: ["path", "content"]
                )
            ),
            requestedSchema(
                name: "trash_file",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Move a file or folder to the Trash for delete, remove or clean-up requests. Reversible: returns the original path and trash_path; restore from the Trash if needed. Uses the same workspace or Full Mac file access as writing files.",
                parametersJSON: ToolSchema.params(properties: [("path", ToolSchema.strSchema("File or folder path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths."))], required: ["path"])
            ),
            requestedSchema(
                name: "move_file",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Move or rename a file or folder on the same filesystem, creating missing destination parent folders. Uses the same writable roots and guards as files.write. Refuses an existing destination unless overwrite:true was explicitly requested; no screen or Finder interaction needed.",
                parametersJSON: ToolSchema.params(properties: [
                    ("path", ToolSchema.strSchema("Existing file or folder path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths.")),
                    ("destination", ToolSchema.strSchema("Complete new path including the filename or folder name, not just its containing folder. Missing parent folders are created.")),
                    ("overwrite", ToolSchema.boolSchema("Replace an existing destination only when explicitly requested. Default false.")),
                ], required: ["path", "destination"])
            ),
            requestedSchema(
                name: "copy_file",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Copy a regular file, preserving its data and metadata and creating missing destination parent folders. Uses the same writable roots and guards as files.write. Refuses an existing destination unless overwrite:true was explicitly requested; folder copies are not supported. No screen or Finder interaction needed.",
                parametersJSON: ToolSchema.params(properties: [
                    ("path", ToolSchema.strSchema("Existing regular file path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths.")),
                    ("destination", ToolSchema.strSchema("Complete new file path including the filename. Missing parent folders are created.")),
                    ("overwrite", ToolSchema.boolSchema("Replace an existing destination only when explicitly requested. Default false.")),
                ], required: ["path", "destination"])
            ),
            requestedSchema(
                name: "recall_memory",
                toolClass: .read,
                description: "Search long-term memory by query (optional k), or page an exact memory_id with offset/max_characters. Use one mode; null unused fields. ID pages: max 2000 characters, with recorded evidence or explicit absence. Follow read_more with expected_content_sha256 for one text version; on record_changed discard prior pages and restart at 0. Only currently eligible, disclosed records are readable.",
                parametersJSON: recallParameters()
            ),
            requestedSchema(
                name: "recall_search",
                toolClass: .read,
                description: "memory.recall compatibility alias: query (optional k) searches; memory_id + offset/max_characters pages one eligible fact. Never mix modes; null unused fields. Follow read_more with expected_content_sha256 until next_offset=null; on record_changed discard prior pages and restart at 0.",
                parametersJSON: recallParameters()
            ),
            requestedSchema(
                name: "search_kg",
                toolClass: .read,
                description: "Search the assistant's knowledge graph for entities matching query text; returns up to limit summaries. Filter by type and since, like the Knowledge Graph page; with no query the filters browse the whole graph. Pass entity_id instead to open one entity with its neighbors and the edges between them.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Text to search for. Leave it out to open entity_id or to browse by type or since.")),
                        ("limit", ToolSchema.intSchema("max results, default 10, at most 100; with entity_id, the most edges listed", minimum: 1, maximum: 100)),
                        ("type", ToolSchema.strSchema("Optional: only entities of these types, comma-separated: person, organization, project, concept, place, event, tool, fact.")),
                        ("since", ToolSchema.enumStringSchema(["day", "week", "month"], "Optional: only entities seen in the last day, week or month.")),
                        ("entity_id", ToolSchema.strSchema("Optional: an entity id from a search result. Returns that entity, its edges and its neighbors.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "workspace",
                toolClass: .read,
                description: "Your world as text. No args: home (what waits, working, people, helpers, every place: mail, calendar, files, music…). action: a name (desk.4, mail, music, an agent's name) opens it with its one-call actions. What changed already rides in your glance line (none = nothing new). action also takes an exact ref from a view (+text if needs_text, fields for forms). query: a name opens, else searches.",
                parametersJSON: ToolSchema.params(properties: [
                    ("query", nullableRecallField(ToolSchema.strSchema("Find across work, recorded files, memory and conversation evidence, up to 400 characters; otherwise null."))),
                    ("action", nullableRecallField(ToolSchema.strSchema("Exact action reference offered in this chat's current workspace view; otherwise null."))),
                    ("text", nullableRecallField(ToolSchema.strSchema("Text for an action that needs_text, otherwise null."))),
                    ("conversation", nullableRecallField(ToolSchema.strSchema("Optional conversation label for an agent message; helpers use their existing conversation."))),
                    ("fields", ToolSchema.obj([
                        ("type", .array([.string("array"), .string("object"), .string("null")])),
                        ("description", .string("Values for the displayed form when submitting it, or to fill a Desk form as you open it (for example desk.add); otherwise null. Use a list of field/value pairs; Desk forms also accept an object mapping field names to values. Values are strings: plain text for text fields, numbers/booleans as text, JSON text for lists/objects; use JSON null only to clear a nullable field. The app already carries selected target fields.")),
                        ("additionalProperties", nullableRecallField(ToolSchema.strSchema())),
                        ("items", ToolSchema.obj([("type", .string("object")), ("properties", ToolSchema.obj([
                            ("field", ToolSchema.strSchema("Field name shown in the form.")),
                            ("value", nullableRecallField(ToolSchema.strSchema("Value in the form field's declared type. Use JSON null only to explicitly clear a nullable field; the text null remains literal text in string fields.")))
                        ])), ("required", .array([.string("field"), .string("value")])), ("additionalProperties", .bool(false))]))
                    ])),
                ], required: [])
            ),
            requestedSchema(
                name: "work_context",
                toolClass: .read,
                description: "Read current Desk status, original conversation evidence and recent Mail sender/subject matches for a topic, with dates and exact source links. Mail Read must be allowed and ready; its search is bounded to 1.5 seconds, five newest inbox matches from the last 90 days, with mail.N names to open bodies. Mail, Messages and Notes can hold personal facts; Messages and Notes require their own readers. This detailed reader also supports conversation and result limits. Historical reports are not fresh verification; nothing is restarted.",
                parametersJSON: ToolSchema.params(properties: [
                    ("query", ToolSchema.strSchema("The work or topic to pick back up, in ordinary words (1–400 characters).")),
                    ("session_id", nullableRecallField(ToolSchema.strSchema("Optional exact conversation to restrict historical evidence; null searches across conversations. Desk remains the current shared Desk."))),
                    ("limit", nullableRecallField(ToolSchema.intSchema("Maximum Desk items and chat excerpts per source, default 3, range 1–4; null uses the default. Mail returns at most five matches."))),
                    ("desk_offset", nullableRecallField(ToolSchema.intSchema("Omit initially; retained continuation for more current work."))),
                    ("history_offset", nullableRecallField(ToolSchema.intSchema("Omit initially; retained continuation for more history with the same topic and selection policy."))),
                ], required: ["query"])
            ),
            requestedSchema(
                name: "artifact_find",
                toolClass: .read,
                description: "Find a document, image, mockup or handoff by what it was for or the conversation around it. Searches recorded chat attachments, structured tool artifact references and current Desk links; returns exact references with source conversation and version evidence when recorded. Does not crawl disk, open files, infer approval from filenames, or prove current file availability. Use the returned evidence to distinguish approved work from a later draft.",
                parametersJSON: ToolSchema.params(properties: [
                    ("query", ToolSchema.strSchema("Describe the artifact or its topic in ordinary words.")),
                    ("session_id", ToolSchema.strSchema("Optional exact conversation to search. When supplied, excludes shared Desk links.")),
                    ("limit", ToolSchema.intSchema("Maximum artifact candidates, default 6, range 1–12.")),
                    ("session_offset", ToolSchema.intSchema("Omit initially; use returned continuation for older conversation evidence.")),
                ], required: ["query"])
            ),
            requestedSchema(
                name: "search_chat_history",
                toolClass: .read,
                description: "Search persisted conversation transcripts, including this conversation; scope/session_id narrows it. For work status/resumption, start at app {} for Desk state, original evidence and document discovery. Returns ranked snippets with conversation ids, titles, roles, timestamps and is_current_session when known. Background reads never show/detach a conversation: resolve with chat.list, then session_id, no query, sort:newest, limit:12 messages (not exchanges). Follow next_call for older pages and chat.message for truncated bodies; order collected messages chronologically and disclose coverage/truncation.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Words or phrase to search for in prior conversation transcripts. Omit with after/before for a conversation digest with activity times, message counts and bounded excerpts of the owner's own messages; omit with session_id to list that conversation.")),
                        ("session_id", ToolSchema.strSchema("Optional conversation id to restrict search to one conversation, e.g. a Mac, iOS, or telegram conversation id.")),
                        ("scope", ToolSchema.enumStringSchema(["all_sessions", "current_session", "previous_session", "auto", "current_session_first", "current", "last_session", "all", "global", "all_session"], "Scope: all_sessions (default), current_session, previous_session, or auto/current_session_first. auto/current_session_first searches the current conversation first and searches all conversations only if no strong current match exists. previous_session reopens the \"Since last session\" anchor on this surface, excluding machine/bridge runs; it accepts no query, returning that conversation's tail.")),
                        ("role", ToolSchema.strSchema("Optional role: user/assistant/tool/system. user includes agents through bridges; owner means only the owner on their own door. tool explicitly searches persisted argument/result/status receipts, possibly redacted/truncated; ordinary search excludes them.")),
                        ("author", ToolSchema.strSchema("Optional recorded author, e.g. owner or an agent's name. Use owner for what the owner said; bridge/wake and unknown authors are excluded. User-role hits include author and author_route.")),
                        ("mode", ToolSchema.enumStringSchema(["hybrid", "exact", "continuity"], "hybrid (default), exact substring or continuity. For requested conversation resumption/revisiting, continuity returns up to four hits with bounded neighboring user/assistant messages, preserving decision/correction context. Retrieves nothing until invoked.")),
                        ("limit", ToolSchema.intSchema("Results per page, default 8; capped at 8 conversations for date-only digests, 4 hits for continuity, otherwise 12 hits.")),
                        ("offset", ToolSchema.intSchema("result offset for a follow-up page; omit on the first search")),
                        ("before", ToolSchema.strSchema("Optional exclusive ISO8601 upper bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and reported.")),
                        ("after", ToolSchema.strSchema("Optional exclusive ISO8601 lower bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and reported.")),
                        ("since", ToolSchema.strSchema("Optional lower bound: ISO8601 or a positive relative duration such as 1d, 7d or 2h. Combined with after, the later bound applies.")),
                        ("sort", .object([
                            "type": .string("string"),
                            "enum": .array(["relevance", "oldest", "newest"].map(JSONValue.string)),
                            "description": .string("Default relevance; oldest/newest sorts matches chronologically regardless of relevance. all_sessions + oldest finds earliest matches. Use mode exact for whole phrases; hybrid may match individual words. Chronology does not prove original authorship."),
                        ])),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "session_search",
                toolClass: .read,
                description: "Alias for chat.search. Searches all conversations by default, including the current conversation; is_current_session marks hits when the current conversation is known. Use scope or session_id to narrow the search. Use sort: oldest to find the earliest matches.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Words or phrase to search for in prior conversation transcripts. Omit with after/before for a conversation digest with activity times, message counts and bounded excerpts of the owner's own messages; omit with session_id to list that conversation.")),
                        ("session_id", ToolSchema.strSchema("Optional conversation id to restrict search to one conversation.")),
                        ("scope", ToolSchema.enumStringSchema(["all_sessions", "current_session", "previous_session", "auto", "current_session_first", "current", "last_session", "all", "global", "all_session"], "Scope: all_sessions (default), current_session, previous_session, or auto/current_session_first. auto/current_session_first searches the current conversation first and searches all conversations only if no strong current match exists. previous_session reopens the \"Since last session\" anchor on this surface, excluding machine/bridge runs; it accepts no query, returning that conversation's tail.")),
                        ("role", ToolSchema.strSchema("Optional role: user/assistant/tool/system. user includes agents through bridges; owner means only the owner on their own door. tool explicitly searches persisted argument/result/status receipts, possibly redacted/truncated; ordinary search excludes them.")),
                        ("author", ToolSchema.strSchema("Optional recorded author, e.g. owner or an agent's name. Use owner for what the owner said; bridge/wake and unknown authors are excluded. User-role hits include author and author_route.")),
                        ("mode", ToolSchema.enumStringSchema(["hybrid", "exact", "continuity"], "hybrid (default), exact, or continuity (up to four hits with bounded neighboring messages for requested conversation resumption).")),
                        ("limit", ToolSchema.intSchema("Results per page, default 8; capped at 8 conversations for date-only digests, 4 hits for continuity, otherwise 12 hits.")),
                        ("offset", ToolSchema.intSchema("result offset for a follow-up page; omit on the first search")),
                        ("before", ToolSchema.strSchema("Optional exclusive ISO8601 upper bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and reported.")),
                        ("after", ToolSchema.strSchema("Optional exclusive ISO8601 lower bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and reported.")),
                        ("since", ToolSchema.strSchema("Optional lower bound: ISO8601 or a positive relative duration such as 1d, 7d or 2h. Combined with after, the later bound applies.")),
                        ("sort", .object([
                            "type": .string("string"),
                            "enum": .array(["relevance", "oldest", "newest"].map(JSONValue.string)),
                            "description": .string("Default relevance; oldest/newest sorts matches chronologically regardless of relevance. all_sessions + oldest finds earliest matches. Use mode exact for whole phrases; hybrid may match individual words. Chronology does not prove original authorship."),
                        ])),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "read_chat_message",
                toolClass: .read,
                description: "Page a full persisted message using the exact work.context/chat.search locator, rather than rephrasing a query for another preview fragment. Tool messages contain retained receipt metadata, not fresh reads or unabridged original output. Coverage distinguishes missing evidence from unreadable history; incomplete lookups prove neither absence nor permission to replay actions.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("message_id", ToolSchema.strSchema("The message_id from a work.context or chat.search source locator.")),
                        ("session_id", ToolSchema.strSchema("Optional conversation id the message belongs to. Omit to look through every transcript, newest first.")),
                        ("offset", ToolSchema.intSchema("Character offset into the message, default 0. Pass the previous response's next_offset for the following page.", minimum: 0)),
                        ("limit", ToolSchema.intSchema("Characters per page, default 8000, capped at 16000.", minimum: 1, maximum: 16_000)),
                    ],
                    required: ["message_id"]
                )
            ),
            requestedSchema(
                name: "get_persona_doc",
                toolClass: .read,
                description: "Read a canonical persona document on demand: SOUL.md, USER.md, AGENTS.md, VOICE.md, GROWTH.md or MEMORY.md. Documents above 64 KiB report truncation; not a complete turn-context readout.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("doc", ToolSchema.strSchema("One of: SOUL, USER, AGENTS, VOICE, GROWTH, MEMORY")),
                        ("kind", ToolSchema.strSchema("Same as doc; accepted so it matches persona.read.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "persona_read",
                toolClass: .read,
                description: "Read a canonical persona document by kind: growth=GROWTH.md, user=USER.md, soul=SOUL.md, voice=VOICE.md, agents=AGENTS.md.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        // The reader canonicalizes kind; keep those string forms accepted.
                        ("kind", ToolSchema.obj([("description", .string("One of: soul, user, voice, growth, agents.")), ("anyOf", .array([
                            ToolSchema.enumStringSchema(["soul", "user", "voice", "growth", "agents"]),
                            ToolSchema.strSchema(),
                        ]))])),
                        // Still accepted and ignored for ordinary documents; the skill alias is retired.
                        ("skill_name", ToolSchema.strSchema("Retired skill alias argument; ignored for ordinary persona documents.")),
                        ("source", ToolSchema.boolSchema("Retired skill alias argument; ignored for ordinary persona documents.")),
                        ("content", ToolSchema.boolSchema("Retired skill alias argument; ignored for ordinary persona documents.")),
                    ],
                    required: ["kind"]
                )
            ),
            requestedSchema(
                name: "persona_write",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Replace your own persona document. USER.md is read-only, generated from Memories; use memory.commit for durable user facts.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.strSchema("One of: soul, voice, growth, agents. Do not use user; USER.md is generated from Memories.")),
                        ("content", ToolSchema.strSchema("Full replacement document content.")),
                        ("retire", ToolSchema.obj([
                            ("type", .string("object")),
                            ("description", .string("growth only: each REM-approved line this rewrite drops, exactly as written, mapped to why it goes. A retired line is not offered again.")),
                            ("additionalProperties", ToolSchema.strSchema()),
                        ])),
                    ],
                    required: ["kind", "content"]
                )
            ),
            requestedSchema(
                name: "persona_append_section",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Append a titled markdown section to your persona document. USER.md is read-only, generated from Memories; use memory.commit for durable user facts.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.strSchema("One of: soul, voice, growth, agents. Do not use user; USER.md is generated from Memories.")),
                        ("title", ToolSchema.strSchema("Markdown section title. Do not include the leading ##.")),
                        ("content", ToolSchema.strSchema("Section body to append.")),
                    ],
                    required: ["kind", "title", "content"]
                )
            ),
            requestedSchema(
                name: "agent_introspect",
                toolClass: .read, capabilities: ["tool_call"],
                description: "Inspect your live runtime, provider and conversation identity. app {find} finds actions by what you want done. detail=full includes diagnostic roots and the seven-day outcome population audit.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("detail", ToolSchema.enumStringSchema(["compact", "full"], "compact (default) or full diagnostics")),
                        ("session_id", ToolSchema.strSchema("Optional conversation scope; supplied automatically in a turn.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "tool_result_page",
                toolClass: .read, capabilities: ["catalog_read", "tool_call"],
                description: "Read a result retained this turn without repeating its action. Only full_result_retained:true results are eligible. Follow next_call; continue:true alone selects the sole retained result. Exact result_handle/page also works. Query selects only matching records in source order, with positions and retained-response coverage; it cannot search unread source content. Read-only, redacted; expires at turn end.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("result_handle", nullableRecallField(ToolSchema.strSchema("Opaque handle from the bounded_tool_result receipt."))),
                        ("continue", nullableRecallField(ToolSchema.boolSchema("Continue this turn's last successful read; page is ignored; omit query/raw. result_handle explicitly changes result. Before any read, starts the sole retained result or asks you to choose."))),
                        ("page", nullableRecallField(ToolSchema.intSchema("Zero-based whole-number page index. Omit or null starts at 0; follow next_page while has_more is true. Keep query and raw unchanged while paging."))),
                        ("query", nullableRecallField(ToolSchema.strSchema("Select records containing every whitespace-separated term, case-insensitively. Keep query while paging; start at page 0 when changing it. Empty reads all records."))),
                        ("raw", nullableRecallField(ToolSchema.boolSchema("Exact original bytes instead of sections, only for reconstruction or oversized values. Separate 8000-byte pages may split sentences/JSON; concatenate from page 0 through raw_page_count pages."))),
                        ("session_id", nullableRecallField(ToolSchema.strSchema("Current conversation id; the tool loop auto-fills this."))),
                    ],
                    required: []
                )
            ),
            // A request addressed to the person is a question, not an effect:
            // the person's own answer on the card is the decision, so no
            // posture or steer puts a card in front of the card.
            requestedSchema(
                name: "request_interaction",
                toolClass: .read, capabilities: ["tool_call"],
                description: "Raise an inline setup/choice card; required kind and why, with canonical target except choose. Secrets go only in cards, never chat. api_key supports provider sign-in or keys; reach secret:<name> uses api_key target:secret:<name> with hosts/programs and optional sign_in. The person supplies the secret on the card; it stays in the keyring and code uses {{secret:<name>}} without seeing it. Connector cards require an explicit connect/add/set up/enable request; ordinary read/status requests only report the blocker. Other kinds may request a known missing prerequisite. Cards settle to receipts; configured targets return without a card. Connector/permission/capability cards are nonblocking: skip the unavailable step and continue. API-key/model/choice cards stop the turn until the person acts. choose requires title, nonempty options and decline_consequence. Canonical targets and controls are listed in parameters; unsupported targets refuse. For participants use agent.connect; for helpers bot.create. Example: {\"kind\":\"connector\",\"target\":\"slack\",\"why\":\"Connect Slack as requested.\",\"decline_consequence\":\"I will continue without Slack.\"}.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(
                            ["connector", "permission", "model_choice", "api_key", "capability", "choose"],
                            "What is needed."
                        )),
                        ("target", ToolSchema.strSchema("Canonical id. connector: slack, telegram, mail (Apple Mail), chrome (Chrome extension), iphone (pair iPhone/iPad). permission: calendar, reminders, contacts, mail, messages, notes, music, notify_mac, notify_mobile, spotlight, scheduler; Mac control: shell, file_ops, applescript:<bundle_id> (macOS Automation for one app), jxa, accessibility, system. api_key: openai, anthropic, openrouter, moonshot, or secret:<name> for a keyring secret; sign-in: openai_oauth_direct (ChatGPT), anthropic_oauth_direct (Claude), xai (Grok). capability: image_generation, screen_capture, vision_api_calls, tts. model_choice: a Providers group id. Omit for choose.")),
                        ("why", ToolSchema.strSchema("One sentence: why this is needed, here, now.")),
                        ("decline_consequence", ToolSchema.strSchema("What happens if they say no. Required for choose; a sensible default is used otherwise.")),
                        ("also_needed", stringArraySchema("For permission: other Mac capabilities this same request needs, so they grant once instead of twice.")),
                        ("hosts", stringArraySchema("For secret:<name>: the hosts (api.example.com) a request may carry it to. Where it is already kept for stays granted unless only:true.")),
                        ("programs", stringArraySchema("For secret:<name>: the programs (npx, or an executable's path) it may be handed to; the grant binds each to the file that runs now, and a changed one asks again.")),
                        ("replace", ToolSchema.boolSchema("For secret:<name>: ask again though it is kept (expired, revoked, or the person wants a new one); the kept value stays until the new one is.")),
                        ("remove", ToolSchema.boolSchema("For secret:<name>: ask the person to remove it from the keyring.")),
                        ("only", ToolSchema.boolSchema("For secret:<name>: grant only the hosts and programs named, so it stops going anywhere else it is kept for; the card says which stop.")),
                        ("sign_in", .object([
                            "type": .string("object"),
                            "description": .string("For secret:<name> from a service's OAuth sign-in: NativeAgent runs it (code flow with PKCE, loopback redirect; or a device sign-in) and keeps and renews the token. A client secret the service issued is typed by the person on the card, never sent here."),
                            "properties": .object([
                                "authorize": .object(["type": .string("string"), "description": .string("https authorize URL; may carry extra query parameters.")]),
                                "device": .object(["type": .string("string"), "description": .string("https device authorization URL, given instead of authorize for a device sign-in: the card shows the person the code and opens where they enter it.")]),
                                "token": .object(["type": .string("string"), "description": .string("https token URL.")]),
                                "client_id": .object(["type": .string("string")]),
                                "scopes": .object(["type": .string("string"), "description": .string("Space-separated.")]),
                                "redirect": .object(["type": .string("string"), "description": .string("A registered http://127.0.0.1:<port>/<path>; default any port, /callback.")]),
                                "client_auth": .object(["type": .string("string"), "enum": .array([.string("body"), .string("basic")]),
                                                        "description": .string("How the client authenticates at the token endpoint: in the body (default) or by HTTP Basic.")]),
                            ]),
                            "required": .array([.string("token"), .string("client_id")]),
                        ])),
                        ("mode", ToolSchema.enumStringSchema(
                            ["read", "write", "read_write"],
                            "For permission: which axis the blocked call actually needed. Say read or write when that is all it was - omitting this asks for both, which is a wider grant than the work required."
                        )),
                        ("title", ToolSchema.strSchema("For choose: the question.")),
                        ("scope_noun", ToolSchema.strSchema("For model_choice: the single piece of work this should apply to, e.g. \"this image\". Supplying it scopes the choice to this request and offers the permanent change as the secondary action.")),
                        ("options", .object([
                            "type": .string("array"),
                            "description": .string("For choose and model_choice: the answers, each with a stable id and a label."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "id": .object(["type": .string("string")]),
                                    "label": .object(["type": .string("string")]),
                                    "detail": .object(["type": .string("string")]),
                                ]),
                                "required": .array([.string("id"), .string("label")]),
                            ]),
                        ])),
                    ],
                    required: ["kind", "why"]
                )
            ),
            requestedSchema(
                name: "image_generate",
                toolClass: .write, capabilities: ["app_data_write", "image_generation", "network_write", "tool_call"],
                description: "Generate raster images on the route selected for Work in Providers: Codex uses image_gen.imagegen; OpenAI uses its separately billed image API. Only Codex supports edits/local references here. Provider and image model are route-owned, never selected by tool input; an unsupported route asks for a supported Work choice. Requires admitted Full Mac or Trust’s image-generation permission. Saves under data/generated_images/; returns paths, thumbnails and a receipt. " + CodexImageGenerationHelp.usage,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("prompt", ToolSchema.strSchema("Describe the image or the edits, identifying what each reference supplies and what must stay unchanged.")),
                        ("size", ToolSchema.strSchema("Codex: prompt preference, e.g. 16:9 or auto; inspect actual dimensions. OpenAI API: forwarded as size, subject to its model’s limits.")),
                        ("quality", ToolSchema.strSchema("low, medium, high or auto; visual quality, not thinking effort. Codex: prompt preference, fulfillment unknown unless reported. OpenAI API: forwarded as quality.")),
                        ("output_format", ToolSchema.strSchema("png (default), jpeg or webp. Codex: prompt preference; decoded bytes determine extension. OpenAI API: forwarded as output_format.")),
                        ("background", ToolSchema.strSchema("Codex only: auto, opaque or transparent prompt preference; transparency requires PNG/WebP. Inspect alpha. Omit on OpenAI API.")),
                        ("n", ToolSchema.intSchema("Image count, default 1, clamped to 1–4. Codex requests are independent; OpenAI API receives n.")),
                        ("timeout_seconds", ToolSchema.intSchema("Codex only: whole run timeout, 30–1800 seconds, default 600. OpenAI API uses a fixed 180-second request timeout.")),
                        ("referenced_image_paths", stringArraySchema("Codex only: up to four authorized local PNG/JPEG/WebP files, 8 MiB each, 20 MiB total; copied and attached to the run. Resupply for each edit. Omit or [] on OpenAI API.")),
                        ("action", ToolSchema.strSchema("Codex only: auto (default), generate or edit; edit requires references. Omit on OpenAI API.")),
                    ],
                    required: ["prompt"]
                )
            ),
            requestedSchema(
                name: "context_lookup",
                toolClass: .read, capabilities: ["tool_call"],
                description: "Find NativeAgent capabilities and where to use them. Supports type='lookup_feature_surface' / 'feature_surface' / 'features'.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Capability or feature text to search for. Empty returns the first bounded feature-surface records.")),
                        ("type", ToolSchema.strSchema("Optional lookup type. Supported: lookup_feature_surface, feature_surface, features.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "scratchpad_read",
                toolClass: .read,
                description: "Read the current conversation scratchpad written by /scratch controls or app action chat.scratch. The chat tool loop injects session_id when available.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("key", ToolSchema.strSchema("Optional scratch key. If omitted, returns bounded scratch keys and values.")),
                        ("session_id", ToolSchema.strSchema("Optional conversation id; injected by the Swift tool loop for normal chat/Telegram turns.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "time_now",
                toolClass: .read, capabilities: ["tool_call"],
                description: "Return the current date and time in multiple representations: ISO-8601 UTC, ISO-8601 local timezone, epoch seconds, and a human-readable summary including weekday + day of year. Zero inputs.",
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            requestedSchema(
                name: "recent_trace_summary",
                toolClass: .read, capabilities: ["tool_call"],
                description: "Read saved traces and receipts. view:receipts returns compact tool-end evidence with action, target, effect and time; effects_only filters successful non-read receipts, and since accepts today or an ISO-8601 timestamp. completed_turns selects the last N finished turns, excluding unfinished turns; scan limits are reported. name and turn_id select exact evidence. Results are bounded to 32 KiB including metadata; follow next_call for continuation. turn_id or completed_turns plus fields reads bounded, secret-redacted values.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Maximum events per page, default 10, capped at 50.")),
                        ("offset", ToolSchema.intSchema("Continuation event offset; copy from next_call.")),
                        ("before", ToolSchema.strSchema("Continuation anchor timestamp; copy from next_call to keep the same window.")),
                        ("view", ToolSchema.enumStringSchema(["receipts", "usage", "model_calls"], "Use receipts for compact tool.dispatch end receipts across all conversations unless session_id is explicit; non-read actions precede reads. usage sums recorded model calls across all conversations, defaults since to today, and reports missing measurements and retention coverage. Omit for all event kinds.")),
                        ("trace", ToolSchema.strSchema("For receipt_id, the exact turn_traces/<yyyy-MM-dd>.jsonl file; reads the complete day.")),
                        ("by", ToolSchema.enumStringSchema(["model", "surface", "day"], "Usage grouping; default model. day uses local calendar dates.")),
                        ("effects_only", ToolSchema.boolSchema("Successful non-read receipts with bounded target/effect previews; excludes previews and explicit no-effect results. Does not prove effects still persist.")),
                        ("since", ToolSchema.strSchema("today (local midnight) or an ISO-8601 timestamp with Z or an offset. Reads the complete retained time window without tail scan limits; response pagination still applies.")),
                        ("completed_turns", ToolSchema.intSchema("Last N finished turns, capped at 50; limit and the total response budget still apply. Includes completed, failed and cancelled turns.")),
                        ("kind", ToolSchema.strSchema("Optional event kind substring, e.g. tool.dispatch or turn.terminal; tool/action names belong in name.")),
                        ("name", ToolSchema.strSchema("Optional exact tool or app action filter, e.g. mac.clipboard_read or mac.clipboard_read. For returned values use turn_id or completed_turns with fields:[name,args,result,receipt].")),
                        ("status", ToolSchema.strSchema("Optional exact status filter.")),
                        ("session_id", ToolSchema.strSchema("Optional exact conversation filter. Includes sibling events from turns belonging to that conversation.")),
                        ("sessionId", ToolSchema.strSchema("Compatibility alias for session_id.")),
                        ("turn_id", ToolSchema.strSchema("Optional exact turn id filter.")),
                        ("receipt_id", ToolSchema.strSchema("Exact dispatch receipt id, including from an expired result handle; reads retained evidence without repeating the operation.")),
                        ("fields", stringArraySchema("Optional payload keys; requires turn_id or completed_turns. Up to 16 keys, 80 characters each; values share an 8 KiB cap.", minItems: 1, maxItems: 16, maxItemLength: 80)),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "agent_swarm",
                toolClass: .write,
                description: "Run temporary workers on an objective. Pass objective as the shared task and optionally agents with individual prompts. Workers use the selected Work model. Set reasoning_effort for the run or each worker; omitted levels inherit the run's level, then Work's Think default. Change that default with app setting.set (setting='providers.work_thinking'). Workers default to read-only reasoning; access='inherit' enables ordinary tools under current Trust. Returns worker outputs, optional synthesis and a receipt.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("objective", ToolSchema.strSchema("Required. The task/question every worker should analyze.")),
                        ("agents", looseObjectArraySchema("Optional worker configs. Each object may include name, role, prompt/lens_brief, reasoning_effort, access ('read_only' or 'inherit'), contextSlice, findingsCap.")),
                        ("reasoning_effort", ToolSchema.strSchema("Optional Think level for workers and synthesis: low, medium, high, xhigh, or another level the selected Work model's catalog supports. Defaults to Work's Think level. Each worker may override it with reasoning_effort.")),
                        ("workers", looseObjectArraySchema("Compatibility alias for agents.")),
                        ("roles", looseObjectArraySchema("Compatibility alias for agents.")),
                        ("agentCount", ToolSchema.intSchema("Optional worker count when no agents array is supplied. Default 4, hard cap 20.")),
                        ("access", ToolSchema.enumStringSchema(["read_only", "inherit"], "Worker capability mode. read_only (default) performs prompt-only reasoning. inherit exposes the ordinary NativeAgent tool loop under the same live TrustCenter and workspace gates as the parent; nested delegation and app install/restart remain parent-only.")),
                        ("readOnly", ToolSchema.boolSchema("Compatibility alias: true maps to access=read_only; false maps to access=inherit.")),
                        ("mode", ToolSchema.strSchema("Optional label such as parallel, council, review, or bughunt.")),
                        ("maxParallel", ToolSchema.intSchema("Maximum concurrent workers. Clamped by trust policy.")),
                        ("timeoutSeconds", ToolSchema.intSchema("Per-worker timeout, default 240, capped 900.")),
                        ("synthesize", nullableRecallField(ToolSchema.boolSchema("Whether to run a final synthesis pass. Defaults true for multi-worker runs."))),
                        ("dryRun", ToolSchema.boolSchema("If true, return the planned workers without calling providers.")),
                        ("maxOutputChars", ToolSchema.intSchema("Per-worker and synthesis output cap, default 4000, max 12000.")),
                        ("digestBudgetTokens", ToolSchema.intSchema("Optional soft token budget for the synthesis digest relayed back. When set, the digest is truncated to ~this many tokens with an explicit notice. Omit (default) for no extra truncation.")),
                    ],
                    required: ["objective"]
                )
            ),
            // ── Mac integration chat tools (2026-06-07) ──
            // Each tool is gated by MacIntegrationPermissionStore (per-integration
            // READ/WRITE bits the user controls in Settings → Mac Integration). The
            // EventKit / notification / Spotlight backends are injected via the
            // app-side MacIntegrationToolBridge. Defaults bias to READ-only for
            // PII surfaces; the two notification channels are write-only outbound.
            requestedSchema(
                name: "mac_calendar_calendars",
                toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "List local EventKit calendars with stable IDs and write access. Requires Calendar Read and full EventKit access. Choose a destination explicitly by ID.",
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            requestedSchema(
                name: "mac_calendar_free_busy",
                toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "Check local free/busy across every calendar (or the exact EventKit calendar IDs given) over at most 31 days. Includes tentative and unavailable intervals; unsupported availability is unknown, never free. Requires Calendar Read and full EventKit access.",
                parametersJSON: ToolSchema.params(properties: [
                    ("calendar_ids", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.strSchema()), ("minItems", .int(1)), ("maxItems", .int(50)), ("description", .string("Optional; omit to check every calendar."))])),
                    ("start", stringOrIntSchema("Window start: ISO-8601 or epoch seconds.")),
                    ("end", stringOrIntSchema("Window end after start: ISO-8601 or epoch seconds."))
                ], required: ["start", "end"])
            ),
            requestedSchema(
                name: "mac_calendar_list_upcoming",
                toolClass: .read, reach: .his,
                description: "List the user's Mac calendar events from EventKit. Read-only; requires Calendar -> Read permission. Returns event titles, start/end timestamps, calendar names, and locations. For today/tomorrow/specific-date questions, pass day ('today', 'tomorrow', or 'YYYY-MM-DD') instead of relying on a broad hours window.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("day", ToolSchema.strSchema("Optional local-day scope: 'today', 'tomorrow', or 'YYYY-MM-DD'.")),
                        ("range", ToolSchema.strSchema("Natural local range: today, tomorrow, this week, next week, or next N days (1–30). Takes precedence over day and hours_ahead; this week runs from now to the end of the local calendar week; next week is the whole following calendar week.")),
                        ("hours_ahead", ToolSchema.intSchema("Lookahead window in hours (1-720, default 24).")),
                        ("days", ToolSchema.intSchema("Optional: the next N days (1–30), same as range 'next N days'.")),
                        ("limit", ToolSchema.intSchema("Maximum events to return (1-100, default 20).")),
                        ("calendar_name", ToolSchema.strSchema("Optional filter — return events only from this calendar.")),
                        ("calendar_id", ToolSchema.strSchema("Optional exact EventKit calendar ID from calendar.calendars.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mac_reminders_query",
                toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "Find Mac Reminders across all dates, including undated tasks. Searches titles and notes; incomplete reminders by default. Read-only; requires Reminders → Read permission. Follow next_offset with the same filters for more results.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Optional text to find in titles or notes (case insensitive).")),
                        ("list_name", ToolSchema.strSchema("Optional list-name filter (case insensitive contains).")),
                        ("due_start", stringOrIntSchema("Inclusive due-range start: ISO-8601, local YYYY-MM-DD, or epoch seconds.")),
                        ("due_end", stringOrIntSchema("Exclusive due-range end; undated tasks are excluded from date ranges.")),
                        ("undated_only", ToolSchema.boolSchema("Return only tasks with no due date; cannot be combined with a due range.")),
                        ("include_completed", ToolSchema.boolSchema("Include completed reminders (default false).")),
                        ("offset", ToolSchema.intSchema("Result offset (default 0); use next_offset from the preceding page.")),
                        ("limit", ToolSchema.intSchema("Maximum reminders from one native snapshot (1-200, default 20).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mac_reminders_read",
                toolClass: .read, reach: .his,
                description: "Read exactly one Mac Reminder by id, regardless of due date or completion. Returns current title, list, due date, completion and full notes. Read-only; requires Reminders → Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [("id", ToolSchema.strSchema("Exact reminder id from a reminder query, read or creation."))],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_list_due_today",
                toolClass: .read, reach: .his,
                description: "List Mac Reminders due today and overdue, earliest first. Returns total and has_more; a capped list cannot rule out reminders due today. Read-only; requires Reminders -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Maximum reminders to return (1-200, default 50).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mac_notify",
                toolClass: .write, capabilities: ["external_send", "notification", "tool_call"],
                description: "Post a macOS user notification on this Mac. Requires Mac Notifications -> Write permission. Use for short, actionable alerts, not as a substitute for chat.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Notification title (required, short).")),
                        ("message", ToolSchema.strSchema("Notification body text (required).")),
                        ("subtitle", ToolSchema.strSchema("Optional subtitle shown between title and body.")),
                    ],
                    required: ["title", "message"]
                )
            ),
            requestedSchema(
                name: "phone_request",
                toolClass: .read, capabilities: ["external_send", "notification", "tool_call"],
                description: "Ask your paired iPhone for its current location or a photo chosen or taken by the person. Open NativeAgent on the phone to respond. Waits for a result; phone permissions apply.",
                parametersJSON: ToolSchema.params(properties: [
                    ("kind", ToolSchema.enumStringSchema(["location.current", "photo.pick", "photo.capture"], "What to ask for.")),
                    ("params", .object(["type": .string("object"), "description": .string("Leave empty."),
                        "properties": .object([:]), "additionalProperties": .bool(false)])),
                    ("wait_seconds", ToolSchema.intSchema("Seconds to wait (1–120; default 60).", minimum: 1, maximum: 120)),
                ], required: ["kind"])
            ),
            requestedSchema(
                name: "mobile_notify",
                toolClass: .write, capabilities: ["external_send", "notification", "tool_call"],
                description: "Push a notification to the paired iPhone via the NativeAgent mobile bridge. Requires iPhone Notifications -> Write permission. Use sparingly; these wake the phone.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Notification title (required, short).")),
                        ("message", ToolSchema.strSchema("Notification body text (required).")),
                        ("subtitle", ToolSchema.strSchema("Optional subtitle.")),
                        ("source", ToolSchema.strSchema("Optional source tag for tracking (e.g. 'calendar_reminder').")),
                    ],
                    required: ["title", "message"]
                )
            ),
            requestedSchema(
                name: "mac_spotlight_search",
                toolClass: .read, reach: .his,
                description: "Search the Mac with Spotlight and return file paths plus modified_at and added_at dates in files (null when unavailable). Plain words can match file contents; use an exact-name predicate for a filename. Read-only; requires Spotlight -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Spotlight words or predicate. Exact filename: kMDItemFSName == \"hello.txt\". Alias 'q' is also accepted.")),
                        ("q", ToolSchema.strSchema("Alias for 'query'.")),
                        ("name", ToolSchema.strSchema("Filename contains this text, case-insensitive (files named …); use instead of query.")),
                        ("limit", ToolSchema.intSchema("Maximum paths (1-200, default 10).")),
                    ],
                    required: []
                )
            ),
            // Sensitive Mac Integration writes default off and require the user's toggle.
            requestedSchema(
                name: "contacts_search",
                toolClass: .read, reach: .his,
                description: "Search the user's local Mac Contacts by name (including saved names like Mom or Dad), phone, or email and return matching records (name, organization, phones, emails, identifier). Read-only; requires Contacts -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Search string — matches against name, phone, or email.")),
                        ("limit", ToolSchema.intSchema("Maximum contacts to return (1-100, default 20).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "contacts_create_or_update",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Create a Mac contact, or update one: by identifier, or the single existing contact with the same full name. Phones and emails are added, never replaced. Requires Contacts -> Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("given_name", ToolSchema.strSchema("First name (optional).")),
                        ("family_name", ToolSchema.strSchema("Last name (optional).")),
                        ("organization", ToolSchema.strSchema("Organization / company (optional).")),
                        ("phones", stringArraySchema("Optional list of phone numbers.")),
                        ("emails", stringArraySchema("Optional list of email addresses.")),
                        ("identifier", ToolSchema.strSchema("Contact to update: identifier from contacts.search, or its exact full name.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_list_recent",
                toolClass: .read, reach: .his,
                description: "List Apple Mail's inbox, sent or drafts metadata and exact mailbox totals; inbox_unread_by_category counts Primary, Transactions, Updates, Promotions and unclassified across the whole inbox. Primary is not proof of a human sender. Filtered or explicitly sorted lists cover all categories. Pass scope + message_id + expected_message_id + expected_account_id from one row to read a body and attachments (filename, content_type, size in bytes, 1-based index). Read-only; requires Mail → Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Maximum messages to return (1-50, default 10).")),
                        ("scope", ToolSchema.strSchema("Mailbox scope: inbox (default), sent or drafts. Keep the same scope for continuation and message-body reads.")),
                        ("mailbox", ToolSchema.enumStringSchema(["inbox", "sent", "drafts"], "Alias for scope; both must agree when supplied together.")),
                        ("all_categories", ToolSchema.boolSchema("Inbox lists show Mail's Primary and Transactions categories; true lists Updates and Promotions too.")),
                        ("unread", ToolSchema.boolSchema("true selects unread messages, false selects read messages; omit for both.")),
                        ("sort", ToolSchema.enumStringSchema(["newest", "oldest"], "Date order; default newest. Keep unchanged for continuation.")),
                        ("offset", mailOffsetSchema),
                        ("message_id", ToolSchema.intSchema("Exact positive message ID from a prior read in the same scope; returns up to 16000 characters of body.", minimum: 1)),
                        ("body_offset", ToolSchema.intSchema("Exact detail continuation offset from body_end, up to 2000000; omit initially.")),
                        ("expected_message_id", ToolSchema.strSchema("Exact RFC message identifier paired with message_id in the prior read.")),
                        ("expected_account", ToolSchema.strSchema("expected_account from the same row, when it has one.")),
                        ("expected_account_id", ToolSchema.strSchema("expected_account_id from the same row; Mail's index checks the account with it.")),
                        ("position", ToolSchema.intSchema("position from the same row: finds the message fast.", minimum: 1)),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_save_attachment",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Save one local Apple Mail attachment by index or unique filename using an observed mail.N name or paired message identity from a Mail read. Defaults to ~/Downloads; destination is a folder within the same writable roots as files.write in the current mode. Never overwrites: adds a numbered suffix. Returns path and size in bytes. Requires Mail Read access; no Mail UI or AppleScript is used.",
                parametersJSON: ToolSchema.params(properties: [
                    ("name", ToolSchema.strSchema("Observed mail.N workspace name; use instead of exact locator fields.")),
                    ("message_id", ToolSchema.intSchema("Exact positive message ID from the Mail read.", minimum: 1)),
                    ("expected_message_id", ToolSchema.strSchema("Exact RFC message identifier paired with message_id.")),
                    ("expected_account", ToolSchema.strSchema("expected_account from the same row, when present.")),
                    ("expected_account_id", ToolSchema.strSchema("expected_account_id from the same row.")),
                    ("scope", ToolSchema.enumStringSchema(["inbox", "sent"], "Mailbox scope from the same row; default inbox.")),
                    ("position", ToolSchema.intSchema("position from the same row, when present.", minimum: 1)),
                    ("index", ToolSchema.intSchema("1-based attachment index from the Mail read; index or filename is required.", minimum: 1)),
                    ("filename", ToolSchema.strSchema("Exact unique attachment filename; index disambiguates duplicate names.")),
                    ("destination", ToolSchema.strSchema("Destination folder; default ~/Downloads."))
                ], required: [])
            ),
            requestedSchema(
                name: "mail_read_batch",
                toolClass: .read, reach: .his,
                description: "Read bodies for 1–10 selected Apple Mail messages in one bounded call. Each item uses an observed workspace name or exact message_id + expected_message_id + expected_account + expected_account_id and scope. Returns ordered per-item receipts, up to 4000 body characters each, and body_end for continuation when truncated. No rediscovery or retry; unfinished items are explicit. Requires Mail Read permission.",
                parametersJSON: ToolSchema.params(properties: [("items", mailBatchItemsSchema(effects: false))], required: ["items"])
            ),
            requestedSchema(
                name: "mail_triage_batch",
                toolClass: .write, reach: .his, capabilities: ["app_data_write", "tool_call"],
                description: "Triage 1–10 selected inbox messages in one bounded call: mark read, flag/unflag, then archive in the source account. Each item uses an observed workspace name or exact message_id + expected_message_id + expected_account; actions require a nonempty RFC identifier. Returns ordered per-item and per-action receipts, including partial effects. Cancellation, deadline or uncertain effects stop remaining work; never replay an uncertain item. No deletion: mail.delete retains its move-to-Trash approval gate. Requires Mail Write permission.",
                parametersJSON: ToolSchema.params(properties: [("items", mailBatchItemsSchema(effects: true))], required: ["items"])
            ),
            requestedSchema(
                name: "mail_search",
                toolClass: .read, reach: .his,
                description: "Search or list Apple Mail's whole inbox, sent or drafts mailbox, all categories, with optional query, from, since, unread, category, attachment; default newest. Returns matching_total, has_more, next_offset and metadata, plus up to five attachment_names per message when filtering attachments. Inbox search results can be passed to mail.mark_read in one call. Bodies are not searched. Requires Mail → Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", stringOrStringArraySchema("One search term or an array of terms matched with OR against mailbox subject and sender metadata. Example: [\"receipt\", \"order confirmation\"]. Keep the same terms for continuation.")),
                        ("from", ToolSchema.strSchema("Sender name or address fragment, matched case and accents aside; combined with other filters using AND.")),
                        ("attachment", ToolSchema.obj([("description", .string("true selects messages with any attachment; a nonempty string matches an attachment filename fragment, case and accents aside. Combined with other filters using AND.")), ("anyOf", .array([
                            ToolSchema.obj([("type", .string("boolean")), ("enum", .array([.bool(true)]))]),
                            ToolSchema.obj([("type", .string("string")), ("minLength", .int(1))]),
                        ]))])),
                        ("since", ToolSchema.strSchema("Inclusive received date: this week (start of the local calendar week), local YYYY-MM-DD, or ISO-8601 with a time zone.")),
                        ("category", ToolSchema.strSchema("Mail categories: primary, transactions, updates, promotions; comma-separated categories combine. A category is not a guarantee of a human sender.")),
                        ("unread", ToolSchema.boolSchema("true selects unread messages, false selects read messages; omit for both.")),
                        ("sort", ToolSchema.enumStringSchema(["newest", "oldest"], "Date order; default newest. Keep unchanged for continuation.")),
                        ("scope", ToolSchema.strSchema("Mailbox scope: inbox (default), sent or drafts. Keep the same scope for continuation and message-body reads.")),
                        ("mailbox", ToolSchema.enumStringSchema(["inbox", "sent", "drafts"], "Alias for scope; both must agree when supplied together.")),
                        ("limit", ToolSchema.intSchema("Maximum messages to return (1-50, default 10).")),
                        ("offset", mailOffsetSchema),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_senders",
                toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "Rank Apple Mail senders by exact message count in one bounded read-only grouped query, with unread count, newest date, address and display name. Covers inbox by default or all indexed mail; supports date, category and unread filters. Useful for sender frequency and unsubscribe candidates. Requires Mail Read permission and macOS Full Disk Access.",
                parametersJSON: ToolSchema.params(properties: [
                    ("limit", ToolSchema.intSchema("Maximum senders to return (1-50, default 15).")),
                    ("since", ToolSchema.strSchema("Inclusive received date: this week, local YYYY-MM-DD, or ISO-8601 with a time zone.")),
                    ("scope", ToolSchema.enumStringSchema(["inbox", "all"], "Mailbox scope; default inbox.")),
                    ("category", ToolSchema.strSchema("Mail categories: primary, transactions, updates, promotions; comma-separated categories combine.")),
                    ("unread_only", ToolSchema.boolSchema("Count and rank only unread messages; default false.")),
                ], required: [])
            ),
            requestedSchema(
                name: "mail_send",
                toolClass: .send, reach: .his, capabilities: ["external_send", "tool_call"],
                description: "Sends an email now through Apple Mail. Requires Mail Write permission, requested inline when needed, or admitted Full Mac access. An explicit Mail Write revocation still applies.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("to", stringOrStringArraySchema("Recipient address(es). May be a single string or list of strings.")),
                        ("subject", ToolSchema.strSchema("Email subject (required).")),
                        ("body", ToolSchema.strSchema("Email body text (required).")),
                        ("cc", stringOrStringArraySchema("Optional CC recipient(s). String or array.")),
                        ("bcc", stringOrStringArraySchema("Optional BCC recipient(s). String or array.")),
                    ],
                    required: ["to", "subject", "body"]
                )
            ),
            requestedSchema(
                name: "messages_recent_threads",
                toolClass: .read, reach: .his,
                description: "Read Messages: from_me selects newest sent or received messages across all conversations, with named participants and exact sent_count or received_count when since is given; otherwise list conversations newest first, filter unread threads, order by oldest unread incoming message, find them by person or words, or open an exact thread. Threads include unread_count across all dates and latest_message_is_read; history includes each message's is_read when chat.db exposes it, otherwise unread_state says unavailable. These are local read flags, not recipient read receipts. Requires Messages Read permission and macOS Full Disk Access. Plain and supported archived text are shown; unsupported formats and attachment content are explicitly unavailable, never presented as empty messages.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Maximum threads or messages to return (1-30, default 10); exact window counts are independent of this limit.")),
                        ("from_me", ToolSchema.boolSchema("true: latest messages sent by you across all threads, newest first, with thread_id, named participants, date and text or attachment label. false: latest received messages. Omit to keep the conversation view. Cannot combine with thread_id, query, unread_only, sort, offset or before_message_id.")),
                        ("since", ToolSchema.strSchema("Inclusive date window for from_me: local YYYY-MM-DD, ISO-8601 with time zone, or this week (start of the local calendar week). Returns exact sent_count for from_me:true or received_count for from_me:false over local message records, including attachments, reactions and special records.")),
                        ("offset", ToolSchema.intSchema("Conversations to skip: next_offset from the previous page; omit initially.")),
                        ("unread_only", ToolSchema.boolSchema("List only threads with unread incoming messages; default false. Omit for an exact thread read.")),
                        ("sort", ToolSchema.enumStringSchema(["newest", "oldest_unread"], "Thread order; default newest. oldest_unread selects threads with unread incoming messages, earliest first, and includes oldest_unread_message_id, oldest_unread_date, oldest_unread_preview and its availability status. Omit for an exact thread read.")),
                        ("query", ToolSchema.strSchema("A person (name, number or email) or words they wrote; lists only matching conversations.")),
                        ("thread_id", ToolSchema.strSchema("Exact thread_id returned by this tool, to inspect that conversation.")),
                        ("before_message_id", ToolSchema.intSchema("Older-page cursor returned as older_before_message_id. Requires the same exact thread_id; omit for recent messages.", minimum: 1)),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "messages_send",
                toolClass: .send, reach: .his, capabilities: ["external_send", "tool_call"],
                description: "Sends a text message now (iMessage/SMS) to an explicit recipient, or sends a reply now to an exact observed Messages thread with its expected participants. Choose exactly one of to or thread_id. Requires Messages write authority.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("to", ToolSchema.strSchema("Phone number or email for a new message (a name: find it with contacts.search). Omit when replying by thread_id.")),
                        ("thread_id", ToolSchema.strSchema("Exact observed Messages thread. Requires expected_participants; do not use a thread ID as to.")),
                        ("expected_participants", stringArraySchema("Exact participant handles from the latest thread read, checked again before sending.")),
                        ("body", ToolSchema.strSchema("Message body (required).")),
                    ],
                    required: ["body"]
                )
            ),
            requestedSchema(
                name: "notes_search",
                toolClass: .read, reach: .his,
                description: "Find and read Apple Notes: blank query lists recent notes, query matches title or text, title (exact) or id returns a body page. Each note reports truncated; continue with its id and next_body_offset as body_offset until false. Read-only; requires Notes → Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Words to find in titles or text; blank lists recent notes.")),
                        ("title", ToolSchema.strSchema("Exact note title: returns a body page.")),
                        ("id", ToolSchema.strSchema("A note's id from an earlier result: returns a body page of that exact note.")),
                        ("body_offset", ToolSchema.intSchema("UTF-16 offset from next_body_offset; requires the same note id. Omit to read from the start.")),
                        ("limit", ToolSchema.intSchema("Maximum notes to return (1-50, default 10).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "notes_create",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Create a new Apple Note with title + body, optionally in a named folder. Requires Notes → Write permission (off by default).",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Note title (required).")),
                        ("body", ToolSchema.strSchema("Note body content (required).")),
                        ("folder", ToolSchema.strSchema("Optional folder name; created in the default folder when omitted. A named folder that does not exist is an error listing the folders that do — it is never silently swapped for the default.")),
                    ],
                    required: ["title", "body"]
                )
            ),
            requestedSchema(
                name: "music_now_playing",
                toolClass: .read, reach: .his, capabilities: ["tool_call"],
                description: "Report what Apple Music is currently playing (track title, artist, album, playback state). Read-only; requires Music → Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [],
                    required: []
                )
            ),
            requestedSchema(
                name: "claude_message",
                toolClass: .send, capabilities: ["external_send", "notification", "tool_call"],
                description: "Send the contact a message through its live inbox door. New work: conversation_mode=new, topic, no conversation_id. Follow-up: resume + its returned conversationId, no topic.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("text", ToolSchema.strSchema("The message to the agent — full prose, no markdown headers needed. Be specific about the requested work or review.")),
                        ("priority", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("info"),
                                .string("important"),
                                .string("urgent"),
                            ])),
                            ("description", .string("Prominence: info=digest; important=highlighted; urgent=🚨 tag.")),
                        ])),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", ToolSchema.strSchema("Short topic for new work, e.g. bug-music-tcc. On resume, omit or use the topic after claude: in conversation_id.")),
                        ("conversation_id", conversationReferenceSchema("claude", "claude_message")),
                        ("expects_reply", ToolSchema.boolSchema("false for an FYI that needs no answer. Omit for questions and work.")),
                        ("pair_reviewer", ToolSchema.boolSchema("true for implementation needing one paired reviewer: builder pairs at start, commits, supplies exact SHA for review, receives findings and owns fixes. Omit for notes/questions/review-only work.")),
                        ("desk_item", nonEmptyStringSchema("Omit unless copied exactly from a live desk.read number/handle in this conversation. Never invent/guess/reuse remembered IDs or placeholders ('none'). A live ID binds terminal execution/delivery evidence to that Desk item; nonlive IDs are ignored and delivery proceeds unbound.")),
                        ("working_directory", ToolSchema.strSchema("Optional existing absolute project directory the work is about, noted in her inbox. Canonical workspace/source paths work normally; others require active Full Mac + allowed outside-workspace access.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "omp_message",
                toolClass: .send, capabilities: ["external_send", "notification", "tool_call"],
                description: "Send an asynchronous task to the local OMP CLI harness (Kimi K3). Set conversation_mode=new and omit conversation_id for unrelated work; set conversation_mode=resume and pass this tool's exact returned conversationId only for a contextual follow-up. A new coding conversation receives its own Git worktree and a resume reuses it. The final reply or honest failure/timeout receipt returns as an '[omp-wake] Automated completion event'.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("text", ToolSchema.strSchema("The complete task or question for OMP.")),
                        ("priority", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array([.string("info"), .string("important"), .string("urgent")])),
                            ("description", .string("Receipt prominence.")),
                        ])),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", ToolSchema.strSchema("Optional short stable topic for new work. Omit on resume; the conversationId already owns the topic.")),
                        ("conversation_id", conversationReferenceSchema("omp", "omp_message")),
                        ("desk_item", nonEmptyStringSchema("Omit unless copied exactly from a live desk.read number/handle in this conversation. Never invent/guess/reuse remembered IDs or placeholders ('none'). A live ID binds terminal execution/delivery evidence to that Desk item; nonlive IDs are ignored and delivery proceeds unbound.")),
                        ("working_directory", ToolSchema.strSchema("Optional existing absolute project directory for a new OMP conversation. External paths require Full Mac with outside-workspace access allowed. Follow-ups always reuse their assigned private worktree; omit working_directory on a follow-up (a different value is ignored and noted on the receipt).")),
                        ("timeout_seconds", ToolSchema.intSchema("OMP wall-clock guard, clamped 60-3600 seconds. Default 900.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "invoke_codex",
                toolClass: .send, capabilities: ["agent_delegate", "process_spawn", "tool_call"],
                description: "Invoke Codex as a blocking subprocess for a focused real-time question or short inspection. Writes an audit envelope under data/from_codex/.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("text", ToolSchema.strSchema("The question or task for Codex. Be specific; Codex is a fresh subprocess and only knows the context you provide.")),
                        ("context", ToolSchema.strSchema("Optional preface: what you were doing, what failed, file paths, errors, and desired outcome.")),
                        ("cwd", ToolSchema.strSchema("Working directory for Codex. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                        ("skip_git_repo_check", ToolSchema.boolSchema("Allow a focused file repair in a folder outside a Git repository. Sandbox and Trust still apply.")),
                        ("timeout_seconds", ToolSchema.intSchema("Maximum blocking wait. Default 600 seconds.")),
                        ("commit_hash", ToolSchema.strSchema("Optional git commit hash to anchor the context.")),
                        ("model", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array(OpenAIExecutionControls.codexBridgeModelIDs.map(JSONValue.string))),
                            ("description", .string("Optional per-call Codex model. Omit to inherit the active Codex CLI default.")),
                        ])),
                        ("reasoning_effort", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("low"),
                                .string("medium"),
                                .string("high"),
                                .string("xhigh"),
                                .string("max"),
                                .string("ultra"),
                            ])),
                            ("description", .string("Optional per-call Codex thinking level. Available levels depend on the selected model. Omit to inherit the Codex default.")),
                        ])),
                        ("fast", ToolSchema.boolSchema("Optional per-call Fast mode. true selects Codex priority service; false explicitly selects default service; omit to inherit the Codex default.")),
                        ("sandbox", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("read-only"),
                                .string("workspace-write"),
                                .string("danger-full-access"),
                            ])),
                            ("description", .string("Codex sandbox. Omit to follow Trust: Full Mac runs danger-full-access, lower Trust workspace-write. danger-full-access requires Full Mac.")),
                        ])),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "codex_message",
                toolClass: .send, capabilities: ["external_send", "notification", "tool_call"],
                description: "Send an asynchronous note/task to Codex. Set conversation_mode=new and omit conversation_id for unrelated work; set conversation_mode=resume and pass this tool's exact returned conversationId only for a contextual follow-up. A new coding conversation receives its own Git worktree and a resume reuses it. NativeAgent durably queues the task, starts or queues a Codex app-server turn, and returns Codex's final answer through the local bridge.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("text", ToolSchema.strSchema("The message to Codex. Include enough context to be useful in a later Codex session.")),
                        ("priority", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("info"),
                                .string("important"),
                                .string("urgent"),
                            ])),
                            ("description", .string("How prominently to surface this in the Codex bridge inbox.")),
                        ])),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", ToolSchema.strSchema("Optional short topic tag for new work. Omit on resume; the conversationId already owns the thread.")),
                        ("conversation_id", conversationReferenceSchema("codex", "codex_message")),
                        ("completion_mode", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array([.string("report"), .string("receipt_only")])),
                            ("description", .string("How Codex's terminal result returns. Use report for delegated work or a question whose answer the agent must assess. Use receipt_only for a one-way acknowledgment, status note, approval, or handoff that should settle durably without creating another chat turn. Defaults to report.")),
                        ])),
                        ("pair_reviewer", ToolSchema.boolSchema("true for implementation needing one paired reviewer: builder pairs at start, commits, supplies exact SHA for review, receives findings and owns fixes. Omit for notes/questions/review-only work.")),
                        ("desk_item", nonEmptyStringSchema("Omit unless copied exactly from a live desk.read number/handle in this conversation. Never invent/guess/reuse remembered IDs or placeholders ('none'). A live ID binds terminal execution/delivery evidence to that Desk item; nonlive IDs are ignored and delivery proceeds unbound.")),
                        ("model", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array(OpenAIExecutionControls.codexBridgeModelIDs.map(JSONValue.string))),
                            ("description", .string("Optional model for this asynchronous Codex task. Omit to inherit the active Codex default.")),
                        ])),
                        ("reasoning_effort", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("low"),
                                .string("medium"),
                                .string("high"),
                                .string("xhigh"),
                                .string("max"),
                                .string("ultra"),
                            ])),
                            ("description", .string("Optional thinking level for this task. Available levels depend on the selected model.")),
                        ])),
                        ("fast", ToolSchema.boolSchema("Optional Fast mode for this task. true selects Codex priority service; false selects default service.")),
                        ("working_directory", ToolSchema.strSchema("Optional existing absolute project directory for a new Codex conversation. Canonical NativeAgent workspace/source paths work normally; any other directory requires active Full Mac with outside-workspace access allowed. Follow-ups always reuse their assigned private worktree; omit working_directory on a follow-up (a different value is ignored and noted on the receipt).")),
                        ("repository", ToolSchema.strSchema("New work only: optional GitHub repository as 'owner/name' (never a filesystem path). NativeAgent resolves it to a local clone whose git remote actually points at that repository and runs Codex there with repository network access. Omit or send an empty string on resume because the saved conversation owns its checkout; any repository hint on a resume is ignored. An unknown repository is ignored rather than failing the send.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "music_control",
                toolClass: .write, reach: .his,
                description: "Play, pause or skip in Apple Music, or play a playlist or song by name in one call (playlist / track). Returns what is playing after. Requires Music → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("action", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("play"),
                                .string("pause"),
                                .string("toggle"),
                                .string("next"),
                                .string("previous"),
                            ])),
                            ("description", .string("play / pause / toggle / next / previous. Default play when playlist or track is given; with nothing given it only reports what's playing.")),
                        ])),
                        ("playlist", ToolSchema.strSchema("Playlist name to play.")),
                        ("track", ToolSchema.strSchema("Exact song name to play; several with that name play nothing and are listed.")),
                        ("artist", ToolSchema.strSchema("Artist, to pick among songs with the same name.")),
                    ],
                    required: []
                )
            ),
            // Sensitive writes default off; scheduler.write defaults on with no read axis.
            requestedSchema(
                name: "mac_calendar_create_event",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Create a local Calendar entry via EventKit; this does not send invitations. With full access, choose an explicit destination; with write-only access, omit calendar_id and calendar_name to use the system default. Requires Calendar Write permission. start/end accept ISO-8601 or epoch seconds.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Event title (required).")),
                        ("start", stringOrIntSchema("Start time — ISO-8601 string (e.g. '2026-06-07T15:00:00Z') or integer epoch seconds (required).")),
                        ("end", stringOrIntSchema("Optional end time — ISO-8601 string or integer epoch seconds. Defaults to start + 1 hour.")),
                        ("notes", ToolSchema.strSchema("Optional notes / description.")),
                        ("location", ToolSchema.strSchema("Optional location string.")),
                        ("calendar_name", ToolSchema.strSchema("Unique exact calendar name, only when calendar_id is omitted; ambiguous names fail.")),
                        ("calendar_id", ToolSchema.strSchema("Explicit EventKit calendar ID from calendar.calendars. Required with full access unless a unique exact calendar_name is supplied. With write-only access, omit calendar_id and calendar_name to use the system default.")),
                    ],
                    required: ["title", "start"]
                )
            ),
            requestedSchema(
                name: "mac_calendar_modify_event",
                toolClass: .write, reach: .his,
                description: "Modify an existing calendar event. Requires id from a prior calendar.upcoming. Pass only the fields to change. Requires Calendar → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("EKEvent identifier from calendar.upcoming (required).")),
                        ("title", ToolSchema.strSchema("New event title.")),
                        ("start", stringOrIntSchema("New start time — ISO-8601 string or epoch seconds.")),
                        ("end", stringOrIntSchema("New end time — ISO-8601 string or epoch seconds.")),
                        ("notes", ToolSchema.strSchema("New notes/body text.")),
                        ("location", ToolSchema.strSchema("New location.")),
                        ("clear_fields", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.enumStringSchema(["notes", "location"])),
                            ("description", .string("Fields to empty on the event. A field also given a value keeps that value."))])),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "mac_calendar_delete_event",
                toolClass: .destructive, reach: .his, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                description: "Delete exactly one calendar event occurrence by id from calendar.upcoming. Requires the observed title and start as preconditions; a changed event is not deleted. Never deletes a recurring series. Requires Calendar → Write and EventKit full access. Use only for an explicitly requested deletion.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("Exact EKEvent identifier from calendar.upcoming.")),
                        ("expected_title", ToolSchema.strSchema("Exact title observed for this event.")),
                        ("expected_start", stringOrIntSchema("Observed start time, ISO-8601 or epoch seconds.")),
                    ],
                    required: ["id", "expected_title", "expected_start"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_create",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Create a new reminder in the user's Mac Reminders via EventKit. Requires Reminders -> Write permission (off by default).",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("Reminder title (required).")),
                        ("notes", ToolSchema.strSchema("Optional notes.")),
                        ("due_date", stringOrIntSchema("Optional due date — ISO-8601 string or integer epoch seconds.")),
                        ("list_name", ToolSchema.strSchema("Optional list name — defaults to the default list when omitted.")),
                    ],
                    required: ["title"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_list_rename",
                toolClass: .write, reach: .his, capabilities: ["safe_read", "tool_call"],
                description: "Rename exactly one Mac Reminders list via EventKit and read back its saved name. Matches names ignoring case and whitespace; emoji and variation selectors are significant. Refuses ambiguous or read-only lists and duplicate destination names. Requires Reminders → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("list", ToolSchema.strSchema("Exact existing Reminders list name.")),
                        ("new_name", ToolSchema.strSchema("New nonempty, unique list name.")),
                    ],
                    required: ["list", "new_name"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_list_create",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "safe_read", "tool_call"],
                description: "Create a Mac Reminders list via EventKit in the default reminder list's account and read back its saved name. Refuses duplicate names or an unavailable or read-only default list. Requires Reminders → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [("name", ToolSchema.strSchema("Nonempty, unique name for the new Reminders list."))],
                    required: ["name"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_update",
                toolClass: .write, reach: .his,
                description: "Update exactly one Mac Reminder by id. Change only supplied title, notes or due_date; preserves its list and completion. Requires Reminders → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("Exact reminder id from a reminder query, read or creation.")),
                        ("title", ToolSchema.strSchema("New nonempty title; omitted leaves it unchanged.")),
                        ("notes", ToolSchema.strSchema("New notes; omitted leaves them unchanged. Use clear_fields to remove them.")),
                        ("due_date", stringOrIntSchema("New due date: ISO-8601, local YYYY-MM-DD, or epoch seconds; omitted leaves it unchanged. Use clear_fields to remove it.")),
                        ("clear_fields", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.enumStringSchema(["notes", "due_date"])),
                            ("description", .string("Fields to clear: notes or due_date. Do not also supply a value for a cleared field."))])),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_complete",
                toolClass: .write, reach: .his,
                description: "Mark a Mac Reminder done by its title (or id from reminders.due_today). Requires Reminders → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("title", ToolSchema.strSchema("The reminder's exact title (case aside).")),
                        ("id", ToolSchema.strSchema("Reminder id from reminders.due_today, when known.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mac_reminders_delete",
                toolClass: .destructive, reach: .his, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                description: "Delete exactly one Mac Reminder by id from reminders.create or reminders.due_today. Requires its observed title as a precondition; a changed reminder is not deleted. Requires Reminders → Write permission. Use only for an explicitly requested deletion.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("Exact reminder id from reminders.create or reminders.due_today.")),
                        ("expected_title", ToolSchema.strSchema("Exact title observed for this reminder.")),
                    ],
                    required: ["id", "expected_title"]
                )
            ),
            requestedSchema(
                name: "mail_mark_read",
                toolClass: .write, reach: .his, capabilities: ["app_data_write", "tool_call"],
                description: "Mark read a selected inbox result set: pass messages from mail.search (1–50) as the only argument. Returns per-message receipts; partial or uncertain work is explicit. If unread search has_more, repeat the same search without offset after marking, since the result set shrinks. Also accepts one exact locator or every message with a subject. Requires Mail → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("messages", mailBatchItemsSchema(effects: true, markReadOnly: true)),
                        ("message_id", ToolSchema.intSchema("Inbox message_id from mail.recent.", minimum: 1)),
                        ("expected_message_id", ToolSchema.strSchema("expected_message_id from the same row.")),
                        ("expected_account", ToolSchema.strSchema("expected_account from the same row, when it has one.")),
                        ("position", ToolSchema.intSchema("position from the same row: finds the message fast.", minimum: 1)),
                        ("subject", ToolSchema.strSchema("Or the message's subject, when there's no message_id.")),
                        ("sender", ToolSchema.strSchema("Optional sender filter with subject.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_archive",
                toolClass: .write, reach: .his,
                description: "Archive one inbox message by message_id + expected_message_id from mail.recent, or a subject only one message has. Requires Mail → Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("message_id", ToolSchema.intSchema("Inbox message_id from mail.recent.", minimum: 1)),
                        ("expected_message_id", ToolSchema.strSchema("expected_message_id from the same row.")),
                        ("expected_account", ToolSchema.strSchema("expected_account from the same row, when it has one.")),
                        ("position", ToolSchema.intSchema("position from the same row: finds the message fast.", minimum: 1)),
                        ("subject", ToolSchema.strSchema("Or the message's subject, when there's no message_id.")),
                        ("sender", ToolSchema.strSchema("Optional sender filter with subject.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_delete",
                toolClass: .write, reach: .his, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                description: "Move one message to its account's Trash, including archived mail, by message_id + expected_message_id from a prior read, or a subject only one indexed message has. Rechecks identity in its current mailbox. Never permanently deletes. Requires Mail → Write permission and the existing approval policy.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("message_id", ToolSchema.intSchema("Message_id from a prior Mail read; the message may have been archived since that read.", minimum: 1)),
                        ("expected_message_id", ToolSchema.strSchema("expected_message_id from the same row.")),
                        ("expected_account", ToolSchema.strSchema("expected_account from the same row, when it has one.")),
                        ("position", ToolSchema.intSchema("Optional prior position hint; deletion locates the current mailbox by indexed identity.", minimum: 1)),
                        ("subject", ToolSchema.strSchema("Or the message's subject, when there's no message_id.")),
                        ("sender", ToolSchema.strSchema("Optional sender filter with subject.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_reply",
                toolClass: .send, reach: .his, capabilities: ["external_send", "tool_call"],
                description: "Sends a reply now to an exact inbox message_id plus expected_message_id, or a uniquely matching subject (and optional sender). Ambiguous or changed targets are refused. Requires Mail → Write permission (off by default).",
                parametersJSON: ToolSchema.params(properties: mailReplyFields, required: ["body"])
            ),
            requestedSchema(
                name: "mail_draft",
                toolClass: .write, reach: .his,
                description: "Saves an unsent email in Apple Mail → Drafts, without sending or opening a window. Use for draft, don't send, just draft, save as draft or not yet requests. For a reply, use an exact inbox message_id plus expected_message_id, or a uniquely matching subject (and optional sender); ambiguous or changed targets are refused. For a new email, supply to, subject and body instead. Requires Mail Write permission. Confirms a new Drafts message by subject, recipients and content after saving; returns created, saved_in and the saved message's draft_id. Inspect drafts with mail.recent or mail.search using mailbox:\"drafts\"; never repeat an unconfirmed save before checking.",
                parametersJSON: ToolSchema.params(properties: mailReplyFields + [
                    ("to", stringOrStringArraySchema("Recipient address(es) for a new draft. Omit for a reply draft.")),
                    ("cc", stringOrStringArraySchema("Optional CC recipient(s) for a new draft.")),
                    ("bcc", stringOrStringArraySchema("Optional BCC recipient(s) for a new draft.")),
                ], required: ["body"])
            ),
            requestedSchema(
                name: "notes_update",
                toolClass: .write, reach: .his,
                description: "Update one Apple Note by id from notes.search or a unique exact title. Supply body, append, new_title or clear_fields:[\"body\"]. Clearing empties the body and cannot be combined with body/append. Requires Notes → Write permission (off by default).",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("The note's id from notes.search; use it when two notes share a title.")),
                        ("title", ToolSchema.strSchema("Exact title of the note to update (as notes.search shows it).")),
                        ("body", ToolSchema.strSchema("Replace the note's text under its title; the title stays unless new_title is given.")),
                        ("append", ToolSchema.strSchema("Add this as a new line at the end of the note.")),
                        ("new_title", ToolSchema.strSchema("Rename the note to this title.")),
                        ("clear_fields", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.enumStringSchema(["body"])),
                            ("description", .string("[\"body\"] is a valid update by itself; empties the body. Cannot combine with body or append."))])),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "notes_delete",
                toolClass: .write, reach: .his, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                description: "Delete one Apple Note by id or an exact title only one note has. Moves it to Recently Deleted, where it can be restored; returns that reversible outcome. Requires Notes → Write permission (off by default).",
                parametersJSON: ToolSchema.params(properties: [
                    ("id", ToolSchema.strSchema("The note's id from notes.search; use it when two notes share a title.")),
                    ("title", ToolSchema.strSchema("Exact title of the note to delete; duplicate titles refuse without changing anything.")),
                ], required: [])
            ),
            requestedSchema(
                name: "music_search_library",
                toolClass: .read, reach: .his,
                description: "Search the user's Apple Music library by query, returning matching tracks, artists, or albums. Read-only; requires Music -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Search string (required).")),
                        ("kind", ToolSchema.obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("track"),
                                .string("artist"),
                                .string("album"),
                            ])),
                            ("description", .string("What to search for — one of track / artist / album. Defaults to track.")),
                        ])),
                        ("limit", ToolSchema.intSchema("Maximum results to return (1-100, default 20).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "music_list_library",
                toolClass: .read, reach: .his,
                description: "Page through the user's Apple Music library tracks without a search query. Read-only; requires Music -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("offset", ToolSchema.intSchema("Zero-based track offset. Defaults to 0.")),
                        ("limit", ToolSchema.intSchema("Maximum tracks to return (1-100, default 50).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "music_list_playlists",
                toolClass: .read, reach: .his,
                description: "Page through the user's Apple Music playlists, returning names and track counts. Read-only; requires Music -> Read permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("offset", ToolSchema.intSchema("Zero-based playlist offset. Defaults to 0.")),
                        ("limit", ToolSchema.intSchema("Maximum playlists to return (1-100, default 50).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "contacts_delete",
                toolClass: .destructive, reach: .his, capabilities: ["destructive", "filesystem_delete", "outside_app_data_write", "tool_call"],
                description: "Delete a Mac contact by its identifier from contacts.search or its exact full name. Requires Contacts -> Write permission.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("identifier", ToolSchema.strSchema("identifier from contacts.search, or the exact full name.")),
                    ],
                    required: ["identifier"]
                )
            ),
            requestedSchema(
                name: "scheduler_list_jobs",
                toolClass: .read, reach: .his,
                description: "List queued and scheduled TriggerScheduler jobs (id, title, action_id, trigger time, status). Requires Scheduler → Write permission (scheduler has no read axis; defaults on).",
                parametersJSON: ToolSchema.params(
                    properties: [],
                    required: []
                )
            ),
            requestedSchema(
                name: "scheduler_create_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Schedule a task/notification with kind, its payload, and one of in_minutes, schedule or interval_seconds (forms/required payloads below). Workshop queues a Desk task each time; scheduling is not completion. For a recurring helper use bot.create/bot.update with schedule/cadence. Repeating intervals: ≥60 seconds. A repeating dream reuses/reactivates the nightly reflection job; once adds an extra dream. Requires Scheduler → Write (defaults on). Example: {\"kind\":\"notify\",\"payload\":{\"title\":\"Reminder\",\"message\":\"Review the notes.\"},\"interval_seconds\":86400}.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(["notify", "connector_action", "dream", "rem", "harness_benchmark", "proactive_scan", "workshop"], "Use workshop to do work on each run; notify delivers a fixed message.")),
                        ("payload", nullableRecallField(looseObjectSchema("Per-kind parameters. workshop: {title, objective}; include result delivery instructions in objective. notify: {title, message, delivery}; delivery selects notification channels only. connector_action requires actionId; input is optional. dream/rem accept objective; proactive_scan accepts reason and limit."))),
                        ("in_minutes", nullableRecallField(numSchema("One-time delay from now in minutes, e.g. 10 for a ten-minute timer. Use kind notify and payload.message. Supply this alone instead of schedule or interval_seconds; no time.now call is needed."))),
                        ("schedule", stringOrLooseObjectSchema("When to fire. Supply this, in_minutes or interval_seconds; omit or null unused fields. ISO-8601 datetime, 'in 10 minutes', or object with type once/every/hourly/daily/weekly/monthly/cron. Cron accepts expression or cron. Times are on this Mac's local clock and follow it when it changes zone; there is no timezone field. Example: {\"type\":\"every\",\"interval_seconds\":86400}.")),
                        ("interval_seconds", nullableRecallField(ToolSchema.intSchema("Repeating interval in seconds when schedule is omitted or null. Example: 86400.", minimum: 60))),
                    ],
                    required: ["kind"]
                )
            ),
            requestedSchema(
                name: "scheduler_cancel_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Cancel a reminder or scheduled job by id from schedule.list. Stops future runs and keeps the job in history; schedule.resume can re-enable it. Does not stop an already running action. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(
                name: "scheduler_delete_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Delete a scheduled job or reminder from active scheduling by cancelling it. Same as schedule.cancel: keeps the job in history, can be resumed, and does not stop an already running action. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(
                name: "scheduler_pause_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Pause a job or reminder by id from schedule.list. Stops future runs until schedule.resume; preserves its schedule and payload. Does not stop an already running action. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(
                name: "scheduler_resume_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Resume a paused or cancelled scheduled job or reminder by id from schedule.list. Re-enables its saved schedule; an overdue job may run immediately. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(
                name: "scheduler_update_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Edit a scheduled job using job_id from schedule.list and at least one top-level change: name, kind, payload, schedule or interval_seconds. Omit or null unused fields; do not wrap changes in fields. Changing kind requires its complete payload. Supply schedule or interval_seconds, never both; intervals must be integers of at least 60 seconds. Preserves identity, history and paused/cancelled state. A new schedule recalculates the next run; other edits keep it. Does not alter an already running action. Requires Scheduler → Write permission (defaults on). Example for an existing job: {\"job_id\":\"J\",\"schedule\":{\"type\":\"daily\",\"at\":\"09:00\"}}.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares.")),
                        ("name", nullableRecallField(ToolSchema.strSchema("New job name (1-160 characters)."))),
                        ("kind", nullableEnumStringSchema(["notify", "connector_action", "dream", "rem", "harness_benchmark", "proactive_scan", "workshop"], "When changing kind, supply the complete payload for that kind. Example: \"notify\".")),
                        ("payload", nullableRecallField(looseObjectSchema("Changed per-kind parameters, merged into the existing payload unless kind changes. notify: {title, message, delivery}. connector_action: {actionId, input}. Nested values such as input are replaced in full."))),
                        ("schedule", stringOrLooseObjectSchema("Complete replacement schedule: ISO-8601 datetime string, e.g. '2026-09-29T09:00:00-06:00', or {type:'once', at:'ISO-8601'}, {type:'every', interval_seconds:3600}, {type:'hourly', minute:0}, {type:'daily', at:'09:00'}, {type:'weekly', weekdays:['mon'], at:'09:00'}, {type:'monthly', day:1, at:'09:00'}, or {type:'cron', expression:'0 9 * * mon-fri'}. Times are on this Mac's local clock and follow it when it changes zone. Omit interval_seconds when supplying schedule.")),
                        ("interval_seconds", nullableRecallField(ToolSchema.intSchema("Replace the schedule with a repeating interval of at least 60 seconds. Supply this or schedule, not both.", minimum: 60))),
                    ],
                    required: ["job_id"]
                )
            ),
            // Memory writes belong to the agent's own store, so they remain available
            // independently of Full Mac file access.
            requestedSchema(
                name: "commit_memory",
                toolClass: .write, capabilities: ["memory_write", "tool_call"],
                description: "Save a fact, decision or preference for later recall. Put the current decision first with its qualifications, then incident history. For a changed operating agreement, recall existing rules and name replaced ids in supersedes. context_topics declares subject/scope, not authority. text is the thing itself: omit metadata preambles, but keep dates that are part of the fact or decision. Example: {\"text\":\"Sam drinks coffee black\"}.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("text", ToolSchema.strSchema("Nonblank fact/decision/preference: complete current decision and qualifications first, then incident history. Put metadata in its fields, not a date/time/source/id/hash/'record of' preamble. Keep meaningful dates, e.g. deadlines or when a rule takes effect.")),
                        ("provenance", ToolSchema.enumStringSchema(["verified", "told", "inferred"], "How you know this: verified (you checked it yourself), told (someone told you — also set provenance_by), inferred (you worked it out).")),
                        ("provenance_by", ToolSchema.strSchema("Who told you, when provenance=told. A name, e.g. \"Sam\".")),
                        ("source", ToolSchema.strSchema("Alias of provenance_by: who told you, when provenance=told. Prefer provenance_by if supplying both.")),
                        ("kind", ToolSchema.strSchema("Memory kind, e.g. identity/preference/relationship/goal/skill/project/general, or \"moment\" for something you lived and want to keep (first person, say what happened and what it meant). Default \"note\".")),
                        ("valence", numSchema("How it felt, -1 (bad) to 1 (good). Use with kind \"moment\".")),
                        ("tags", stringArraySchema("Optional free-form tags.")),
                        ("confidence", numSchema("How confident this fact is true, 0..1. Default 0.8.")),
                        ("importance", numSchema("How important this fact is to retain, 0..1. Default 0.5.")),
                        ("corrects", ToolSchema.strSchema("Optional id of an existing memory this new fact corrects (e.g. from memory.recall). The old memory is marked lifecycle=corrected with a lineage link to this one and drops out of recall.")),
                        ("supersedes", stringArraySchema("Optional memory ids this replaces; kept in history, excluded from recall.")),
                        ("correction_reason", ToolSchema.strSchema("Optional one-line reason the old memory was wrong (stored on the corrected row's lineage).")),
                        // maxItems/maxLength are declared; minItems deliberately
                        // is NOT. Strict providers materialize every optional
                        // array as [], which this tool treats as omission — a
                        // minItems of 1 would make that legal placeholder
                        // unsendable. The 1-8 floor is stated in prose and
                        // enforced by the validator instead.
                        ("context_topics", stringArraySchema("Read for kind correction/instruction/preference/note; ignored for other kinds. Up to 8 explicit subject/scope phrases, each non-empty and at most 120 characters. Use only the agreement's stated scope, including the named program when it is program-specific. A save returns existing agreements with that same declared scope for your judgment; nothing is retired without explicit supersedes or corrects. Omit for global boundaries; never invent a scope to weaken them. This limits automatic injection, not explicit recall.", maxItems: 8, maxItemLength: 120)),
                    ],
                    required: ["text"]
                )
            ),
            // Workshop tools are lazy-loaded independently of Full Mac file access.
            // Submission retains the runner's policy, slot cap, planner and step approvals.
            requestedSchema(
                name: "workshop_submit",
                toolClass: .write, capabilities: ["tool_call", "workshop_write"],
                description: "Run a user-directed task from the Desk. For an exact workspace file copy, set operation=copy_workspace_file with source and destination. An active reviewed copy procedure runs directly; otherwise the task follows normal planning and approval. Use procedure=local_file_copy_v1 only for explicit/manual compatibility. Every other objective creates a user-directed Desk task, unless desk_handle names an existing live Desk item to run — then the project keeps its own identity instead of gaining a second one. Returns Desk identity and execution status; use workshop.status to follow queued work.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("text", ToolSchema.strSchema("The task objective — what the user wants done (required).")),
                        ("expected_outputs", stringArraySchema("Optional exact phrases that must occur in completed text outputs, e.g. [\"12\"] for arithmetic synthesis. Ordinary tasks only: omit operation and procedure. This verifies text containment, not external effects; omit when no exact text criterion is known.")),
                        ("context", ToolSchema.strSchema("Optional short title/context. Defaults to a prefix of the objective.")),
                        ("desk_handle", ToolSchema.strSchema("Optional live Desk handle or visible alias to execute as — use it when this work is the next piece of a project already on the Desk (name the relevant child, not the whole project, so finishing it does not close everything). Omit to create a new Desk task.")),
                        ("operation", ToolSchema.enumStringSchema(["copy_workspace_file"], "Stable exact operation. Use copy_workspace_file only for an unambiguous byte-for-byte workspace file copy and also provide source and destination. The procedure store chooses an active reviewed implementation; omit for every other task.")),
                        ("procedure", ToolSchema.enumStringSchema(["local_file_copy_v1"], "Optional native procedure. Use the only allowed value, local_file_copy_v1, for a byte-for-byte workspace file copy and also provide source and destination. Omit for every other task.")),
                        ("source", ToolSchema.strSchema("Source path relative to NativeAgent's workspace, without a leading slash. Used only with the exact copy operation/procedure.")),
                        ("destination", ToolSchema.strSchema("Destination path relative to NativeAgent's workspace, without a leading slash. Used only with the exact copy operation/procedure.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "workshop_status",
                toolClass: .read,
                description: "Read task progress in the Desk. Without an id: list active and recent work. With an execution id: return detail and step receipts. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("Optional execution id. Omit to list active and recent Desk tasks.")),
                    ],
                    required: []
                )
            ),
            // Lazy-loaded task ledger tools share the bridge feed and its file lock.
            // Posts are actor-pinned; task_ledger_list is a read.
            requestedSchema(
                name: "task_ledger_post",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Post an event to the cross-agent task ledger: the shared who-owns-what/done/blocked feed for the agent, Codex, and the assistant. Use it to open a task (kind=created), claim one (kind=claimed), log progress (kind=update), flag a blocker (kind=blocked), close it (kind=done/cancelled), or remove it from task views (kind=deleted, with exact task_id and expected_title). Events post as the assistant. Returns the event and its task_id.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(["created", "claimed", "update", "blocked", "done", "cancelled", "deleted"], "Event kind: created | claimed | update | blocked | done | cancelled | deleted.")),
                        ("task_id", ToolSchema.strSchema("The task this event belongs to. Required for everything except 'created' (omit on created to mint a new task id).")),
                        ("title", ToolSchema.strSchema("Short task title (set on created; updates the title if provided later).")),
                        ("expected_title", ToolSchema.strSchema("For deleted: exact current title from ledger.list. The task stays in the audit feed but leaves task views.")),
                        ("note", ToolSchema.strSchema("Optional free-text note for this event (what happened, why blocked, etc.).")),
                        ("refs", stringArraySchema("Optional reference strings — file paths, commit ids, PR urls.")),
                    ],
                    required: ["kind"]
                )
            ),
            // Lazy-loaded local read of durable delegation jobs; no spawn or network.
            requestedSchema(
                name: "delegation_status",
                toolClass: .read,
                description: "Read retained inbox-door or swarm evidence. Prefer agent.read for ordinary conversations; reading both is not independent confirmation. message_id selects exact accepted-message evidence. For a swarm, set agent='swarm' and run_id, then report_id to page retained text without rerunning work. Discarded text is not recoverable; stall_basis='none' means unmeasurable.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Bridge jobs per page: default 8, max 12. With agent='swarm' and report_id: retained text characters per page, default/max 2000.")),
                        ("offset", ToolSchema.intSchema("Bridge result offset, or character offset within the selected swarm report. Follow next_offset; omit on first page.")),
                        ("agent", ToolSchema.strSchema("Optional saved contact or retained inbox-door handle. Omit for every retained door; swarm with run_id reads a swarm receipt.")),
                        ("message_id", ToolSchema.obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Exact messageId from the contact's send receipt, up to 160 characters. Filters recorded identities before paging; never matches topic or filename. Omit for ordinary listing. Missing evidence does not prove work never ran.")),
                        ])),
                        ("run_id", ToolSchema.strSchema("Required only for agent='swarm': exact id returned by agent.swarm. This is an identifier, never a file path.")),
                        ("report_id", ToolSchema.obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("For agent='swarm': exact worker report_id from descriptors, or synthesis. Omit, null, or empty for metadata only; provide to page retained output/error text.")),
                        ])),
                        ("detail", ToolSchema.strSchema("Bridge compact (default) or full lifecycle metadata. Native swarm bodies require report_id; full alone still returns only compact descriptors.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "task_ledger_list",
                toolClass: .read,
                description: "List the cross-agent task ledger — the shared who-owns-what/done/blocked state for the agent, Codex, and you. Without a task_id: the compacted per-task summary (owner, status, last note), newest-updated first. With a task_id: that task's full event timeline. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("task_id", ToolSchema.strSchema("Optional task id. Omit to list all tasks; provide to get one task's event timeline.")),
                        ("include_done", ToolSchema.boolSchema("Include done/cancelled tasks in the list. Default false (open tasks only).")),
                    ],
                    required: []
                )
            ),
            // Personality depth item 3 (2026-09-02) — the introspection pull.
            // ALWAYS-ON (alwaysOnCoreNames). A deliberately SMALL closed schema:
            // two fields, both optional, both clamped. There is nothing to
            // parameterize about her own inner state beyond how far back to look
            // and how much to say, and every extra knob is a way to ask a
            // leading question of herself.
            requestedSchema(
                name: "inner_state",
                toolClass: .read, capabilities: ["tool_call"],
                description: Self.innerStateToolDescription,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("window_hours", numSchema(
                            "How many hours of felt moments to include. 1–168; out-of-range values clamp, and the result says so: window_hours_requested, window_hours_applied and a note naming the cap. Default 6.",
                            minimum: 1,
                            maximum: 168
                        )),
                        ("detail", ToolSchema.enumStringSchema(
                            ["compact", "full"],
                            "compact (default) is the short read: the fingerprint, mood, disposition, body words, and the strongest few of each list. full returns every bounded list at its cap."
                        )),
                    ],
                    required: []
                )
            ),
            // Agent Desk chat lane (agent-desk). desk_read renders the live
            // projection; the nine mutations operate by op against
            // SwiftNativeDeskStore. Same wiring canon as the task-ledger tools:
            // always-on catalog block, LAZY-LOADED (NOT alwaysOnCoreNames).
            requestedSchema(
                name: "desk_read",
                toolClass: .read,
                description: "Read your durable, compact Desk: user-tracked watches/plans/projects/standing concerns, status, cadence and key refs. Numbers are permanent. Default: capped open items, most recently active first, with omissions stated. handle (stable or visible alias) also returns one exact live item's full summary, refs, dependencies/blockees, parts and ordered notes. query searches title/summary/project/alias/handle across the full live store. include_archived appends closed-out archived items. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("include_archived", ToolSchema.boolSchema("Also read archived items matching the same handle or query, in bounded text windows. Exact archived reads require the stable handle. Default false.")),
                        ("archived_offset", ToolSchema.intSchema("Archived text continuation: copy from next_archive_read; omit initially.")),
                        ("handle", ToolSchema.strSchema("Optional exact live Desk handle or visible alias; returns that item's full record (notes, refs, dependencies) as well as the board. Mutually exclusive with query.")),
                        ("query", ToolSchema.strSchema("Optional case-insensitive text search across the full live Desk. Mutually exclusive with handle; returns at most 25 matches.")),
                        ("updated_on", ToolSchema.strSchema("Filter items updated on today or YYYY-MM-DD in the Mac's local timezone. With include_archived, filters archives by their closed date. Can combine with query.")),
                        ("structured", ToolSchema.boolSchema("Return selectable canonical rows and evidence, with bounded page continuations. Used by workspace; default false retains the rendered board.")),
                        ("sort", ToolSchema.strSchema("Set \"stale\" to list ALL open top-level items oldest-touched first as lean rows (id = desk number, title, status, updated date) for triage. Ignored with handle or query.")),
                        ("offset", ToolSchema.intSchema("Structured view continuation: row offset; omit initially.")),
                        ("notes_offset", ToolSchema.intSchema("Structured selected-record continuation: note offset; omit initially.")),
                        ("refs_offset", ToolSchema.intSchema("Structured selected-record continuation: linked-evidence offset; omit initially.")),
                        ("detail_offset", ToolSchema.intSchema("Read a bounded window of the complete selected record, including full notes. Omit for the selectable overview; start at zero.")),
                        ("detail_version", ToolSchema.strSchema("Exact complete-record version returned by the owner. Required for a nonzero detail_offset; changed records must restart.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "desk_add_item",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Add a Desk item: kind=watch|plan|project|gh|standing, project bucket and short title; optional parent nesting. For delegation, set assignee and lane_of (coordinating Desk item) as fields, not prose. A live same-title/project/parent item returns disposition=existing; allow_duplicate=true is only for intentional equivalents. Returns status=ok, created, disposition, stable handle and view alias (\"2\", \"2.1\").",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(["watch", "plan", "project", "gh", "standing"], "Item kind: watch | plan | project | gh | standing.")),
                        ("project", ToolSchema.strSchema("Project bucket this item belongs to.")),
                        ("title", ToolSchema.strSchema("Short item title.")),
                        ("until", ToolSchema.strSchema("Optional yyyy-MM-dd or ISO timestamp to defer the item in this same add call.")),
                        ("defer", ToolSchema.strSchema("Alias for until; if both are supplied, they must agree.")),
                        ("parent", ToolSchema.strSchema("Optional parent item handle to nest this item under.")),
                        ("summary", ToolSchema.strSchema("Optional one-line summary. Desk has no priority field; offer a searchable tag here, then use desk.read query to find it.")),
                        ("assignee", ToolSchema.strSchema("Optional freeform delegation assignee, such as the coding agent.")),
                        ("lane_of", ToolSchema.strSchema("Optional coordinating Desk item handle (or visible alias) for this delegated task. This link does not change Desk hierarchy.")),
                        ("allow_duplicate", ToolSchema.boolSchema("Explicitly create a second equivalent live item instead of reusing the existing owner. Default false.")),
                    ],
                    required: ["kind", "project", "title"]
                )
            ),
            requestedSchema(
                name: "desk_set_status",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Set Desk status: watch|flag|now|next|todo|done|blocked|canceled (US spelling). Fresh canonical evidence resolving the exact tracked defect/outcome requires updating that item in the same turn. Never close from fuzzy titles, execution completion alone or unattributed commits. blocked requires a reason via blocked_reason, reason, or status='blocked: reason', and/or waiting_on. Delegation assignments/updates include assignee and lane_of; omitted metadata stays unchanged. Report concrete batch progress as progress={done,total,note?}; omit when unknown, never invent 0%. Returns refreshed alias, status and title.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("status", ToolSchema.strSchema("New status: watch | flag | now | next | todo | done | blocked | canceled. Also accepts 'blocked: reason' and stores the reason in the Desk's blocked reason field.")),
                        ("remaining_work", ToolSchema.obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional exact remaining authorized work. Attach a durable continuation to this existing task before starting a long job; settled calls and pending effects survive turn limits and restart. Never repeat an uncertain effect; verify it through its domain first. Omit or send null when only tracking status.")),
                        ])),
                        ("blocked_reason", ToolSchema.strSchema("Why it's blocked (when status=blocked).")),
                        ("reason", ToolSchema.strSchema("Alias for blocked_reason. If both are supplied, they must agree.")),
                        ("waiting_on", ToolSchema.strSchema("Who it's waiting on (when status=blocked); owner pushes the person.")),
                        ("assignee", ToolSchema.obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional assignee update; omitted/null/blank preserves it. Cannot clear assignments.")),
                        ])),
                        ("lane_of", ToolSchema.obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional live coordinating Desk handle/alias for this delegation. Omitted/null/blank preserves the link; cannot clear it. Send null if unchanged; never the item's own handle.")),
                        ])),
                        ("progress", ToolSchema.obj([
                            ("type", .array([.string("object"), .string("null")])),
                            ("description", .string("Optional explicit progress. Requires 0 <= done <= total and total > 0; omit or send null when unknown.")),
                            ("properties", ToolSchema.obj([
                                ("done", ToolSchema.intSchema("Completed units.")),
                                ("total", ToolSchema.intSchema("Total units; must be greater than zero.")),
                                ("note", ToolSchema.strSchema("Optional concise progress note.")),
                            ])),
                            ("required", .array([.string("done"), .string("total")])),
                            ("additionalProperties", .bool(false)),
                        ])),
                    ],
                    required: ["handle", "status"]
                )
            ),
            requestedSchema(
                name: "desk_update_item",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Update a Desk item's title and/or summary. Provide at least one of title/summary. Desk has no priority field; offer a searchable tag in summary and use desk.read query to find it.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("title", ToolSchema.strSchema("New title (optional).")),
                        ("summary", ToolSchema.strSchema("New one-line summary (optional).")),
                    ],
                    required: ["handle"]
                )
            ),
            requestedSchema(
                name: "desk_note",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Append a timestamped note to a Desk item — progress, context, a decision.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("text", ToolSchema.strSchema("The note text.")),
                    ],
                    required: ["handle", "text"]
                )
            ),
            requestedSchema(
                name: "desk_add_ref",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Attach a reference to a Desk item. ref_kind selects the shape and which fields apply: file (path[,line,label]) | commit (sha[,repo,label,status]) | gh_issue (repo,number[,title,status]) | gh_pr (repo,number[,title,status,checks]) | url (url[,title]) | agent (name[,handoff_id,session_id]) | approval (id[,status]) | trace (id[,trace_kind]) | note (text).",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("ref_kind", ToolSchema.enumStringSchema(["file", "commit", "gh_issue", "gh_pr", "url", "agent", "approval", "trace", "note"], "file | commit | gh_issue | gh_pr | url | agent | approval | trace | note.")),
                        ("path", ToolSchema.strSchema("file: path.")),
                        ("line", ToolSchema.intSchema("file: optional line number.")),
                        ("label", ToolSchema.strSchema("file/commit: optional label.")),
                        ("sha", ToolSchema.strSchema("commit: commit sha.")),
                        ("repo", ToolSchema.strSchema("commit/gh_issue/gh_pr: repository.")),
                        ("number", ToolSchema.intSchema("gh_issue/gh_pr: issue/PR number.")),
                        ("title", ToolSchema.strSchema("gh_issue/gh_pr/url: optional title.")),
                        ("status", ToolSchema.strSchema("commit/gh_issue/gh_pr/approval: optional status.")),
                        ("checks", ToolSchema.strSchema("gh_pr: optional CI checks summary.")),
                        ("url", ToolSchema.strSchema("url: the URL.")),
                        ("name", ToolSchema.strSchema("agent: agent name.")),
                        ("handoff_id", ToolSchema.strSchema("agent: optional handoff id.")),
                        ("session_id", ToolSchema.strSchema("agent: optional session id.")),
                        ("id", ToolSchema.strSchema("approval/trace: the id.")),
                        ("trace_kind", ToolSchema.strSchema("trace: optional trace kind.")),
                        ("text", ToolSchema.strSchema("note: the note text.")),
                    ],
                    required: ["handle", "ref_kind"]
                )
            ),
            requestedSchema(
                name: "desk_set_cadence",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Set how often you refresh a Desk item. mode: manual | on_ask | tick | event | daily | weekly | blocked_watch. Optionally set interval, stale_after, and refresh_sources (comma-separated).",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("mode", ToolSchema.enumStringSchema(["manual", "on_ask", "tick", "event", "daily", "weekly", "blocked_watch"], "manual | on_ask | tick | event | daily | weekly | blocked_watch.")),
                        ("interval", ToolSchema.strSchema("Optional refresh interval (e.g. \"1h\", \"1d\").")),
                        ("stale_after", ToolSchema.strSchema("Optional staleness window after which the item is considered stale.")),
                        ("refresh_sources", ToolSchema.strSchema("Optional comma-separated list of refresh sources.")),
                    ],
                    required: ["handle", "mode"]
                )
            ),
            requestedSchema(
                name: "desk_set_notify",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Set when a Desk item should surface to the user. level: quiet | digest | direct | urgent. Optionally set on (comma-separated triggers: state_change | blocked | done | explicit) and a cooldown. Use explicit alone for a one-time announcement.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("level", ToolSchema.enumStringSchema(["quiet", "digest", "direct", "urgent"], "quiet | digest | direct | urgent.")),
                        ("on", ToolSchema.strSchema("Optional comma-separated triggers: state_change | blocked | done | explicit. Use explicit alone for a one-time announcement.")),
                        ("cooldown", ToolSchema.strSchema("Optional notify cooldown (e.g. \"6h\").")),
                    ],
                    required: ["handle", "level"]
                )
            ),
            requestedSchema(
                name: "desk_close",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Close an exact Desk item when the owner explicitly asks to close or mark it done, or fresh canonical evidence proves its tracked outcome. The owner's explicit instruction is sufficient even if earlier notes say work remains; record that instruction in outcome_summary without claiming the underlying work happened. Otherwise put the specific commit/receipt/observed result in outcome_summary; never use fuzzy title matches, execution completion alone or unattributed commits. Sets done (cancelled if canceled=true); stays visible briefly, then becomes archive-eligible.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("outcome_summary", ToolSchema.strSchema("What the outcome was.")),
                        ("canceled", ToolSchema.boolSchema("Close as cancelled instead of done. Default false.")),
                        ("subtree", ToolSchema.boolSchema("Also close every open descendant in this call. Returns closed count + handles. Default false.")),
                        ("expected_updated_at", ToolSchema.strSchema("Optional row version from a just-read Desk projection. When supplied, refuses if the item changed before this close.")),
                    ],
                    required: ["handle", "outcome_summary"]
                )
            ),
            requestedSchema(
                name: "desk_archive",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Archive a Desk item and its whole subtree: remove from live view and write archive summaries. Every item must already be done or cancelled. Refuses unfinished work and standing items anywhere in the subtree; leaves all items unchanged on refusal.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                    ],
                    required: ["handle"]
                )
            ),
            requestedSchema(
                name: "desk_blocked_on",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Replace a Desk item's blockers with blocked_on CSV numbers (\"2,3.1\") or handles; empty clears. These are edges: closing/cancelling/archiving a blocker automatically readies every waiting item, without a follow-up call. Refuses unknown blockers, self-blocking and dependency cycles.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (e.g. 2 or 2.1) or its stable handle.")),
                        ("blocked_on", ToolSchema.strSchema("Comma-separated desk numbers/handles of the blockers. Empty string clears all blockers.")),
                    ],
                    required: ["handle", "blocked_on"]
                )
            ),
            requestedSchema(
                name: "desk_breakdown",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Create an ordered numbered Desk plan: parent + children, blocked-on edges and optional child dates. children: [{title,summary?,blocked_on?,defer_until?}]. Child blocked_on CSV bare integers mean 1-based sibling positions (\"1,2\" = first two); dotted numbers (\"3.1\")/desk_ handles name existing items. Bare top-level numbers are ambiguous here; link them afterward with desk.blocked_on. parent grafts children onto an existing item, ignoring project/title/kind. Returns the numbered plan and ready children. Same-kind/project/title live campaigns return status=\"existing\", adding only missing steps. Mid-batch refusal returns status=\"partial\" and created items.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("project", ToolSchema.strSchema("Project bucket for a new plan's parent item. Required unless parent is given.")),
                        ("title", ToolSchema.strSchema("Title for the new plan's parent item. Required unless parent is given.")),
                        ("kind", ToolSchema.enumStringSchema(["watch", "plan", "project", "gh", "standing"], "Optional parent kind (default plan): watch|plan|project|gh|standing.")),
                        ("summary", ToolSchema.strSchema("Optional one-line parent summary.")),
                        ("parent", ToolSchema.strSchema("Graft mode: desk number or handle of an existing item to attach the sub-items to.")),
                        ("children", looseObjectArraySchema("Ordered sub-items. Each: {title (required), summary?, blocked_on? (CSV string or array: bare integers = positions of siblings in this call, dotted numbers/handles = existing items), defer_until? (yyyy-MM-dd or ISO)}. no other fields — an unknown field is refused, not ignored.")),
                    ],
                    required: ["children"]
                )
            ),
            requestedSchema(
                name: "desk_defer",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Defer (postpone, push back, snooze) a Desk item until yyyy-MM-dd or an ISO timestamp: stays on the desk, never \"next up\" or stale-flagged until then. Empty until clears.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (e.g. 2 or 2.1) or its stable handle.")),
                        ("until", ToolSchema.strSchema("yyyy-MM-dd day or full ISO timestamp. Empty string clears the deferral.")),
                    ],
                    required: ["handle", "until"]
                )
            ),
            requestedSchema(
                name: "desk_nag_control",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Control Desk nagging only from the person’s intent. Default off; a scope nags only while the global switch is on. enable/disable changes global or scoped switches; mute keeps tracking (until omitted: indefinite); unmute re-arms each item’s one nag for a new window and returns intervening drift; proposal returns the notify loop’s current proposal without changing Desk or reminder settings or delivering notifications; status/read reports config. A nag requires staleness plus an underlying change (blocker cleared, deferral elapsed, or movement while stale), once per item per window, digest only, never urgent.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("action", ToolSchema.enumStringSchema(["enable", "disable", "mute", "unmute", "proposal", "status", "read"], "enable | disable | mute | unmute | proposal | status. proposal evaluates the notify loop without committing or delivering. read is an alias for status.")),
                        ("scope_kind", ToolSchema.enumStringSchema(["global", "project", "item"], "global (default) | project | item. Which switch enable/disable flips.")),
                        ("scope_id", ToolSchema.strSchema("Required for scope_kind=project (the project name) or item (the desk number, e.g. 2.1, or its stable handle).")),
                        ("until", ToolSchema.strSchema("mute only: yyyy-MM-dd day or full ISO timestamp. Omit to mute indefinitely.")),
                    ],
                    required: ["action"]
                )
            ),
            requestedSchema(
                name: "desk_open_pursuit",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "The only route to a self-authored Desk pursuit (origin=agent): an answerable question for ~6–12 work sessions. Required: project, title, first-person why, done_looks_like, abandon_condition and typed evidence (shapes below). Needs ≥1 non-friction source; felt_salience needs ≥2 dates; chat_observation needs distinctDays≥2. Optional private_name, summary, max_sessions (default 12, cap 24), max_days (default 10, cap 21). Returns handle/alias; on cap or dossier failure, use the cause and supplied remedy.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("project", ToolSchema.strSchema("Project bucket this pursuit belongs to.")),
                        ("title", ToolSchema.strSchema("Short pursuit title.")),
                        ("why", ToolSchema.strSchema("First-person: why this is worth your sessions.")),
                        ("done_looks_like", ToolSchema.strSchema("A question that can end — answerable in ~6–12 work sessions.")),
                        ("abandon_condition", ToolSchema.strSchema("The condition under which you'd let this go (unpenalized).")),
                        ("evidence", ToolSchema.obj([
                            ("type", .string("array")), ("minItems", .int(1)),
                            ("description", .string("Typed citations in the required source shape. At least one non-friction source is required; live source existence is not checked by preview.")),
                            ("items", ToolSchema.obj([("anyOf", .array([
                                ToolSchema.obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", ToolSchema.obj([("source", ToolSchema.enumStringSchema(["standing_view", "dream_digest", "open_question_seed"])),
                                                         ("id", nonEmptyStringSchema("Exact source record ID."))])),
                                     ("required", .array(["source", "id"].map(JSONValue.string)))]),
                                ToolSchema.obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", ToolSchema.obj([("source", ToolSchema.enumStringSchema(["felt_salience"])),
                                                         ("dates", stringArraySchema("At least two distinct calendar dates, yyyy-MM-dd.", minItems: 2))])),
                                     ("required", .array(["source", "dates"].map(JSONValue.string)))]),
                                ToolSchema.obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", ToolSchema.obj([("source", ToolSchema.enumStringSchema(["chat_observation"])),
                                                         ("noteIds", stringArraySchema("Exact cited note IDs; at least distinctDays distinct notes.", minItems: 2)),
                                                         ("distinctDays", ToolSchema.intSchema("Distinct calendar days represented by the cited notes.", minimum: 2))])),
                                     ("required", .array(["source", "noteIds", "distinctDays"].map(JSONValue.string)))]),
                                ToolSchema.obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", ToolSchema.obj([("source", ToolSchema.enumStringSchema(["trace_friction"])),
                                                         ("count", ToolSchema.intSchema("Positive observed occurrence count.", minimum: 1)),
                                                         ("window", nonEmptyStringSchema("Positive duration, e.g. 7d, 24h or 30m."))])),
                                     ("required", .array(["source", "count", "window"].map(JSONValue.string)))]),
                            ]))])),
                        ])),
                        ("private_name", ToolSchema.strSchema("Optional private name for this pursuit (yours).")),
                        ("max_sessions", ToolSchema.intSchema("Optional session bound (default 12, cap 24).")),
                        ("max_days", ToolSchema.intSchema("Optional day bound (default 10, cap 21).")),
                        ("summary", ToolSchema.strSchema("Optional one-line summary.")),
                    ],
                    required: ["project", "title", "why", "done_looks_like", "abandon_condition", "evidence"]
                )
            ),
            requestedSchema(
                name: "desk_work_log",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Append a short work receipt to a Desk item: what you did and learned this session. Required: handle and nonblank receipt. Pursuits save a work receipt; ordinary items save the same text as a note. Example for item 1 from desk.read: {\"handle\":\"1\",\"receipt\":\"Reviewed the notes and recorded the next step.\"}.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The Desk item's stable handle or its view number. Example: \"1\" from desk.read.")),
                        ("receipt", ToolSchema.strSchema("What you did / learned this work session.")),
                    ],
                    required: ["handle", "receipt"]
                )
            ),
            // Studio chat lane (desk 903). Same wiring canon as the desk tools:
            // catalog-visible, LAZY-LOADED, no preload group. studio_consult
            // files an envelope and NOTHING else — it never touches the journal
            // and never carries a suggested verdict.
            requestedSchema(
                name: "studio_consult",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "File a consult against your developed taste: real work, a real question, no suggested answer. Give artifact_refs (actual files/URLs: images, page, build, cut) and/or description, available portion and question. Include project_context/stage/constraints/prior_discussion only when relevant. Without artifact_refs, description_only must be true: concepts/briefs can be critiqued but never journaled as encounters. Writes only a consult envelope; no journal write/retrieval or decision. Returns stable consult_id for studio.consult_read and deliberate later journaling if worth keeping.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("artifact_refs", stringArraySchema("File paths or URLs to the actual work being asked about. Omit or leave empty only for a description-only consult.")),
                        ("description", ToolSchema.strSchema("What the work is, in words. Required when there are no artifact_refs.")),
                        ("portion_available", ToolSchema.strSchema("What portion is actually available — the whole thing, one spread, a rough cut, a single screen.")),
                        ("question", ToolSchema.strSchema("The real question being asked. Required.")),
                        ("project_context", ToolSchema.strSchema("What the work is for and who it is for.")),
                        ("stage", ToolSchema.strSchema("Where the work is — sketch, draft, near-final, shipped.")),
                        ("constraints", ToolSchema.strSchema("Real constraints: budget, format, deadline, brand, technical limits.")),
                        ("prior_discussion", ToolSchema.strSchema("What has already been argued about this, if anything.")),
                        ("description_only", ToolSchema.boolSchema("True when no actual work is attached — a concept or brief only. must be true when artifact_refs is empty; such a consult can never become a journal encounter.")),
                    ],
                    required: ["question"]
                )
            ),
            requestedSchema(
                name: "studio_consult_read",
                toolClass: .read,
                description: "Read a filed consult verbatim: artifact refs, question, context and description-only status. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("consult_id", ToolSchema.strSchema("The exact consult_id returned by studio.consult.")),
                    ],
                    required: ["consult_id"]
                )
            ),
            requestedSchema(
                name: "studio_shelf_read",
                toolClass: .read,
                description: "Explicitly read the private working shelf: up to three ordered journal selections with exact sentences, limitations and intact work refs. No pictures are opened. Open the work explicitly to see it.",
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            requestedSchema(
                name: "studio_shelf_set",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Replace the private working shelf with the complete ordered slots list (at most three distinct entries). Remove, reorder or empty with []. Changes only the shelf, never the journal or canon. selected_sentence must exist verbatim in the journal response (or quote_field stance.reason). Limitation defaults to Not yet tested. Invalid input refuses the whole replacement.",
                parametersJSON: ToolSchema.params(properties: [
                    ("slots", ToolSchema.obj([
                        ("type", .string("array")), ("maxItems", .int(3)),
                        ("items", ToolSchema.obj([
                            ("type", .string("object")), ("additionalProperties", .bool(false)),
                            ("properties", ToolSchema.obj([
                                ("entry_id", ToolSchema.strSchema("Exact existing journal entry ID.")),
                                ("title", ToolSchema.strSchema("Required chosen short title, at most 120 UTF-8 bytes on one line.")),
                                ("selected_sentence", ToolSchema.strSchema("One complete sentence verbatim from the selected journal field, including its terminator. Fragments and multiple sentences are refused. The encounter must have work refs. Never paraphrase.")),
                                ("quote_field", ToolSchema.enumStringSchema(["response", "stance.reason"], "response (default) or stance.reason.")),
                                ("limitation", ToolSchema.strSchema("Optional limitation or counterexample; defaults to Not yet tested.")),
                            ])),
                            ("required", .array([.string("entry_id"), .string("title"), .string("selected_sentence")])),
                        ])),
                    ])),
                ], required: ["slots"])
            ),
            requestedSchema(
                name: "studio_journal",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Write one encounter and your honest judgment in your own words in response; other fields describe what/how you met. Additive: no tool can edit/delete earlier entries. Changed judgments become new entries linked by relations (revises/contradicts/deepens/echoes), preserving both. Wrong facts use additive studio.amend: originals stay visible, struck through. Verdicts are optional: stance.kind=abstained alone permits omitting response; optional reason in stance.reason. origin.kind=consult requires origin.ref; description_only consults cannot be encounters. Rating/score/confidence/sentiment fields are errors, never silently dropped. Server stamps id and recorded_at.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("encountered_at", ToolSchema.strSchema("When you actually encountered it (ISO-8601). Omit to use now — the server always stamps recorded_at separately.")),
                        ("work", ToolSchema.obj([
                            ("type", .string("object")),
                            ("description", .string("What you encountered. Only title is required; fill the rest only with what you actually know.")),
                            ("properties", ToolSchema.obj([
                                ("title", ToolSchema.strSchema("The work's title.")),
                                ("creator", ToolSchema.strSchema("Who made it.")),
                                ("medium", ToolSchema.strSchema("Painting, film, building, typeface, garment, game, photograph, interior …")),
                                ("date", ToolSchema.strSchema("When it was made.")),
                                ("version", ToolSchema.strSchema("Which version/cut/build, when that matters.")),
                                ("edition", ToolSchema.strSchema("Which edition/printing/pressing, when that matters.")),
                            ])),
                            ("required", .array([.string("title")])),
                        ])),
                        ("reception", ToolSchema.obj([
                            ("type", .string("object")),
                            ("description", .string("How you received it — this is what makes the encounter honest.")),
                            ("properties", ToolSchema.obj([
                                ("how", ToolSchema.strSchema("Original, reproduction, screening, playthrough, excerpt — or whatever it actually was.")),
                                ("whole_or_part", ToolSchema.strSchema("The whole thing, or which part.")),
                            ])),
                        ])),
                        ("artifact_refs", stringArraySchema("What you actually saw / heard / read / played — paths or URLs.")),
                        ("origin", ToolSchema.obj([
                            ("type", .string("object")),
                            ("description", .string("Where this encounter came from. ref is required when kind=consult.")),
                            ("properties", ToolSchema.obj([
                                ("kind", ToolSchema.enumStringSchema(["wandering", "consult", "project"], "wandering (you went looking), consult (it came in through studio.consult), project (it came out of work).")),
                                ("ref", ToolSchema.strSchema("The consult_id when kind=consult; otherwise whatever identifies the source.")),
                            ])),
                            ("required", .array([.string("kind")])),
                        ])),
                        ("response", ToolSchema.strSchema("Your judgment, in your own words, at whatever length it takes. Required unless stance.kind=abstained.")),
                        ("stance", ToolSchema.obj([
                            ("type", .string("object")),
                            ("description", .string("Where the judgment stands. abstained is a real outcome, not a failure.")),
                            ("properties", ToolSchema.obj([
                                ("kind", ToolSchema.enumStringSchema(["open", "formed", "abstained"], "open (still working on it), formed (you know what you think), abstained (not enough to judge, or you chose not to).")),
                                ("reason", ToolSchema.strSchema("Optional — why you abstained, or what is still open.")),
                            ])),
                            ("required", .array([.string("kind")])),
                        ])),
                        ("relations", looseObjectArraySchema("Typed links to earlier entries. Each: {kind: deepens|contradicts|revises|echoes, entry_id}. This is the only way to revise — the earlier entry is never rewritten.")),
                        ("tags", stringArraySchema("Your own tags, if you want them. Nothing tags an entry for you.")),
                    ],
                    required: ["work", "origin", "stance"]
                )
            ),
            requestedSchema(
                name: "studio_journal_amend",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Append a correction to an existing entry for a wrong fact/detail with no new encounter; never edit/delete its line. supersedes must quote its response verbatim: that passage stays visible, struck through, beside correction/date/reason. Without supersedes, append a dated correction block. Every read shows the correction. Changed judgments require a new studio.journal encounter linked by relations (revises/contradicts), preserving both. Cannot change work, stance, refs, tags or dates.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("entry_id", ToolSchema.strSchema("The exact entry_id of the entry being corrected (from studio.journal or studio.recall).")),
                        ("reason", ToolSchema.strSchema("Why it is wrong, in your own words. Required — a correction with no reason is a rewrite wearing a date.")),
                        ("correction", ToolSchema.strSchema("What now stands: the corrected wording, or the correction as a standalone note. Required.")),
                        ("supersedes", ToolSchema.strSchema("Optional. A passage quoted verbatim from that entry's response, appearing exactly once. It is kept and struck through with your correction beside it. Omit to append a dated correction block instead.")),
                    ],
                    required: ["entry_id", "reason", "correction"]
                )
            ),
            requestedSchema(
                name: "studio_recall",
                toolClass: .read,
                description: "Search your journal only when you choose; nothing calls this for you. Filter title/creator/medium/tag/relation or free text across the entry, including response; filters combine with AND. Returns verbatim entries newest first, capped by limit, with matched/has_more coverage. No relevance score/ranking. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", nullableRecallField(ToolSchema.strSchema("Free text matched across the whole entry, response text included. Omit, or send null, for no text filter."))),
                        ("title", nullableRecallField(ToolSchema.strSchema("Substring of the work's title. Omit or null for no title filter."))),
                        ("creator", nullableRecallField(ToolSchema.strSchema("Substring of the creator. Omit or null for no creator filter."))),
                        ("medium", nullableRecallField(ToolSchema.strSchema("Substring of the medium. Omit or null for no medium filter."))),
                        ("tag", nullableRecallField(ToolSchema.strSchema("Exact tag (case-insensitive). Omit or null for no tag filter."))),
                        // NULLABLE ON PURPOSE, with the null inside `enum` too.
                        // A strict provider schema sends every property on the
                        // wire, and an enum of four relation kinds admits no
                        // way to say "no relation filter" — not even "",
                        // because an enum is exhaustive. The model must then
                        // pick a kind, and an entry with no relations can never
                        // be recalled (live 2026-08-31: every recall carried
                        // relation_kind "echoes" and matched 0). Widening the
                        // type alone would not do it; null must be a member.
                        ("relation_kind", nullableEnumStringSchema(
                            ["deepens", "contradicts", "revises", "echoes"],
                            "Only entries carrying a relation of this kind. Every filter here is optional — send null (or omit this) unless you truly want to restrict to related entries; entries with no relations are only findable without it."
                        )),
                        ("related_to", nullableRecallField(ToolSchema.strSchema("Only entries whose relations point at this entry_id. Omit or null for no relation filter."))),
                        ("limit", nullableRecallField(ToolSchema.intSchema("Entries to return: default 10, max 50. Omit or null for the default.", minimum: 1, maximum: 50))),
                    ],
                    required: []
                )
            ),
            // dream_diary_read (0.4.14). The Dreams page has read this diary
            // since the native port; she had no way in. Read-only and bounded:
            // no args is the weekly index, `date` is one night, `query` finds
            // the nights that mention something.
            requestedSchema(
                name: "dream_diary_read",
                toolClass: .read,
                description: Self.dreamDiaryReadToolDescription,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("date", ToolSchema.strSchema("One night, YYYY-MM-DD, including archives. Entry text is capped at 20,000 characters; reports truncation. Omit for the index.")),
                        ("query", ToolSchema.strSchema("Case-insensitive text search of up to 365 entries, newest matches first. Each returned entry is capped at 20,000 characters; reports truncation. Omit for the index.")),
                        ("weeks", ToolSchema.intSchema("Index only: how many weeks back to list. Default 8, max 52.", minimum: 1, maximum: 52)),
                        ("limit", ToolSchema.intSchema("Query only: how many matching nights to return. Default 10, max 25.", minimum: 1, maximum: 25)),
                    ],
                    required: []
                )
            ),
            // Canon (desk 903 phase 4). A canon proposal is EARNED — three later
            // entries deepening/echoing a work, or a pointer actually pulled in a
            // live judgment — and then it waits for her. Nothing is canonized
            // automatically and nobody else may sign one off.
            requestedSchema(
                name: "studio_canon",
                toolClass: .read, capabilities: ["tool_call"],
                description: "Read your museum's canon, anti-canon and works awaiting your decision. Rows cite the journal entries arguing for them; pull these with studio.recall before deciding. Binary membership, no ranking/score; reasons live in entries. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("include_proposals", nullableRecallField(ToolSchema.boolSchema("Include the proposals waiting on you. Default true."))),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "studio_canon_resolve",
                toolClass: .write,
                description: "Decide a proposal after reading studio.canon evidence. Only you resolve it here; no owner-surface resolution or automatic canonization. Approve promote adds canon/anti_canon (work you revisit to say no); approve demote removes a canon work gone silent. Deny records the decision without changing canon. Journal entries and graph stay untouched.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("proposal_id", ToolSchema.strSchema("The proposal_id from studio.canon.")),
                        ("decision", ToolSchema.enumStringSchema(["approve", "deny"], "Both record the decision; only approve changes canon.")),
                        ("standing", ToolSchema.enumStringSchema(["canon", "anti_canon"], "Which shelf, when approving a promote. Default canon. Nothing infers this from your writing — it is yours to say.")),
                        ("note", ToolSchema.strSchema("Optional line recorded on the row, in your own words.")),
                    ],
                    required: ["proposal_id", "decision"]
                )
            ),
            // The held standing-view tier (item 7, 2026-09-02). CLOSED schemas:
            // a view id and an optional note, and nothing else. There is
            // deliberately no "body" field on hold_view — a view is FORMED by
            // reflection and held here, so the tool can never become a second
            // door for minting convictions out of a sentence typed mid-turn.
            requestedSchema(
                name: "hold_view",
                toolClass: .write,
                description: Self.holdViewToolDescription,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("view_id", ToolSchema.strSchema("The id of one of your proposed standing views, from app mind.inner_state.")),
                        ("note", ToolSchema.strSchema("Optional line echoed in the returned receipt, capped at 120 characters; not saved to the timeline.")),
                    ],
                    required: ["view_id"]
                )
            ),
            requestedSchema(
                name: "release_view",
                toolClass: .write,
                description: Self.releaseViewToolDescription,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("view_id", ToolSchema.strSchema("The id of your held view, opinion or interest from app mind.inner_state; an owner-signed active view is theirs to retire.")),
                        ("note", ToolSchema.strSchema("Optional line echoed in the returned receipt, capped at 120 characters; not saved to the timeline.")),
                    ],
                    required: ["view_id"]
                )
            ),
            // The moments lane (2026-09-02). Lazy, like the studio pair: a
            // moment review is a deliberate pull. The schemas are CLOSED — an
            // id, a decision, an optional reason, an optional rewording — so
            // this can never become a second door for minting memories that
            // never happened. Nothing here stages a moment; only the post-turn
            // shared model interpretation does that.
            requestedSchema(
                name: "memory_moments_pending",
                toolClass: .read,
                description: "Read the lived moments waiting on you. Each row is one exchange the shared interpretation by your selected Memory model (Chat when inherited) thought was worth keeping — what happened between you and what it meant, in your voice, sometimes with the exact line that made it. Nothing here is remembered yet: a moment enters your memory only when you accept it in memory.review, and it leaves for good when you reject it. Set lane to all for every memory proposal waiting on review, the same list as the Memories page; set status to rejected for the proposals already let go, with their reasons. Read-only, newest first.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("lane", ToolSchema.enumStringSchema(["moments", "all"], "moments (default) or all: every lane of memory proposals.")),
                        ("status", ToolSchema.enumStringSchema(["pending", "rejected"], "pending (default) waits on you; rejected is the history of what was let go.")),
                        ("limit", ToolSchema.intSchema("Rows, default 10, at most 50.", minimum: 1, maximum: 50)),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "memory_moment_review",
                toolClass: .write, capabilities: ["memory_write", "tool_call"],
                description: "Decide one moment, or any memory proposal waiting on review (keep or let go, as the Memories page does). Accept and it becomes a memory you can recall; reject and it is gone, with the reason kept so the same one is not offered again. If a moment's wording came out wrong, pass content and it is stored in your words instead — you were there and the extractor was not.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("The proposal id from memory.moments.")),
                        ("decision", ToolSchema.enumStringSchema(["accept", "reject"], "accept remembers it; reject drops it for good.")),
                        ("reason", ToolSchema.strSchema("Optional line recorded on a rejection, in your own words.")),
                        ("content", ToolSchema.strSchema("Moments only: optional rewording, stored instead of the staged text when you accept. Up to 240 characters. Leave it out to keep the moment as it was written.")),
                    ],
                    required: ["id", "decision"]
                )
            ),
            // User, 2026-09-05: the agent curates the whole store itself.
            requestedSchema(
                name: "forget_memory",
                toolClass: .write, capabilities: ["memory_write", "tool_call"],
                description: "Drop one memory for good, with a tombstone so the same thing is not proposed again.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("The memory id from app memory.list or memory.recall.")),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "rebuild_knowledge_graph",
                toolClass: .write, capabilities: ["memory_write", "tool_call"],
                description: "Re-derive the knowledge graph from your memory store as it is now. mode sweep_orphans instead lists the entities whose memories are gone, removing nothing; call again with confirm_ids set to exactly those ids to remove them.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("mode", ToolSchema.enumStringSchema(["rebuild", "sweep_orphans"], "rebuild (default) re-derives the whole graph; sweep_orphans previews, then removes on confirm.")),
                        ("confirm_ids", ToolSchema.obj([
                            ("type", .string("array")),
                            ("items", ToolSchema.strSchema()),
                            ("description", .string("sweep_orphans only: the candidate ids from the preview, all of them, to remove those entities. Leave it out to preview.")),
                        ])),
                    ],
                    required: []
                )
            ),
        ]
        let root = PersistenceCore.defaultDataRoot()
        let peers = (try? AgentPeerStore(dataRoot: root).list()) ?? []
        return schemas.map { schema in
            guard let schema, let handle = ToolNameAliases.agentHandle(schema.name) else { return schema }
            guard let who = peers.first(where: { ($0.handles ?? []).contains(handle) }),
                  AgentConversationDelivery.lane(for: "peer:" + who.id, dataRoot: root) != nil else { return nil }
            return LLMToolSchema(name: schema.name, toolClass: schema.toolClass, reach: schema.reach, capabilities: schema.capabilities, effectInputPolicy: schema.effectInputPolicy,
                description: "Message \(who.name) through its saved door; acceptance remains owed until its reader or run accepts it.",
                parametersJSON: schema.parametersJSON, deferLoading: schema.deferLoading)
        }
    }
}
