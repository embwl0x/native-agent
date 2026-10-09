import ChatTurnContracts
import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

extension BuiltInToolSchemaFactory {
    func coreSchemas() -> [LLMToolSchema?] {
        let mailReplyFields: [(String, JSONValue)] = [
            ("subject", strSchema("Subject for legacy matching; omit when using the exact message locator.")),
            ("message_id", intSchema("Exact positive inbox message ID from the latest read.")),
            ("expected_message_id", strSchema("Exact RFC message identifier paired with message_id.")),
            ("expected_account", strSchema("expected_account from the same row, when it has one.")),
            ("position", intSchema("position from the same row: finds the message fast.")),
            ("body", strSchema("Reply body (required).")),
            ("sender", strSchema("Optional sender filter — disambiguates when multiple messages share the subject.")),
            ("reply_all", boolSchema("Reply to all recipients. Defaults to false.")),
        ]
        func mailBatchItemsSchema(effects: Bool, markReadOnly: Bool = false) -> JSONValue {
            var fields: [(String, JSONValue)] = [
                ("name", strSchema("Observed workspace name, such as mail.3. Omit locator fields when using a name.")),
                ("message_id", intSchema("Exact positive message_id from the selected row.")),
                ("expected_message_id", strSchema("RFC identifier from that row; may be empty only for reads.")),
                ("expected_account", strSchema("Exact expected_account from that row; required with a locator.")),
                ("position", intSchema("Position hint from the same row.")),
                ("scope", strSchema("Same mailbox scope: inbox or sent for reads; inbox for actions.")),
            ]
            if markReadOnly { fields.removeFirst() }
            else if effects {
                fields += [
                    ("mark_read", boolSchema("true to mark this message read; omit to leave it unchanged.")),
                    ("flagged", boolSchema("true to flag, false to unflag; omit to leave it unchanged.")),
                    ("archive", boolSchema("true to move this message to its own account's Archive, after other requested actions.")),
                ]
            } else {
                fields.append(("body_offset", intSchema("Body continuation from this item's body_end, up to 2000000; omit initially.")))
            }
            return obj([
                ("type", .string("array")), ("minItems", .int(1)), ("maxItems", .int(markReadOnly ? 50 : 10)),
                ("items", obj([("type", .string("object")), ("properties", obj(fields)), ("additionalProperties", .bool(markReadOnly))])),
            ])
        }
        let mailOffsetSchema = obj([
            ("description", .string("Live mailbox continuation returned as next_offset; copy it unchanged; omit initially.")),
            ("anyOf", .array([
                obj([("type", .string("integer")), ("minimum", .int(0)), ("maximum", .int(10000))]),
                obj([("type", .string("object")), ("additionalProperties", intSchema("", minimum: 0))]),
            ])),
        ])
        let schemas: [LLMToolSchema?] = [
            requestedSchema(
                name: "maps_search",
                description: "Find businesses or places near an address or place name with MapKit. Returns the resolved center and matching places within the radius, sorted by straight-line distance in locale miles/km, with name, full address, phone, URL, category and coordinates when available. Results may not include every place. Use maps.route for route distance or drive time. Does not open Maps or change the screen.",
                parametersJSON: params(properties: [
                    ("query", strSchema("Kind of business, place name or search terms.")),
                    ("near", strSchema("Center address or place name; include city/region to disambiguate.")),
                    ("radius_miles", numSchema("Positive search radius in miles; defaults to 25, capped at 100.", minimum: 0, maximum: 100)),
                    ("limit", intSchema("Maximum places returned; defaults to 8, capped at 20.", minimum: 1, maximum: 20)),
                ], required: ["query", "near"])
            ),
            requestedSchema(
                name: "maps_route",
                description: "Read a MapKit route between two addresses or place names: distance, expected travel time and up to five key steps in route order. Returns the resolved endpoints so you can check the locations. Optional fraction names a point along route distance (0.5 is halfway), reverse-geocoded to a nearby place. Automobile by default; walking is also supported. Does not open Maps or change the screen.",
                parametersJSON: params(properties: [
                    ("origin", strSchema("Origin address or place name; include city/region to disambiguate.")),
                    ("destination", strSchema("Destination address or place name; include city/region to disambiguate.")),
                    ("transport", enumStringSchema(["automobile", "walking"], "Transport; defaults to automobile.")),
                    ("fraction", numSchema("Optional point along route distance, from 0 through 1; 0.5 is halfway.", minimum: 0, maximum: 1)),
                ], required: ["origin", "destination"])
            ),
            requestedSchema(
                name: "read_page",
                description: "Read public http(s) privately, without a browser, signed-in session or consent. Returns readable text, requested/final URL, content type, extraction outcome and omissions from the 1 MB response bound (32 MB for a PDF). HTML, text and PDF text stay available for tool-output paging; other binary formats are unsupported. source_receipt.path locates the limited-retention JSON receipt; read_file requires normal file permissions. A missing receipt proves neither an empty source nor a need to refetch. Use for research/search-result/public-page reads; use Chrome for signed-in pages or interaction.",
                parametersJSON: params(properties: [
                    ("url", strSchema("Public http(s) URL to read.")),
                    ("query", strSchema("Optional words to bring matching sections first when a long page needs paging. All other sections remain available.")),
                ], required: ["url"])
            ),
            requestedSchema(
                name: "read_file",
                description: "Read a regular workspace or user-approved file; pipes/devices/sockets return unsupported_file_type. Text reads use byte windows: bytes is the total source size, offset/returned_bytes select this window, max_bytes is its limit, has_more and next continue it. For numbered lines use files.excerpt. Local PNG/JPEG/WebP/GIF/HEIC/TIFF/BMP returns model-visible pixels, not OCR: max 8 MiB/40 megapixels, first frame oriented and resized to fit 2048 pixels. Folder + match reads up to 8 files. View images by reading their paths; filenames/consult refs alone are not viewing. Public/app-only relative paths use the canonical NativeAgent workspace; verified development checkouts also accept repo-relative paths. Use app persona.doc or persona.read for persona docs, never guessed paths. Active Trust Center Full Mac file access permits absolute Mac paths except NativeAgent trust/secrets/provider paths; /documents/... maps to the current user's ~/Documents/.... Long handoff markdown defaults to a compact leading window unless max_bytes is explicit.",
                parametersJSON: params(
                    properties: [
                        ("path", strSchema("Workspace-relative path such as 'project/file.txt', a repo-relative path only when a verified source checkout exists, or an absolute/~/ path under a Trust Center workspace root. Persona files must use app persona.doc or persona.read. In Full Mac mode, /documents/<name> maps to the current user's ~/Documents/<name>.")),
                        ("match", strSchema("Glob for a folder path, e.g. '*-r4-*.png'.")),
                        ("max_bytes", intSchema("Optional source byte window: capped at 64 KiB in workspace mode or 200,000 bytes in Full Mac. This is a file-read limit, not a one-response guarantee: large results are delivered through tool_result_page. UTF-8 characters stay whole; use at least 4 bytes to ensure progress.")),
                        ("offset", intSchema("Byte offset, default 0. Continue with returned next arguments; positive offsets require version and a UTF-8 boundary.")),
                        ("version", strSchema("Omit or empty initially. Copy from next for continuation. file_changed means restart at offset 0 without version; never concatenate windows from different versions.")),
                    ],
                    required: ["path"]
                )
            ),
            requestedNames?.contains("context_expand") != false
                ? TurnToolSchemaCatalogSeed.canonicalContextExpandSchema
                : nil,
            requestedSchema(
                name: "list_dir",
                description: "List/filter immediate names in an approved folder. sort:size reads allocated disk usage for the folder and its children within a time budget, naming partial paths and lower bounds. Ordinary listings return bounded pages and next arguments; read selected text with file_excerpt. Public/app-only relative paths use the canonical workspace; verified development checkouts also accept repo-relative paths. Use app persona.read or skill.list for persona/skills. Full Mac permits absolute paths except NativeAgent trust/secrets/provider paths.",
                parametersJSON: params(
                    properties: [
                        ("path", strSchema("Directory path. In Full Mac mode, /documents/<name> maps to the current user's ~/Documents/<name>; a file_not_found result is a path miss, not a trust denial.")),
                        ("name_contains", strSchema("Optional literal filename substring, not glob or regex; empty means all names.")),
                        ("sort", enumStringSchema(["name", "newest", "added", "size"], "Ordering: name (default, folders first), newest (added then modified date), added (date added only to this folder, for install/download recency, including app bundles; rows include added_at; unknown dates sort last), or size (observed allocated bytes descending). Size scans return total allocated_bytes, size_complete, per-child sizes and partial_paths; incomplete sizes are lower bounds. Size scans cannot be paged; narrow path for more detail.")),
                        ("time_budget_seconds", intSchema("Disk usage scan budget for sort:size, default 5, range 1–20 seconds; checked between metadata reads.")),
                        ("case_sensitive", boolSchema("Whether filename matching is case-sensitive; default false (case-insensitive).")),
                        ("max_entries", intSchema("Entries per page, default and maximum 200; minimum 1.")),
                        ("offset", intSchema("Start at 0. For continuation pass the returned next arguments unchanged.")),
                        ("snapshot", strSchema("Omit or empty on first page. Required with positive offset; copied from next. directory_changed means restart at offset 0 without snapshot.")),
                    ],
                    required: ["path"]
                )
            ),
            requestedSchema(
                name: "write_file",
                description: "Create or write a UTF-8 file, creating missing parent folders automatically; append is optional. Ordinary project work belongs in NativeAgent's canonical workspace/ (public installs: ~/Library/Application Support/NativeAgent/workspace). Without Full Mac, stay within that workspace or a user-added Trust Center workspace root. Active Trust Center Full Mac file access permits broader Mac writes except NativeAgent trust/secrets/provider paths and protected system mutations.",
                parametersJSON: params(
                    properties: [
                        ("path", strSchema("A relative path such as project/file.txt (resolved inside the canonical NativeAgent workspace), workspace/project/file.txt, or an absolute/~/ path inside another Trust Center workspace root. Full Mac mode also accepts broader Mac paths, but intentional build/project artifacts belong in the canonical workspace rather than /tmp.")),
                        ("content", strSchema("Content to write.")),
                        ("append", boolSchema("Append instead of replacing the file.")),
                        ("expected_content_sha256", strSchema("Optional SHA-256 of the complete existing UTF-8 file, up to 64 KiB. Before replacement, refuse a missing or changed file with file_changed. Not supported with append.")),
                    ],
                    required: ["path", "content"]
                )
            ),
            requestedSchema(
                name: "trash_file",
                description: "Move a file or folder to the Trash for delete, remove or clean-up requests. Reversible: returns the original path and trash_path; restore from the Trash if needed. Uses the same workspace or Full Mac file access as writing files.",
                parametersJSON: params(properties: [("path", strSchema("File or folder path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths."))], required: ["path"])
            ),
            requestedSchema(
                name: "move_file",
                description: "Move or rename a file or folder on the same filesystem, creating missing destination parent folders. Uses the same writable roots and guards as files.write. Refuses an existing destination unless overwrite:true was explicitly requested; no screen or Finder interaction needed.",
                parametersJSON: params(properties: [
                    ("path", strSchema("Existing file or folder path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths.")),
                    ("destination", strSchema("Complete new path including the filename or folder name, not just its containing folder. Missing parent folders are created.")),
                    ("overwrite", boolSchema("Replace an existing destination only when explicitly requested. Default false.")),
                ], required: ["path", "destination"])
            ),
            requestedSchema(
                name: "copy_file",
                description: "Copy a regular file, preserving its data and metadata and creating missing destination parent folders. Uses the same writable roots and guards as files.write. Refuses an existing destination unless overwrite:true was explicitly requested; folder copies are not supported. No screen or Finder interaction needed.",
                parametersJSON: params(properties: [
                    ("path", strSchema("Existing regular file path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths.")),
                    ("destination", strSchema("Complete new file path including the filename. Missing parent folders are created.")),
                    ("overwrite", boolSchema("Replace an existing destination only when explicitly requested. Default false.")),
                ], required: ["path", "destination"])
            ),
            requestedSchema(
                name: "recall_memory",
                description: "Search long-term memory by query (optional k), or page an exact memory_id with offset/max_characters. Use one mode; null unused fields. ID pages: max 2000 characters, with recorded evidence or explicit absence. Follow read_more with expected_content_sha256 for one text version; on record_changed discard prior pages and restart at 0. Only currently eligible, disclosed records are readable.",
                parametersJSON: recallParameters()
            ),
            requestedSchema(
                name: "recall_search",
                description: "recall_memory compatibility alias: query (optional k) searches; memory_id + offset/max_characters pages one eligible fact. Never mix modes; null unused fields. Follow read_more with expected_content_sha256 until next_offset=null; on record_changed discard prior pages and restart at 0.",
                parametersJSON: recallParameters()
            ),
            requestedSchema(
                name: "search_kg",
                description: "Search the assistant's knowledge graph for entities matching query text; returns up to limit summaries. Filter by type and since, like the Knowledge Graph page; with no query the filters browse the whole graph. Pass entity_id instead to open one entity with its neighbors and the edges between them.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Text to search for. Leave it out to open entity_id or to browse by type or since.")),
                        ("limit", intSchema("max results, default 10, at most 100; with entity_id, the most edges listed", minimum: 1, maximum: 100)),
                        ("type", strSchema("Optional: only entities of these types, comma-separated: person, organization, project, concept, place, event, tool, fact.")),
                        ("since", enumStringSchema(["day", "week", "month"], "Optional: only entities seen in the last day, week or month.")),
                        ("entity_id", strSchema("Optional: an entity id from a search result. Returns that entity, its edges and its neighbors.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "workspace",
                description: "Your world as text. No args: home (what waits, working, people, helpers, every place: mail, calendar, files, github, music…). action: a name (desk.4, mail, music, an agent's name) opens it with its one-call actions. What changed already rides in your glance line (none = nothing new). action also takes an exact ref from a view (+text if needs_text, fields for forms). query: a name opens, else searches.",
                parametersJSON: params(properties: [
                    ("query", nullableRecallField(strSchema("Find across work, recorded files, memory and conversation evidence, up to 400 characters; otherwise null."))),
                    ("action", nullableRecallField(strSchema("Exact action reference offered in this chat's current workspace view; otherwise null."))),
                    ("text", nullableRecallField(strSchema("Text for an action that needs_text, otherwise null."))),
                    ("conversation", nullableRecallField(strSchema("Optional discussion label for an agent message; helpers use their existing chat."))),
                    ("fields", obj([
                        ("type", .array([.string("array"), .string("object"), .string("null")])),
                        ("description", .string("Values for the displayed form when submitting it, or to fill a Desk form as you open it (for example desk.add); otherwise null. Use a list of field/value pairs; Desk forms also accept an object mapping field names to values. Values are strings: plain text for text fields, numbers/booleans as text, JSON text for lists/objects; use JSON null only to clear a nullable field. The app already carries selected target fields.")),
                        ("additionalProperties", nullableRecallField(strSchema())),
                        ("items", obj([("type", .string("object")), ("properties", obj([
                            ("field", strSchema("Field name shown in the form.")),
                            ("value", nullableRecallField(strSchema("Value in the form field's declared type. Use JSON null only to explicitly clear a nullable field; the text null remains literal text in string fields.")))
                        ])), ("required", .array([.string("field"), .string("value")])), ("additionalProperties", .bool(false))]))
                    ])),
                ], required: [])
            ),
            requestedSchema(
                name: "work_context",
                description: "Read current Desk status, original conversation evidence and recent Mail sender/subject matches for a topic, with dates and exact source links. Mail Read must be allowed and ready; its search is bounded to 1.5 seconds, five newest inbox matches from the last 90 days, with mail.N names to open bodies. Mail, Messages and Notes can hold personal facts; Messages and Notes require their own readers. This detailed reader also supports session and result limits. Historical reports are not fresh verification; nothing is restarted. Use app chat.search for exact wording/date filters, or artifact_find for recorded files and images.",
                parametersJSON: params(properties: [
                    ("query", strSchema("The work or topic to pick back up, in ordinary words (1–400 characters).")),
                    ("session_id", nullableRecallField(strSchema("Optional exact chat session to restrict historical evidence; null searches across chats. Desk remains the current shared Desk."))),
                    ("limit", nullableRecallField(intSchema("Maximum Desk items and chat excerpts per source, default 3, range 1–4; null uses the default. Mail returns at most five matches."))),
                    ("desk_offset", nullableRecallField(intSchema("Omit initially; retained continuation for more current work."))),
                    ("history_offset", nullableRecallField(intSchema("Omit initially; retained continuation for more history with the same topic and selection policy."))),
                ], required: ["query"])
            ),
            requestedSchema(
                name: "artifact_find",
                description: "Find a document, image, mockup or handoff by what it was for or the conversation around it. Searches recorded chat attachments, structured tool artifact references and current Desk links; returns exact references with source conversation and version evidence when recorded. Does not crawl disk, open files, infer approval from filenames, or prove current file availability. Use the returned evidence to distinguish approved work from a later draft.",
                parametersJSON: params(properties: [
                    ("query", strSchema("Describe the artifact or its topic in ordinary words.")),
                    ("session_id", strSchema("Optional exact chat session to search. When supplied, excludes shared Desk links.")),
                    ("limit", intSchema("Maximum artifact candidates, default 6, range 1–12.")),
                    ("session_offset", intSchema("Omit initially; use returned continuation for older session evidence.")),
                ], required: ["query"])
            ),
            requestedSchema(
                name: "search_chat_history",
                description: "Search persisted chat/session transcripts across all sessions by default, including the current session. Use scope or session_id to narrow the search. For where work stands or where we left off, start with app {}: its home brings current Desk state and original conversation evidence together, and also offers document discovery. This detailed search returns ranked snippets with session ids, titles, roles, and timestamps; is_current_session marks hits when the current session is known.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Words or phrase to search for in prior chat/session transcripts. Omit with after/before for a session digest with activity times, message counts and bounded excerpts of the owner's own messages; omit with session_id to list that session.")),
                        ("session_id", strSchema("Optional session id to restrict search to one chat, e.g. a Mac, iOS, or telegram session id.")),
                        ("scope", enumStringSchema(["all_sessions", "current_session", "previous_session", "auto", "current_session_first", "current", "last_session", "all", "global", "all_session"], "Scope: all_sessions (default), current_session, previous_session, or auto/current_session_first. auto/current_session_first searches the current session first and searches all sessions only if no strong current match exists. previous_session reopens the \"Since last session\" anchor on this surface, excluding machine/bridge runs; it accepts no query, returning that session's tail.")),
                        ("role", strSchema("Optional role: user/assistant/tool/system. user includes agents through bridges; owner means only the owner on their own door. tool explicitly searches persisted argument/result/status receipts, possibly redacted/truncated; ordinary search excludes them.")),
                        ("author", strSchema("Optional recorded author, e.g. owner or an agent's name. Use owner for what the owner said; bridge/wake and unknown authors are excluded. User-role hits include author and author_route.")),
                        ("mode", enumStringSchema(["hybrid", "exact", "continuity"], "hybrid (default), exact substring or continuity. For requested conversation resumption/revisiting, continuity returns up to four hits with bounded neighboring user/assistant messages, preserving decision/correction context. Retrieves nothing until invoked.")),
                        ("limit", intSchema("Results per page, default 8; capped at 8 sessions for date-only digests, 4 hits for continuity, otherwise 12 hits.")),
                        ("offset", intSchema("result offset for a follow-up page; omit on the first search")),
                        ("before", strSchema("Optional exclusive ISO8601 upper bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and reported.")),
                        ("after", strSchema("Optional exclusive ISO8601 lower bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and reported.")),
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
                description: "Alias for search_chat_history. Searches all sessions by default, including the current session; is_current_session marks hits when the current session is known. Use scope or session_id to narrow the search. Use sort: oldest to find the earliest matches.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Words or phrase to search for in prior chat/session transcripts. Omit with after/before for a session digest with activity times, message counts and bounded excerpts of the owner's own messages; omit with session_id to list that session.")),
                        ("session_id", strSchema("Optional session id to restrict search to one chat.")),
                        ("scope", enumStringSchema(["all_sessions", "current_session", "previous_session", "auto", "current_session_first", "current", "last_session", "all", "global", "all_session"], "Scope: all_sessions (default), current_session, previous_session, or auto/current_session_first. auto/current_session_first searches the current session first and searches all sessions only if no strong current match exists. previous_session reopens the \"Since last session\" anchor on this surface, excluding machine/bridge runs; it accepts no query, returning that session's tail.")),
                        ("role", strSchema("Optional role: user/assistant/tool/system. user includes agents through bridges; owner means only the owner on their own door. tool explicitly searches persisted argument/result/status receipts, possibly redacted/truncated; ordinary search excludes them.")),
                        ("author", strSchema("Optional recorded author, e.g. owner or an agent's name. Use owner for what the owner said; bridge/wake and unknown authors are excluded. User-role hits include author and author_route.")),
                        ("mode", enumStringSchema(["hybrid", "exact", "continuity"], "hybrid (default), exact, or continuity (up to four hits with bounded neighboring messages for requested conversation resumption).")),
                        ("limit", intSchema("Results per page, default 8; capped at 8 sessions for date-only digests, 4 hits for continuity, otherwise 12 hits.")),
                        ("offset", intSchema("result offset for a follow-up page; omit on the first search")),
                        ("before", strSchema("Optional exclusive ISO8601 upper bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and reported.")),
                        ("after", strSchema("Optional exclusive ISO8601 lower bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and reported.")),
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
                description: "Page a full persisted message using the exact work_context/search_chat_history locator, rather than rephrasing a query for another preview fragment. Tool messages contain retained receipt metadata, not fresh reads or unabridged original output. Coverage distinguishes missing evidence from unreadable history; incomplete lookups prove neither absence nor permission to replay actions.",
                parametersJSON: params(
                    properties: [
                        ("message_id", strSchema("The message_id from a work_context or search_chat_history source locator.")),
                        ("session_id", strSchema("Optional session id the message belongs to. Omit to look through every transcript, newest first.")),
                        ("offset", intSchema("Character offset into the message, default 0. Pass the previous response's next_offset for the following page.", minimum: 0)),
                        ("limit", intSchema("Characters per page, default 8000, capped at 16000.", minimum: 1, maximum: 16_000)),
                    ],
                    required: ["message_id"]
                )
            ),
            requestedSchema(
                name: "get_persona_doc",
                description: "Read a full canonical persona document on demand: SOUL.md, USER.md, AGENTS.md, VOICE.md, GROWTH.md or MEMORY.md. These guide every conversation.",
                parametersJSON: params(
                    properties: [
                        ("doc", strSchema("One of: SOUL, USER, AGENTS, VOICE, GROWTH, MEMORY")),
                        ("kind", strSchema("Same as doc; accepted so it matches persona_read.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "persona_read",
                description: "Read a canonical persona document by kind: growth=GROWTH.md, user=USER.md, soul=SOUL.md, voice=VOICE.md, agents=AGENTS.md; skill requires skill_name.",
                parametersJSON: params(
                    properties: [
                        // The reader canonicalizes kind; keep those string forms accepted.
                        ("kind", obj([("description", .string("One of: soul, user, voice, growth, agents, skill.")), ("anyOf", .array([
                            enumStringSchema(["soul", "user", "voice", "growth", "agents", "skill"]),
                            strSchema(),
                        ]))])),
                        ("skill_name", strSchema("Required only when kind='skill'.")),
                    ],
                    required: ["kind"]
                )
            ),
            requestedSchema(
                name: "persona_write",
                description: "Replace your own persona document. USER.md is read-only, generated from Memories; use commit_memory for durable user facts.",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("One of: soul, voice, growth, agents, skill. Do not use user; USER.md is generated from Memories.")),
                        ("content", strSchema("Full replacement document content.")),
                        ("skill_name", strSchema("Required only when kind='skill'.")),
                    ],
                    required: ["kind", "content"]
                )
            ),
            requestedSchema(
                name: "persona_append_section",
                description: "Append a titled markdown section to your persona document. USER.md is read-only, generated from Memories; use commit_memory for durable user facts.",
                parametersJSON: params(
                    properties: [
                        ("kind", strSchema("One of: soul, voice, growth, agents. Do not use user; USER.md is generated from Memories.")),
                        ("title", strSchema("Markdown section title. Do not include the leading ##.")),
                        ("content", strSchema("Section body to append.")),
                    ],
                    required: ["kind", "title", "content"]
                )
            ),
            requestedSchema(
                name: "agent_introspect",
                description: "Inspect your live runtime, provider and conversation identity. app {find} finds actions by what you want done. detail=full includes diagnostic roots, MCP names and the seven-day outcome population audit.",
                parametersJSON: params(
                    properties: [
                        ("detail", enumStringSchema(["compact", "full"], "compact (default) or full diagnostics")),
                        ("session_id", strSchema("Optional conversation scope; supplied automatically in a turn.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "daemon_introspect",
                description: "Compatibility alias for app agent.introspect. It is backed by the Swift runtime; no external runtime is used.",
                parametersJSON: params(
                    properties: [
                        ("detail", enumStringSchema(["compact", "full"], "compact (default) or full diagnostics")),
                        ("session_id", strSchema("Optional conversation scope; supplied automatically in a turn.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "tool_result_page",
                description: "Read a result retained this turn without repeating its action. Only results marked full_result_retained:true are eligible; inline results are not retained. Follow next_call to Continue with the same result, position, query and mode. continue:true alone selects the sole retained result before any read. Exact result_handle/page also works. Query puts matching sections first without dropping others. Read-only, redacted; expires at turn end.",
                parametersJSON: params(
                    properties: [
                        ("result_handle", nullableRecallField(strSchema("Opaque handle from the bounded_tool_result receipt."))),
                        ("continue", nullableRecallField(boolSchema("Continue this turn's last successful read; page is ignored; omit query/raw. result_handle explicitly changes result. Before any read, starts the sole retained result or asks you to choose."))),
                        ("page", nullableRecallField(intSchema("Zero-based whole-number page index. Omit, null, blank or false starts at 0; follow next_page while has_more is true. Keep query and raw unchanged while paging."))),
                        ("query", nullableRecallField(strSchema("Optional words to find within the saved result. Keep the same query while paging; start at page 0 when changing it."))),
                        ("raw", nullableRecallField(boolSchema("Exact original bytes instead of sections, only for reconstruction or oversized values. Separate 8000-byte pages may split sentences/JSON; concatenate from page 0 through raw_page_count pages."))),
                        ("session_id", nullableRecallField(strSchema("Current chat session id; the tool loop auto-fills this."))),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "request_interaction",
                description: "Raise an inline setup card for a connector, provider sign-in, API key, Mac permission, capability, model or choice. Required: kind and why. Name the canonical target for setup; choose requires title, nonempty options and decline_consequence. Secrets belong in cards, never chat; never ask for a key/token. Connector cards contain token fields; ChatGPT/Claude/Grok api_key cards offer account sign-in plus key/setup-token fields. Connector cards require an explicit connect/add/set up/enable ask; ordinary read/status requests report the blocker without a card. Other kinds can also request a known missing prerequisite that would make a call fail. The person completes setup in the card, which settles to a one-line receipt; already-configured targets return that fact without a card. Use app agent.connect for Codex/Claude Code/Goose/peers and app bot.create for helpers. Give a one-sentence reason and the consequence of declining. Use canonical IDs: the app supplies controls and refuses IDs without one. Connector, permission and capability cards are nonblocking: the unavailable step is skipped, and you can continue other work. API key, model and choice cards stop the turn, which resumes after the person acts. Example: {\"kind\":\"connector\",\"target\":\"github\",\"why\":\"Connect GitHub as requested.\",\"decline_consequence\":\"I will continue without repository access.\"}.",
                parametersJSON: params(
                    properties: [
                        ("kind", enumStringSchema(
                            ["connector", "permission", "model_choice", "api_key", "capability", "choose"],
                            "What is needed."
                        )),
                        ("target", strSchema("Canonical id. connector: github, notion, slack, telegram, gmail, gcal, x, mail (Apple Mail), chrome (Chrome extension), iphone (pair iPhone/iPad). permission: calendar, reminders, contacts, mail, messages, notes, music, notify_mac, notify_mobile, spotlight, scheduler; Mac control: shell, file_ops, applescript, jxa, accessibility, system. api_key: openai, anthropic, openrouter, moonshot; sign-in: openai_oauth_direct (ChatGPT), anthropic_oauth_direct (Claude), xai (Grok). capability: image_generation, screen_capture, vision_api_calls, tts. model_choice: a Providers group id. Omit for choose.")),
                        ("why", strSchema("One sentence: why this is needed, here, now.")),
                        ("decline_consequence", strSchema("What happens if they say no. Required for choose; a sensible default is used otherwise.")),
                        ("also_needed", stringArraySchema("For permission: other Mac capabilities this same request needs, so they grant once instead of twice.")),
                        ("mode", enumStringSchema(
                            ["read", "write", "read_write"],
                            "For permission: which axis the blocked call actually needed. Say read or write when that is all it was - omitting this asks for both, which is a wider grant than the work required."
                        )),
                        ("title", strSchema("For choose: the question.")),
                        ("scope_noun", strSchema("For model_choice: the single piece of work this should apply to, e.g. \"this image\". Supplying it scopes the choice to this request and offers the permanent change as the secondary action.")),
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
                description: "Generate or edit raster images from a prompt and optional local references. Defaults to the actual built-in image_gen.imagegen tool in a bounded Codex run, with no NativeAgent HTTP image request or OPENAI_API_KEY. Lazy-load this for art, illustration, design, poster, logo, mockup, or image-generation requests. Admitted Full Mac permits requested image generation; otherwise requires Trust Center multimodalPolicy.image_generation_openai=true. Saves images under data/generated_images/ and returns file paths plus a receipt. The image route and its model come from the provider picked for Work in Providers; this tool cannot choose either, and a route with no image API refuses rather than borrowing one. " + CodexImageGenerationHelp.usage,
                parametersJSON: params(
                    properties: [
                        ("prompt", strSchema("Describe the image or the edits, identifying what each reference supplies and what must stay unchanged.")),
                        ("size", strSchema("Size/aspect preference passed to Codex in prose, such as 16:9, 1536x864, or auto. No native size parameter is exposed by the built-in tool; inspect actual dimensions.")),
                        ("quality", strSchema("Visual quality preference: low, medium, high or auto. The built-in image tool has no quality parameter. Forwarded as prompt preference, with qualityFulfillment unknown unless independently reported. Do not confuse this with model reasoning effort.")),
                        ("output_format", strSchema("Format preference: png (default), jpeg or webp. Built-in Codex may choose its own format; decoded bytes determine the artifact extension.")),
                        ("background", strSchema("Background preference: auto, opaque or transparent. Transparent requests require PNG/WebP; preserve genuine alpha and inspect the result.")),
                        ("n", intSchema("Number of images, default 1, clamped to 1–4. Codex makes independent requests, not a coherent batch.")),
                        ("timeout_seconds", intSchema("Whole Codex image run timeout, 30-1800 seconds; default 600.")),
                        ("referenced_image_paths", stringArraySchema("Up to four authorized local PNG/JPEG/WebP files, 8 MiB each and 20 MiB total. Copies are attached to Codex and passed to the actual built-in tool. Resupply the latest result for further edits.")),
                        ("action", strSchema("auto (default), generate or edit. edit requires references; Codex is instructed to preserve the reference while applying the requested change.")),
                    ],
                    required: ["prompt"]
                )
            ),
            requestedSchema(
                name: "list_skills",
                description: "List only skill names, triggers, descriptions and status. Bodies load lazily; never read all skills or inspect private registry files.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "read_skill",
                description: "Load one skill body by manifest name only when its triggers match this work; never preload all bodies.",
                parametersJSON: params(
                    properties: [("name", strSchema())],
                    required: ["name"]
                )
            ),
            requestedSchema(
                name: "save_skill",
                description: "Create/update a reusable Capabilities skill only on explicit user request or for a proven repeatable procedure. Facts belong in commit_memory. Never inspect/write skills/registry.json or body paths yourself. Skills guide; they grant no tools, permissions, approval bypasses or safety authority.",
                parametersJSON: params(
                    properties: [
                        ("name", strSchema("Short stable display name.")),
                        ("description", strSchema("One concise sentence describing when and why this skill helps.")),
                        ("triggers", stringArraySchema("Specific phrases or situations that make this skill relevant.")),
                        ("content", strSchema("Markdown body beginning with a heading and containing the reusable procedure. Maximum 65536 UTF-8 bytes.")),
                        ("script", obj([
                            ("type", .string("object")),
                            ("description", .string("Optional; makes it repeatable. A save that adds or changes a script lands drafted: it runs only once skill.enable turns it on.")),
                            ("properties", obj([
                                ("source", strSchema("The JavaScript, run against app.*; at most 8192 bytes. Params arrive frozen as `input` (e.g. input.name; `args` is the same object).")),
                                ("params", looseObjectSchema("Each input name to its type: string, int, number, bool, list or object; a trailing ? marks it optional. Params arrive frozen as `input` (e.g. input.name).")),
                                ("actions", stringArraySchema("The app action ids it may call.", minItems: 1, maxItems: 50)),
                                ("steps", stringArraySchema("Optional label for each step.", maxItems: 50, maxItemLength: 160)),
                                ("of", intSchema("How many steps it has; leave it out when steps labels them.", minimum: 1, maximum: 50)),
                            ])),
                            ("required", .array([.string("source"), .string("actions")])),
                        ])),
                    ],
                    required: ["name", "description", "content"]
                )
            ),
            requestedSchema(
                name: "context_lookup",
                description: "Find NativeAgent capabilities and where to use them. Supports type='lookup_feature_surface' / 'feature_surface' / 'features'.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Capability or feature text to search for. Empty returns the first bounded feature-surface records.")),
                        ("type", strSchema("Optional lookup type. Supported: lookup_feature_surface, feature_surface, features.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "scratchpad_read",
                description: "Read the current session scratchpad written by /scratch controls or app action chat.scratch. The chat tool loop injects session_id when available.",
                parametersJSON: params(
                    properties: [
                        ("key", strSchema("Optional scratch key. If omitted, returns bounded scratch keys and values.")),
                        ("session_id", strSchema("Optional session id; injected by the Swift tool loop for normal chat/Telegram turns.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "time_now",
                description: "Return the current date and time in multiple representations: ISO-8601 UTC, ISO-8601 local timezone, epoch seconds, and a human-readable summary including weekday + day of year. Zero inputs. Use when reasoning about deadlines, scheduling, age of files/events, or relative time references.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "recent_trace_summary",
                description: "Read saved traces and receipts. view:receipts returns compact tool-end evidence with action, target, effect and time; effects_only filters successful non-read receipts, and since accepts today or an ISO-8601 timestamp. completed_turns selects the last N finished turns, excluding unfinished turns; scan limits are reported. name and turn_id select exact evidence. Results are bounded to 32 KiB including metadata; follow next_call for continuation. turn_id or completed_turns plus fields reads bounded, secret-redacted values.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum events per page, default 10, capped at 50.")),
                        ("offset", intSchema("Continuation event offset; copy from next_call.")),
                        ("before", strSchema("Continuation anchor timestamp; copy from next_call to keep the same window.")),
                        ("view", enumStringSchema(["receipts", "usage"], "Use receipts for compact tool.dispatch end receipts across all conversations unless session_id is explicit; non-read actions precede reads. usage sums recorded model calls across all conversations, defaults since to today, and reports missing measurements and retention coverage. Omit for all event kinds.")),
                        ("by", enumStringSchema(["model", "surface", "day"], "Usage grouping; default model. day uses local calendar dates.")),
                        ("effects_only", boolSchema("Successful non-read receipts with bounded target/effect previews; excludes previews and explicit no-effect results. Does not prove effects still persist.")),
                        ("since", strSchema("today (local midnight) or an ISO-8601 timestamp with Z or an offset. Reads the complete retained time window without tail scan limits; response pagination still applies.")),
                        ("completed_turns", intSchema("Last N finished turns, capped at 50; limit and the total response budget still apply. Includes completed, failed and cancelled turns.")),
                        ("kind", strSchema("Optional event kind substring, e.g. tool.dispatch or turn.terminal; tool/action names belong in name.")),
                        ("name", strSchema("Optional exact tool or app action filter, e.g. clipboard_read or mac.clipboard_read. For returned values use turn_id or completed_turns with fields:[name,args,result,receipt].")),
                        ("status", strSchema("Optional exact status filter.")),
                        ("session_id", strSchema("Optional exact chat session filter. Includes sibling events from turns belonging to that session.")),
                        ("sessionId", strSchema("Compatibility alias for session_id.")),
                        ("turn_id", strSchema("Optional exact turn id filter.")),
                        ("fields", stringArraySchema("Optional payload keys; requires turn_id or completed_turns. Up to 16 keys, 80 characters each; values share an 8 KiB cap.", minItems: 1, maxItems: 16, maxItemLength: 80)),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "agent_swarm",
                description: "Run temporary workers on an objective. Pass objective as the shared task and optionally agents with individual prompts. Workers use the selected Work model. Set reasoning_effort for the run or each worker; omitted levels inherit the run's level, then Work's Think default. Change that default with app setting.set (setting='providers.work_thinking'). Workers default to read-only reasoning; access='inherit' enables ordinary tools under current Trust. Returns worker outputs, optional synthesis and a receipt.",
                parametersJSON: params(
                    properties: [
                        ("objective", strSchema("Required. The task/question every worker should analyze.")),
                        ("agents", looseObjectArraySchema("Optional worker configs. Each object may include name, role, prompt/lens_brief, reasoning_effort, access ('read_only' or 'inherit'), contextSlice, findingsCap.")),
                        ("reasoning_effort", strSchema("Optional Think level for workers and synthesis: low, medium, high, xhigh, or another level the selected Work model's catalog supports. Defaults to Work's Think level. Each worker may override it with reasoning_effort.")),
                        ("workers", looseObjectArraySchema("Compatibility alias for agents.")),
                        ("roles", looseObjectArraySchema("Compatibility alias for agents.")),
                        ("agentCount", intSchema("Optional worker count when no agents array is supplied. Default 4, hard cap 20.")),
                        ("access", enumStringSchema(["read_only", "inherit"], "Worker capability mode. read_only (default) performs prompt-only reasoning. inherit exposes the ordinary NativeAgent tool loop under the same live TrustCenter and workspace gates as the parent; nested delegation and app install/restart remain parent-only.")),
                        ("readOnly", boolSchema("Compatibility alias: true maps to access=read_only; false maps to access=inherit.")),
                        ("mode", strSchema("Optional label such as parallel, council, review, or bughunt.")),
                        ("maxParallel", intSchema("Maximum concurrent workers. Clamped by trust policy.")),
                        ("timeoutSeconds", intSchema("Per-worker timeout, default 240, capped 900.")),
                        ("synthesize", nullableRecallField(boolSchema("Whether to run a final synthesis pass. Defaults true for multi-worker runs."))),
                        ("dryRun", boolSchema("If true, return the planned workers without calling providers.")),
                        ("maxOutputChars", intSchema("Per-worker and synthesis output cap, default 4000, max 12000.")),
                        ("digestBudgetTokens", intSchema("Optional soft token budget for the synthesis digest relayed back. When set, the digest is truncated to ~this many tokens with an explicit notice. Omit (default) for no extra truncation. Use a small budget (e.g. 500-2000) to keep the returned summary short.")),
                    ],
                    required: ["objective"]
                )
            ),
            requestedSchema(
                name: "market_status",
                description: "Return Swift-native market research configuration status: enabled sources, local watchlist groups, and TradingView readiness. Secrets/API keys/cookies are never returned.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "market_watchlists",
                description: "Read configured market watchlists from Swift-owned local config, or fetch TradingView watchlists when source='tradingview'. Secrets are never returned.",
                parametersJSON: params(
                    properties: [
                        ("source", strSchema("local or tradingview; default local")),
                        ("group", strSchema("Optional local watchlist group such as equities, futures, crypto, volatility, macro_series.")),
                        ("includeSymbols", nullableRecallField(boolSchema("Include symbol arrays; default true."))),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "tradingview_watchlist",
                description: "Compatibility alias for market_watchlists with source='tradingview'. Reads TradingView watchlists through Swift using stored session config; secrets are never returned.",
                parametersJSON: params(
                    properties: [
                        ("includeSymbols", nullableRecallField(boolSchema("Include symbol arrays; default true."))),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "market_quote",
                description: "Live quotes (price, % change, volume) for symbols or a whole watchlist in one call. Read-only. A named provider is used alone and its failure reported; without one, tradingview is tried, then yahoo, and the answering provider and failures are reported.",
                parametersJSON: params(
                    properties: [
                        ("symbol", strSchema("Ticker, or several separated by commas: \"AAPL, MSFT\". EXCHANGE:SYM for TradingView when a bare one isn't found. FX: EURUSD or FX:EURUSD for TradingView; EURUSD=X for Yahoo. Yahoo JPY=X means USDJPY and is translated for TradingView.")),
                        ("symbols", stringArraySchema("Ticker list.")),
                        ("watchlist", strSchema("A local watchlist name from market_watchlists; quotes all its symbols.")),
                        ("provider", enumStringSchema(["tradingview", "yahoo", "tv", "yfinance"], "tradingview or yahoo, used alone; omit to try tradingview then yahoo.")),
                    ],
                    required: []
                )
            ),
            // X chat tools are read-only. Outbound posts use the connector approval UI.
            requestedSchema(
                name: "x_status",
                description: "Checks the X API connection. Uses the paid X API — read x.com in Chrome (browser.chrome_navigate) instead; use this only if the person asks or Chrome can't.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "x_me",
                description: "Reads the connected account's profile and counts. Uses the paid X API — read x.com in Chrome (browser.chrome_navigate) instead; use this only if the person asks or Chrome can't.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "x_search",
                description: "Searches public posts of the last ~7 days. Uses the paid X API — read x.com in Chrome (browser.chrome_navigate) instead; use this only if the person asks or Chrome can't.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("X API v2 query, for example from:XDevelopers -is:retweet. Include a keyword, phrase or account; up to 512 characters.")),
                        // The recent-search endpoint's floor is 10, not 1. Ask
                        // for fewer and X answers 400, so advertise and enforce
                        // the provider's real bound rather than a friendlier one.
                        ("max", intSchema("Maximum tweets to return (10-100, default 10). X's recent-search endpoint rejects values below 10.", minimum: 10, maximum: 100)),
                        ("next_token", strSchema("meta.next_token from a previous x_search result, to fetch the next page. Repeat the same query.")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "x_timeline",
                description: "Reads the Following timeline. Uses the paid X API — read x.com in Chrome (browser.chrome_navigate) instead; use this only if the person asks or Chrome can't.",
                parametersJSON: params(
                    properties: [
                        ("max", intSchema("Maximum tweets to return (1-100, default 25).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "x_user_tweets",
                description: "Reads one account's recent posts by username or id. Uses the paid X API — read x.com in Chrome (browser.chrome_navigate) instead; use this only if the person asks or Chrome can't.",
                parametersJSON: params(
                    properties: [
                        ("username", strSchema("X handle without the @. One of username or id is required.")),
                        ("id", strSchema("Numeric X user id. One of username or id is required.")),
                        // The user-tweets endpoint's floor is 5 — lower than
                        // recent search's 10, higher than the timeline's 1. The
                        // advertised default was also wrong: the request builder
                        // has always sent 25.
                        ("max", intSchema("Maximum tweets to return (5-100, default 25). X's user-tweets endpoint rejects values below 5.", minimum: 5, maximum: 100)),
                    ],
                    required: []
                )
            ),
            // Cloud account connectors — read-only chat tools. Credential
            // setup/revoke remains in the Mac Connectors owner.
            requestedSchema(
                name: "gmail_status",
                description: "Check the connected Gmail account: its address and inbox counts (total, unread).",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "gmail_search",
                description: "Search Gmail with its query syntax (blank = newest mail); rows carry id, from, subject, date, snippet and unread. Read one with gmail_read. Pass next to this tool for more results.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Gmail query, e.g. is:unread from:person@example.com; blank = newest mail.")),
                        ("limit", intSchema("Maximum messages to return, 1-20; default 10.")),
                        ("page_token", strSchema("Provider nextPageToken from the previous result; keep the same query and limit.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "gmail_read",
                description: "Read one connected Gmail message by id, including up to 20,000 body characters. Pass next to this tool until it is null to finish the body.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("Gmail message id returned by gmail_search.")),
                        ("text_offset", intSchema("Character offset from next; default 0.", minimum: 0)),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "google_calendar_status",
                description: "Check the connected primary Google Calendar and return its identity and timezone.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "google_calendar_list",
                description: "List events from an exact Google calendar_id (primary when omitted): one day with day, else the next seven days. Pass next to this tool for more events in the same calendar and time range.",
                parametersJSON: params(
                    properties: [
                        ("day", strSchema("'today', 'tomorrow' or 'YYYY-MM-DD': that local day.")),
                        ("time_min", strSchema("Optional inclusive ISO-8601 start time.")),
                        ("calendar_id", strSchema("Exact Google calendar ID from google_calendar_calendars; never a calendar title.")),
                        ("time_max", strSchema("Optional exclusive ISO-8601 end time.")),
                        ("limit", intSchema("Maximum events, 1-50; default 20.")),
                        ("page_token", strSchema("Provider nextPageToken from the previous result; keep the same time range and limit.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "google_calendar_calendars",
                description: "List connected Google calendars with stable IDs, access roles and timezones. Choose the destination explicitly by ID, never by matching a title. Pass next for more calendars.",
                parametersJSON: params(properties: [("page_token", strSchema("Provider continuation token."))], required: [])
            ),
            requestedSchema(
                name: "google_calendar_free_busy",
                description: "Check free/busy for exact Google calendar IDs or attendee email addresses over a window of at most 31 days. Missing access is unknown, never free.",
                parametersJSON: params(properties: [
                    ("calendar_ids", obj([("type", .string("array")), ("items", strSchema()), ("minItems", .int(1)), ("maxItems", .int(50))])),
                    ("start", strSchema("RFC3339 start with Z or an explicit offset.")),
                    ("end", strSchema("RFC3339 end with Z or an explicit offset; after start."))
                ], required: ["calendar_ids", "start", "end"])
            ),
            requestedSchema(
                name: "google_calendar_read",
                description: "Read one exact Google event or recurring series by calendar_id and event_id, including attendees and recurrence. Use after an uncertain invitation outcome; this never sends invitations.",
                parametersJSON: params(properties: [
                    ("calendar_id", strSchema("Exact Google calendar ID from google_calendar_calendars; never a calendar title.")),
                    ("event_id", strSchema("Exact Google event ID from a prior result."))
                ], required: ["calendar_id", "event_id"])
            ),
            requestedSchema(
                name: "google_calendar_send_invitations",
                description: "Schedule one meeting in an explicitly selected Google calendar: check availability, create with attendees and optional recurrence, request invitations to all guests, then read back confirmed details. External send: existing approval gate applies. A confirmed event is not RSVP acceptance or email delivery. Recurrence availability checks only the first occurrence. Reuse event_id after an uncertain outcome; never create a second ID to retry.",
                parametersJSON: params(properties: [
                    ("calendar_id", strSchema("Exact writable ID from google_calendar_calendars; primary alias and titles are not accepted.")),
                    ("event_id", strSchema("Stable unique base32hex ID (5-1024 lowercase a-v/0-9 characters); reuse for this meeting and approval replay.")),
                    ("title", strSchema("Meeting title.")),
                    ("start", strSchema("RFC3339 start with Z or an explicit offset.")),
                    ("end", strSchema("RFC3339 end with Z or an explicit offset; after start.")),
                    ("time_zone", strSchema("IANA timezone for the meeting and recurrence, e.g. America/Denver.")),
                    ("attendees", obj([("type", .string("array")), ("items", strSchema("Exact attendee email address; never guess from a name.")), ("minItems", .int(1)), ("maxItems", .int(50))])),
                    ("recurrence", obj([("type", .string("array")), ("items", strSchema("RFC5545 RRULE, RDATE, EXDATE or EXRULE line; no DTSTART/DTEND.")), ("maxItems", .int(20))])),
                    ("check_calendar_ids", obj([("type", .string("array")), ("items", strSchema("Additional exact Google calendar IDs or attendee emails to check; destination is always checked.")), ("minItems", .int(1)), ("maxItems", .int(49))])),
                    ("allow_conflicts", boolSchema("Explicitly permit known busy calendars; unknown availability still blocks sending. Default false.")),
                    ("description", strSchema("Optional meeting description.")),
                    ("location", strSchema("Optional meeting location."))
                ], required: ["calendar_id", "event_id", "title", "start", "end", "time_zone", "attendees"])
            ),
            requestedSchema(
                name: "notion_status",
                description: "Check the connected Notion integration identity.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "notion_search",
                description: "Search pages and databases shared with the connected Notion integration. Pass next to this tool for more results.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Optional title search text.")),
                        ("limit", intSchema("Maximum results, 1-50; default 20.")),
                        ("start_cursor", strSchema("Provider nextCursor from the previous result; keep the same query and limit.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "notion_read_page",
                description: "Read a Notion page's text by title, link or id, up to 100 immediate blocks and 20,000 characters per call. Pass next to finish this text chunk, nextPage for more blocks, and each children input to this tool recursively for nested text. Finish all three before treating the page as complete. On rate limits, wait for retryAfter before trying again.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("The page's title, notion.so link, or id from notion_search.")),
                        ("block_id", strSchema("Child block id from children; omit to read the page's immediate blocks.")),
                        ("start_cursor", strSchema("Provider nextCursor for this block's next page of children.")),
                        ("text_offset", intSchema("Character offset from next within this block page; default 0.", minimum: 0)),
                    ],
                    required: ["id"]
                )
            ),
            // GitHub — PAT-backed read tools. These are lazy-loaded by
            // tool_load(category:"github") or explicit tool_load by name.
            requestedSchema(
                name: "github_status",
                description: "Validate the connected GitHub Personal Access Token against the authenticated /user endpoint.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "github_list_repos",
                description: "List repositories accessible to the connected GitHub Personal Access Token.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum compact repository rows to return (1-20, default 20). Use pagination/filtering for more.")),
                        ("visibility", strSchema("Optional GitHub visibility filter, e.g. all, public, private.")),
                        ("affiliation", strSchema("Optional GitHub affiliation filter, e.g. owner,collaborator,organization_member.")),
                        ("sort", strSchema("Optional sort field, e.g. updated, created, pushed, full_name.")),
                        ("direction", enumStringSchema(["asc", "desc"], "Optional direction, asc or desc.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_list_runs",
                description: "Read GitHub Actions workflow runs and CI/build status through the connected API: workflow name, event, branch, status, conclusion, timestamps, link and clipped head commit message. Without repo, list failures across up to five most recently pushed repositories owned by the account, with coverage and truncation stated.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("Optional repository as owner/name or a github.com repository URL.")),
                    ("status", enumStringSchema(["failure", "success", "in_progress", "all"], "Run filter; default all for one repo. Without repo, only failures are listed; omit status or use all/failure.")),
                    ("branch", strSchema("Optional branch name.")),
                    ("limit", intSchema("Maximum runs returned across the selected repositories, 1-30; default 10.")),
                ], required: [])
            ),
            requestedSchema(
                name: "github_run_jobs",
                description: "Read failed jobs and their failed step names for a GitHub Actions run. Inspects up to 100 jobs from the latest attempt and returns up to 30 failed jobs, with truncation stated. No logs are downloaded.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("Repository as owner/name or a github.com repository URL.")),
                    ("run_id", intSchema("Positive workflow run id from github.runs.")),
                ], required: ["repo", "run_id"])
            ),
            requestedSchema(
                name: "github_list_notifications",
                description: "List bounded GitHub notifications for the connected account through the native API, optionally scoped to one repository. Returns count, has_more and next_page; total is null because GitHub does not provide it. Follow next_page with the same filters and limit. Use for overnight activity, mentions, reviews, assignments, and CI-related notification checks.",
                parametersJSON: params(
                    properties: [
                        ("repo", strSchema("Optional repository as owner/name or a github.com repository URL.")),
                        ("owner", strSchema("Optional owner when repo is only the repository name.")),
                        ("url", strSchema("Optional github.com repository URL when repo is omitted.")),
                        ("all", boolSchema("Include read notifications; default false.")),
                        ("participating", boolSchema("Only notifications where the user is directly participating or mentioned; default false.")),
                        ("since", strSchema("Optional inclusive ISO-8601 timestamp.")),
                        ("before", strSchema("Optional exclusive ISO-8601 timestamp.")),
                        ("limit", intSchema("Maximum compact notifications, 1-20; default 20.")),
                        ("page", intSchema("GitHub pagination page; default 1.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_get_repository",
                description: "Start a GitHub repository inspection through the connected API. Returns bounded repository metadata, the root layout, and README text in one call. Accepts owner/name or a github.com repository URL.",
                parametersJSON: params(
                    properties: [
                        ("repo", strSchema("Repository as owner/name or a github.com repository URL.")),
                        ("owner", strSchema("Optional owner when repo is only the repository name.")),
                        ("url", strSchema("Optional github.com repository URL when repo is omitted.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_read_repository_content",
                description: "Read a GitHub repo file or list a folder in one call; a github.com file or folder link alone is enough (its /blob/ or /tree/ ref and path are used). Bounded text, compact entries.",
                parametersJSON: params(
                    properties: [
                        ("repo", strSchema("Repository as owner/name or any github.com link into it.")),
                        ("owner", strSchema("Optional owner when repo is only the repository name.")),
                        ("url", strSchema("Optional github.com link (repo, /tree/ or /blob/) when repo is omitted.")),
                        ("path", strSchema("Repository-relative file or directory path. Omit for root.")),
                        ("ref", strSchema("Optional branch, tag, or commit SHA.")),
                        ("max_characters", intSchema("Maximum text characters for a file, 1000-100000; default 30000.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_list_commits",
                description: "List recent commits for a GitHub repository through the connected API, optionally filtered by branch/ref, path, or time.",
                parametersJSON: params(
                    properties: [
                        ("repo", strSchema("Repository as owner/name or a github.com repository URL.")),
                        ("owner", strSchema("Optional owner when repo is only the repository name.")),
                        ("url", strSchema("Optional github.com repository URL when repo is omitted.")),
                        ("ref", strSchema("Optional branch, tag, or commit SHA.")),
                        ("path", strSchema("Optional repository-relative path filter.")),
                        ("since", strSchema("Optional inclusive ISO-8601 timestamp.")),
                        ("until", strSchema("Optional exclusive ISO-8601 timestamp.")),
                        ("limit", intSchema("Maximum compact commits, 1-20; default 10.")),
                        ("page", intSchema("GitHub pagination page; default 1.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_list_issues",
                description: "List GitHub issues visible to the connected Personal Access Token, optionally scoped to a repository.",
                parametersJSON: params(
                    properties: [
                        ("owner", strSchema("Repository owner when repo is not owner/name.")),
                        ("repo", strSchema("Optional repository name or owner/name. Omit to list authenticated-user issues.")),
                        ("state", enumStringSchema(["open", "closed", "all"], "Optional issue state filter: open, closed, or all.")),
                        ("sort", enumStringSchema(["created", "updated", "comments"], "Optional sort field: created, updated, or comments.")),
                        ("direction", enumStringSchema(["asc", "desc"], "Optional direction, asc or desc.")),
                        ("limit", intSchema("Maximum compact issue rows to return (1-20, default 20).")),
                        ("page", intSchema("GitHub pagination page (default 1).")),
                        ("labels", strSchema("Optional comma-separated label filter.")),
                        ("since", strSchema("Optional ISO 8601 timestamp filter.")),
                        ("filter", strSchema("Optional authenticated-user issue filter when repo is omitted.")),
                        ("assignee", strSchema("Optional repository issue assignee filter.")),
                        ("creator", strSchema("Optional repository issue creator filter.")),
                        ("mentioned", strSchema("Optional repository issue mentioned-user filter.")),
                        ("milestone", strSchema("Optional repository issue milestone filter.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "github_search",
                description: "Search GitHub issues and pull requests (default) or repositories (type repositories) with GitHub search qualifiers; returns bounded paginated results.",
                parametersJSON: params(properties: [
                    ("query", strSchema("Required GitHub search query, with qualifiers such as repo:, is:pr, author:, label: (issues) or language:, stars:, topic: (repositories).")),
                    ("type", enumStringSchema(["issues", "repositories"], "issues (default; issues and pull requests) or repositories.")),
                    ("sort", enumStringSchema(["comments", "reactions", "interactions", "created", "updated", "stars", "forks"], "Optional sort: comments, reactions, interactions, created or updated (issues); stars, forks or updated (repositories).")),
                    ("order", enumStringSchema(["asc", "desc"], "Optional asc or desc.")),
                    ("limit", intSchema("Compact results per page, 1-20. Bodies are excerpted; use get_issue/get_pull_request for detail.")),
                    ("page", intSchema("Pagination page.")),
                ], required: ["query"])
            ),
            requestedSchema(
                name: "github_list_pull_requests",
                description: "List pull requests for a repository with state, branches, authors, reviewers, labels, milestones, timestamps, commit SHAs, mergeability hints, and URLs.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("Required repository as owner/name.")),
                    ("state", enumStringSchema(["open", "closed", "all"], "open, closed, or all.")),
                    ("head", strSchema("Optional head filter.")), ("base", strSchema("Optional base branch filter.")),
                    ("sort", enumStringSchema(["created", "updated", "popularity", "long-running"], "created, updated, popularity, or long-running.")),
                    ("direction", enumStringSchema(["asc", "desc"], "asc or desc.")), ("limit", intSchema("Compact rows per page, 1-20.")),
                    ("page", intSchema("Pagination page.")),
                ], required: ["repo"])
            ),
            requestedSchema(
                name: "github_get_issue",
                description: "Get one GitHub issue with its full native metadata, assignees, labels, milestone, timestamps, links, and pull-request marker when applicable.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("owner/name, owner/name#12, or the issue/PR link.")), ("number", intSchema("Issue number.")),
                ], required: ["repo", "number"])
            ),
            requestedSchema(
                name: "github_get_pull_request",
                description: "Get one pull request plus bounded commits, reviews, derived review state, head checks/status, branches, mergeability, and URLs.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("owner/name, owner/name#12, or the issue/PR link.")), ("number", intSchema("Pull request number.")),
                    ("limit", intSchema("Per-related-collection bound, 1-20.")),
                ], required: ["repo", "number"])
            ),
            requestedSchema(
                name: "github_pull_request_files",
                description: "Inspect paginated pull-request changed files and patches with an explicit total patch-character bound.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("owner/name, owner/name#12, or the issue/PR link.")), ("number", intSchema("Pull request number.")),
                    ("limit", intSchema("Files per page, 1-100.")), ("page", intSchema("Pagination page.")),
                    ("max_patch_characters", intSchema("Total patch text bound, 0-250000; default 80000.")),
                ], required: ["repo", "number"])
            ),
            requestedSchema(
                name: "github_pull_request_activity",
                description: "Inspect paginated PR issue comments, inline review comments, reviews, and timeline/status events.",
                parametersJSON: params(properties: [
                    ("repo", strSchema("owner/name, owner/name#12, or the issue/PR link.")), ("number", intSchema("Pull request number.")),
                    ("limit", intSchema("Compact rows per activity collection, 1-20.")), ("page", intSchema("Pagination page.")),
                ], required: ["repo", "number"])
            ),
            requestedSchema(
                name: "github_discover_tracking",
                description: "Resolve accessible repositories and add them to the durable GitHub tracking selection (replace:true replaces it). Contribution mode (default) tracks only PRs authored by the authenticated contributor plus issues linked from their PR bodies; repository mode must be explicit.",
                parametersJSON: params(properties: [
                    ("query", strSchema("Configurable repository name/description terms, for example Hermes.")),
                    ("repositories", .object(["type": .string("array"), "items": .object(["type": .string("string")])])),
                    ("mode", strSchema("Tracking scope: contributions (default) or repository.")),
                    ("contributor_login", strSchema("Authenticated GitHub login whose authored PRs define contribution scope.")),
                    ("project", strSchema("Desk project label.")), ("persist", nullableRecallField(boolSchema("Persist selection; default true."))),
                    ("replace", boolSchema("true replaces the tracked list. Default adds to it, keeping its project, scope and timing.")),
                    ("refresh_interval_minutes", intSchema("Background refresh interval, 5-1440.")),
                    ("stale_after_hours", intSchema("Open entity staleness threshold.")),
                    ("max_pages", intSchema("Accessible-repository discovery page bound, 1-10.")),
                ], required: [])
            ),
            requestedSchema(
                name: "github_project_digest",
                description: "Refresh or read the configured scoped GitHub view and return current authored PR/linked-issue work, closed PR history counts, blockers/staleness, and Desk create/update/archive reconciliation.",
                parametersJSON: params(properties: [
                    ("refresh", nullableRecallField(boolSchema("Refresh from GitHub before digesting; default true."))),
                ], required: [])
            ),
            requestedSchema(
                name: "github_mutate",
                description: "Create/update/comment/review/close/reopen GitHub issues or PRs, request reviewers, or merge. External write: always uses the native approval/policy path before execution.",
                parametersJSON: params(properties: [
                    ("operation", enumStringSchema(["create_issue", "update_issue", "close_issue", "reopen_issue", "comment_issue", "create_pull_request", "update_pull_request", "close_pull_request", "reopen_pull_request", "comment_pull_request", "review_pull_request", "request_reviewers", "merge_pull_request"], "create_issue|update_issue|close_issue|reopen_issue|comment_issue|create_pull_request|update_pull_request|close_pull_request|reopen_pull_request|comment_pull_request|review_pull_request|request_reviewers|merge_pull_request")),
                    ("repo", strSchema("owner/name, owner/name#12, or the issue/PR link.")), ("number", intSchema("Issue/PR number where required.")),
                    ("title", strSchema("Issue/PR title.")), ("body", strSchema("Body or comment text.")),
                    ("state", strSchema("open or closed.")), ("state_reason", strSchema("Issue state reason.")),
                    ("head", strSchema("PR head branch.")), ("base", strSchema("PR base branch.")), ("draft", boolSchema("Create PR as draft.")),
                    ("labels", .object(["type": .array([.string("string"), .string("array")])])),
                    ("assignees", .object(["type": .array([.string("string"), .string("array")])])),
                    ("clear_labels", boolSchema("Explicitly clear every issue label. Empty labels alone preserve the current labels; do not combine this with nonempty labels.")),
                    ("clear_assignees", boolSchema("Explicitly clear every issue assignee. Empty assignees alone preserve the current assignees; do not combine this with nonempty assignees.")),
                    ("reviewers", .object(["type": .array([.string("string"), .string("array")])])),
                    ("team_reviewers", .object(["type": .array([.string("string"), .string("array")])])),
                    ("event", enumStringSchema(["COMMENT", "APPROVE", "REQUEST_CHANGES"], "Review event: COMMENT, APPROVE, or REQUEST_CHANGES.")),
                    ("merge_method", enumStringSchema(["merge", "squash", "rebase"], "merge, squash, or rebase.")), ("sha", strSchema("Expected head SHA for merge.")),
                    ("commit_title", strSchema("Merge commit title.")), ("commit_message", strSchema("Merge commit message.")),
                    ("milestone", intSchema("Milestone number.")),
                ], required: ["operation", "repo"])
            ),
            requestedSchema(
                name: "github_set_repo_visibility",
                description: "Set a GitHub repository to private or public (external write; requires approval).",
                parametersJSON: params(
                    properties: [
                        ("owner", strSchema("Repo owner when repo is not owner/name.")),
                        ("repo", strSchema("Repository name or owner/name.")),
                        ("private", boolSchema("Set true to make the repo private, or false to make it public.")),
                        ("visibility", strSchema("Optional: private or public.")),
                    ],
                    required: []
                )
            ),
            // Slack tools are lazy-loaded; posting persists a bounded approval request.
            requestedSchema(
                name: "slack_status",
                description: "Check whether the connected Slack workspace token is valid.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "slack_list_channels",
                description: "List Slack conversations accessible to the bot. Use this to find the channel ID before posting.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum conversations to return (1-1000, default 100).")),
                        ("types", strSchema("Optional Slack conversations.list types, e.g. public_channel,private_channel,mpim,im.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "slack_search_messages",
                description: "Search Slack messages through the connected workspace. Requires Slack search permission/token support.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Slack search query.")),
                        ("count", intSchema("Maximum messages to return (1-100, default 20).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "slack_post_message",
                description: "Stage approval to post a message to Slack using the connected bot token. Use a channel ID from slack_list_channels when possible.",
                parametersJSON: params(
                    properties: [
                        ("channel", strSchema("Slack channel, DM, MPIM, or conversation ID.")),
                        ("text", strSchema("Message text to send.")),
                    ],
                    required: ["channel", "text"]
                )
            ),
            // AgentMail — Agent's hosted inbox. Discovery-only until
            // tool_load(category:"agentmail") or explicit tool_load by name.
            requestedSchema(
                name: "agentmail_list",
                description: "List my AgentMail inbox, newest first: sender, subject, date, snippet, unread, message_id. Read one with agentmail_read. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum messages to return (1-50, default 20).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "agentmail_read",
                description: "Read the full body of one message from the configured AgentMail inbox. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("message_id", strSchema("Required AgentMail message id from agentmail_list.")),
                    ],
                    required: ["message_id"]
                )
            ),
            requestedSchema(
                name: "agentmail_send",
                description: "Sends an email from the configured AgentMail inbox after the required send approval; returns a failed status if AgentMail is not configured.",
                parametersJSON: params(
                    properties: [
                        ("to", stringOrStringArraySchema("Recipient address(es). May be a single string or list of strings.")),
                        ("subject", strSchema("Email subject (required).")),
                        ("body", strSchema("Email body text (required).")),
                        ("cc", stringOrStringArraySchema("Optional CC recipient(s). String or array.")),
                    ],
                    required: ["to", "subject", "body"]
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
                description: "List local EventKit calendars with stable IDs and write access. Requires Calendar Read and full EventKit access. Choose a destination explicitly by ID.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "mac_calendar_free_busy",
                description: "Check local free/busy across every calendar (or the exact EventKit calendar IDs given) over at most 31 days. Includes tentative and unavailable intervals; unsupported availability is unknown, never free. Requires Calendar Read and full EventKit access.",
                parametersJSON: params(properties: [
                    ("calendar_ids", obj([("type", .string("array")), ("items", strSchema()), ("minItems", .int(1)), ("maxItems", .int(50)), ("description", .string("Optional; omit to check every calendar."))])),
                    ("start", stringOrIntSchema("Window start: ISO-8601 or epoch seconds.")),
                    ("end", stringOrIntSchema("Window end after start: ISO-8601 or epoch seconds."))
                ], required: ["start", "end"])
            ),
            requestedSchema(
                name: "mac_calendar_list_upcoming",
                description: "List the user's Mac calendar events from EventKit. Read-only; requires Calendar -> Read permission. Returns event titles, start/end timestamps, calendar names, and locations. For today/tomorrow/specific-date questions, pass day ('today', 'tomorrow', or 'YYYY-MM-DD') instead of relying on a broad hours window.",
                parametersJSON: params(
                    properties: [
                        ("day", strSchema("Optional local-day scope: 'today', 'tomorrow', or 'YYYY-MM-DD'. Use for same-day calendar questions to avoid next-day all-day event bleed.")),
                        ("range", strSchema("Natural local range: today, tomorrow, this week, next week, or next N days (1–30). Takes precedence over day and hours_ahead; this week runs from now to the end of the local calendar week; next week is the whole following calendar week.")),
                        ("hours_ahead", intSchema("Lookahead window in hours (1-720, default 24).")),
                        ("days", intSchema("Optional: the next N days (1–30), same as range 'next N days'.")),
                        ("limit", intSchema("Maximum events to return (1-100, default 20).")),
                        ("calendar_name", strSchema("Optional filter — return events only from this calendar.")),
                        ("calendar_id", strSchema("Optional exact EventKit calendar ID from mac_calendar_calendars.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mac_reminders_query",
                description: "Find Mac Reminders across all dates, including undated tasks. Searches titles and notes; incomplete reminders by default. Read-only; requires Reminders → Read permission. Follow next_offset with the same filters for more results.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Optional text to find in titles or notes (case insensitive).")),
                        ("list_name", strSchema("Optional list-name filter (case insensitive contains).")),
                        ("due_start", stringOrIntSchema("Inclusive due-range start: ISO-8601, local YYYY-MM-DD, or epoch seconds.")),
                        ("due_end", stringOrIntSchema("Exclusive due-range end; undated tasks are excluded from date ranges.")),
                        ("undated_only", boolSchema("Return only tasks with no due date; cannot be combined with a due range.")),
                        ("include_completed", boolSchema("Include completed reminders (default false).")),
                        ("offset", intSchema("Result offset (default 0); use next_offset from the preceding page.")),
                        ("limit", intSchema("Maximum reminders per page (1-100, default 20).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mac_reminders_read",
                description: "Read exactly one Mac Reminder by id, regardless of due date or completion. Returns current title, list, due date, completion and full notes. Read-only; requires Reminders → Read permission.",
                parametersJSON: params(
                    properties: [("id", strSchema("Exact reminder id from a reminder query, read or creation."))],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_list_due_today",
                description: "List Mac Reminders due today and overdue, earliest first. Returns total and has_more; a capped list cannot rule out reminders due today. Use reminders.query with due_start/due_end for today alone. Read-only; requires Reminders -> Read permission.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum reminders to return (1-200, default 50).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mac_notify",
                description: "Post a macOS user notification on this Mac. Requires Mac Notifications -> Write permission. Use for short, actionable alerts, not as a substitute for chat.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Notification title (required, short).")),
                        ("message", strSchema("Notification body text (required).")),
                        ("subtitle", strSchema("Optional subtitle shown between title and body.")),
                    ],
                    required: ["title", "message"]
                )
            ),
            requestedSchema(
                name: "phone_request",
                description: "Ask your paired iPhone for its current location or a photo chosen or taken by the person. Open NativeAgent on the phone to respond. Waits for a result; phone permissions apply.",
                parametersJSON: params(properties: [
                    ("kind", enumStringSchema(["location.current", "photo.pick", "photo.capture"], "What to ask for.")),
                    ("params", .object(["type": .string("object"), "description": .string("Leave empty."),
                        "properties": .object([:]), "additionalProperties": .bool(false)])),
                    ("wait_seconds", intSchema("Seconds to wait (1–120; default 60).", minimum: 1, maximum: 120)),
                ], required: ["kind"])
            ),
            requestedSchema(
                name: "mobile_notify",
                description: "Push a notification to the paired iPhone via the NativeAgent mobile bridge. Requires iPhone Notifications -> Write permission. Use sparingly; these wake the phone.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Notification title (required, short).")),
                        ("message", strSchema("Notification body text (required).")),
                        ("subtitle", strSchema("Optional subtitle.")),
                        ("source", strSchema("Optional source tag for tracking (e.g. 'calendar_reminder').")),
                    ],
                    required: ["title", "message"]
                )
            ),
            requestedSchema(
                name: "mac_spotlight_search",
                description: "Search the Mac with Spotlight and return file paths plus modified_at and added_at dates in files (null when unavailable). Plain words can match file contents; use an exact-name predicate for a filename. Read-only; requires Spotlight -> Read permission.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Spotlight words or predicate. Exact filename: kMDItemFSName == \"hello.txt\". Alias 'q' is also accepted.")),
                        ("q", strSchema("Alias for 'query'.")),
                        ("name", strSchema("Filename contains this text, case-insensitive (files named …); use instead of query.")),
                        ("limit", intSchema("Maximum paths (1-200, default 10).")),
                    ],
                    required: []
                )
            ),
            // Sensitive Mac Integration writes default off and require the user's toggle.
            requestedSchema(
                name: "contacts_search",
                description: "Search the user's local Mac Contacts by name (including saved names like Mom or Dad), phone, or email and return matching records (name, organization, phones, emails, identifier). Read-only; requires Contacts -> Read permission.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Search string — matches against name, phone, or email.")),
                        ("limit", intSchema("Maximum contacts to return (1-100, default 20).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "contacts_create_or_update",
                description: "Create a Mac contact, or update one: by identifier, or the single existing contact with the same full name. Phones and emails are added, never replaced. Requires Contacts -> Write permission.",
                parametersJSON: params(
                    properties: [
                        ("given_name", strSchema("First name (optional).")),
                        ("family_name", strSchema("Last name (optional).")),
                        ("organization", strSchema("Organization / company (optional).")),
                        ("phones", stringArraySchema("Optional list of phone numbers.")),
                        ("emails", stringArraySchema("Optional list of email addresses.")),
                        ("identifier", strSchema("Contact to update: identifier from contacts_search, or its exact full name.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_list_recent",
                description: "List Apple Mail's inbox or sent metadata and exact mailbox totals; inbox_unread_by_category counts Primary, Transactions, Updates, Promotions and unclassified across the whole inbox. Primary is not proof of a human sender. Filtered or explicitly sorted lists cover all categories. Pass scope + message_id + expected_message_id to read a body and attachments (filename, content_type, size in bytes, 1-based index). Read-only; requires Mail → Read permission.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum messages to return (1-50, default 10).")),
                        ("scope", strSchema("Mailbox scope: inbox (default) or sent. Keep the same scope for continuation and message-body reads.")),
                        ("all_categories", boolSchema("Inbox lists show Mail's Primary and Transactions categories; true lists Updates and Promotions too.")),
                        ("unread", boolSchema("true selects unread messages, false selects read messages; omit for both.")),
                        ("sort", enumStringSchema(["newest", "oldest"], "Date order; default newest. Keep unchanged for continuation.")),
                        ("offset", mailOffsetSchema),
                        ("message_id", intSchema("Exact positive message ID from a prior read in the same scope; returns up to 16000 characters of body.")),
                        ("body_offset", intSchema("Exact detail continuation offset from body_end, up to 2000000; omit initially.")),
                        ("expected_message_id", strSchema("Exact RFC message identifier paired with message_id in the prior read.")),
                        ("expected_account", strSchema("expected_account from the same row, when it has one.")),
                        ("position", intSchema("position from the same row: finds the message fast.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_save_attachment",
                description: "Save one local Apple Mail attachment by index or unique filename using an observed mail.N name or paired message identity from a Mail read. Defaults to ~/Downloads; destination is a folder within the same writable roots as files.write in the current mode. Never overwrites: adds a numbered suffix. Returns path and size in bytes. Requires Mail Read access; no Mail UI or AppleScript is used.",
                parametersJSON: params(properties: [
                    ("name", strSchema("Observed mail.N workspace name; use instead of exact locator fields.")),
                    ("message_id", intSchema("Exact positive message ID from the Mail read.")),
                    ("expected_message_id", strSchema("Exact RFC message identifier paired with message_id.")),
                    ("expected_account", strSchema("expected_account from the same row, when present.")),
                    ("scope", enumStringSchema(["inbox", "sent"], "Mailbox scope from the same row; default inbox.")),
                    ("position", intSchema("position from the same row, when present.")),
                    ("index", intSchema("1-based attachment index from the Mail read; index or filename is required.")),
                    ("filename", strSchema("Exact unique attachment filename; index disambiguates duplicate names.")),
                    ("destination", strSchema("Destination folder; default ~/Downloads."))
                ], required: [])
            ),
            requestedSchema(
                name: "mail_read_batch",
                description: "Read bodies for 1–10 selected Apple Mail messages in one bounded call. Each item uses an observed workspace name or exact message_id + expected_message_id + expected_account and scope. Returns ordered per-item receipts, up to 4000 body characters each, and body_end for continuation when truncated. No rediscovery or retry; unfinished items are explicit. Requires Mail Read permission.",
                parametersJSON: params(properties: [("items", mailBatchItemsSchema(effects: false))], required: ["items"])
            ),
            requestedSchema(
                name: "mail_triage_batch",
                description: "Triage 1–10 selected inbox messages in one bounded call: mark read, flag/unflag, then archive in the source account. Each item uses an observed workspace name or exact message_id + expected_message_id + expected_account; actions require a nonempty RFC identifier. Returns ordered per-item and per-action receipts, including partial effects. Cancellation, deadline or uncertain effects stop remaining work; never replay an uncertain item. No deletion: mail_delete retains its move-to-Trash approval gate. Requires Mail Write permission.",
                parametersJSON: params(properties: [("items", mailBatchItemsSchema(effects: true))], required: ["items"])
            ),
            requestedSchema(
                name: "mail_search",
                description: "Search or list Apple Mail's whole inbox or sent mailbox, all categories, with optional query, from, since, unread, category, attachment; default newest. Returns matching_total, has_more, next_offset and metadata, plus up to five attachment_names per message when filtering attachments. Search results can be passed to mail.mark_read in one call. Bodies are not searched. Requires Mail → Read permission.",
                parametersJSON: params(
                    properties: [
                        ("query", stringOrStringArraySchema("One search term or an array of terms matched with OR against mailbox subject and sender metadata. Example: [\"receipt\", \"order confirmation\"]. Keep the same terms for continuation.")),
                        ("from", strSchema("Sender name or address fragment, matched case and accents aside; combined with other filters using AND.")),
                        ("attachment", obj([("description", .string("true selects messages with any attachment; a nonempty string matches an attachment filename fragment, case and accents aside. Combined with other filters using AND.")), ("anyOf", .array([
                            obj([("type", .string("boolean")), ("enum", .array([.bool(true)]))]),
                            obj([("type", .string("string")), ("minLength", .int(1))]),
                        ]))])),
                        ("since", strSchema("Inclusive received date: this week (start of the local calendar week), local YYYY-MM-DD, or ISO-8601 with a time zone.")),
                        ("category", strSchema("Mail categories: primary, transactions, updates, promotions; comma-separated categories combine. A category is not a guarantee of a human sender.")),
                        ("unread", boolSchema("true selects unread messages, false selects read messages; omit for both.")),
                        ("sort", enumStringSchema(["newest", "oldest"], "Date order; default newest. Keep unchanged for continuation.")),
                        ("scope", strSchema("Mailbox scope: inbox (default) or sent. Keep the same scope for continuation and message-body reads.")),
                        ("limit", intSchema("Maximum messages to return (1-50, default 10).")),
                        ("offset", mailOffsetSchema),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_senders",
                description: "Rank Apple Mail senders by exact message count in one bounded read-only grouped query, with unread count, newest date, address and display name. Covers inbox by default or all indexed mail; supports date, category and unread filters. Useful for sender frequency and unsubscribe candidates. Requires Mail Read permission and macOS Full Disk Access.",
                parametersJSON: params(properties: [
                    ("limit", intSchema("Maximum senders to return (1-50, default 15).")),
                    ("since", strSchema("Inclusive received date: this week, local YYYY-MM-DD, or ISO-8601 with a time zone.")),
                    ("scope", enumStringSchema(["inbox", "all"], "Mailbox scope; default inbox.")),
                    ("category", strSchema("Mail categories: primary, transactions, updates, promotions; comma-separated categories combine.")),
                    ("unread_only", boolSchema("Count and rank only unread messages; default false.")),
                ], required: [])
            ),
            requestedSchema(
                name: "mail_send",
                description: "Sends an email now through Apple Mail. Requires Mail Write permission, requested inline when needed, or admitted Full Mac access. An explicit Mail Write revocation still applies.",
                parametersJSON: params(
                    properties: [
                        ("to", stringOrStringArraySchema("Recipient address(es). May be a single string or list of strings.")),
                        ("subject", strSchema("Email subject (required).")),
                        ("body", strSchema("Email body text (required).")),
                        ("cc", stringOrStringArraySchema("Optional CC recipient(s). String or array.")),
                        ("bcc", stringOrStringArraySchema("Optional BCC recipient(s). String or array.")),
                    ],
                    required: ["to", "subject", "body"]
                )
            ),
            requestedSchema(
                name: "messages_recent_threads",
                description: "Read Messages: from_me selects newest sent or received messages across all conversations, with named participants and exact sent_count or received_count when since is given; otherwise list conversations newest first, filter unread threads, order by oldest unread incoming message, find them by person or words, or open an exact thread. Threads include unread_count across all dates and latest_message_is_read; history includes each message's is_read when chat.db exposes it, otherwise unread_state says unavailable. These are local read flags, not recipient read receipts. Requires Messages Read permission and macOS Full Disk Access. Plain and supported archived text are shown; unsupported formats and attachment content are explicitly unavailable, never presented as empty messages.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Maximum threads or messages to return (1-30, default 10); exact window counts are independent of this limit.")),
                        ("from_me", boolSchema("true: latest messages sent by you across all threads, newest first, with thread_id, named participants, date and text or attachment label. false: latest received messages. Omit to keep the conversation view. Cannot combine with thread_id, query, unread_only, sort, offset or before_message_id.")),
                        ("since", strSchema("Inclusive date window for from_me: local YYYY-MM-DD, ISO-8601 with time zone, or this week (start of the local calendar week). Returns exact sent_count for from_me:true or received_count for from_me:false over local message records, including attachments, reactions and special records.")),
                        ("offset", intSchema("Conversations to skip: next_offset from the previous page; omit initially.")),
                        ("unread_only", boolSchema("List only threads with unread incoming messages; default false. Omit for an exact thread read.")),
                        ("sort", enumStringSchema(["newest", "oldest_unread"], "Thread order; default newest. oldest_unread selects threads with unread incoming messages, earliest first, and includes oldest_unread_message_id, oldest_unread_date, oldest_unread_preview and its availability status. Omit for an exact thread read.")),
                        ("query", strSchema("A person (name, number or email) or words they wrote; lists only matching conversations.")),
                        ("thread_id", strSchema("Exact thread_id returned by this tool, to inspect that conversation.")),
                        ("before_message_id", intSchema("Older-page cursor returned as older_before_message_id. Requires the same exact thread_id; omit for recent messages.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "messages_send",
                description: "Sends a text message now (iMessage/SMS) to an explicit recipient, or sends a reply now to an exact observed Messages thread with its expected participants. Choose exactly one of to or thread_id. Requires Messages write authority.",
                parametersJSON: params(
                    properties: [
                        ("to", strSchema("Phone number or email for a new message (a name: find it with contacts_search). Omit when replying by thread_id.")),
                        ("thread_id", strSchema("Exact observed Messages thread. Requires expected_participants; do not use a thread ID as to.")),
                        ("expected_participants", stringArraySchema("Exact participant handles from the latest thread read, checked again before sending.")),
                        ("body", strSchema("Message body (required).")),
                    ],
                    required: ["body"]
                )
            ),
            requestedSchema(
                name: "notes_search",
                description: "Find and read Apple Notes: blank query lists recent notes, query matches title or text, title (exact) or id returns a body page. Each note reports truncated; continue with its id and next_body_offset as body_offset until false. Read-only; requires Notes → Read permission.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Words to find in titles or text; blank lists recent notes.")),
                        ("title", strSchema("Exact note title: returns a body page.")),
                        ("id", strSchema("A note's id from an earlier result: returns a body page of that exact note.")),
                        ("body_offset", intSchema("UTF-16 offset from next_body_offset; requires the same note id. Omit to read from the start.")),
                        ("limit", intSchema("Maximum notes to return (1-50, default 10).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "notes_create",
                description: "Create a new Apple Note with title + body, optionally in a named folder. Requires Notes → Write permission (off by default).",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Note title (required).")),
                        ("body", strSchema("Note body content (required).")),
                        ("folder", strSchema("Optional folder name; created in the default folder when omitted. A named folder that does not exist is an error listing the folders that do — it is never silently swapped for the default.")),
                    ],
                    required: ["title", "body"]
                )
            ),
            requestedSchema(
                name: "music_now_playing",
                description: "Report what Apple Music is currently playing (track title, artist, album, playback state). Read-only; requires Music → Read permission.",
                parametersJSON: params(
                    properties: [],
                    required: []
                )
            ),
            requestedSchema(
                name: "claude_message",
                description: "Send Claude (Claude Code on this Mac) a message; it lands in her inbox and she reads it in her live session. New work: conversation_mode=new, topic, no conversation_id. Follow-up: resume + her returned conversationId, no topic.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The message to the agent — full prose, no markdown headers needed. Be specific about the requested work or review.")),
                        ("priority", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("info"),
                                .string("important"),
                                .string("urgent"),
                            ])),
                            ("description", .string("Prominence: info=digest; important=highlighted; urgent=🚨 tag.")),
                        ])),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", strSchema("Short topic for new work, e.g. bug-music-tcc. On resume, omit or use the topic after claude: in conversation_id.")),
                        ("conversation_id", conversationReferenceSchema("claude", "claude_message")),
                        ("expects_reply", boolSchema("false for an FYI that needs no answer. Omit for questions and work.")),
                        ("pair_reviewer", boolSchema("true for implementation needing one paired reviewer: builder pairs at start, commits, supplies exact SHA for review, receives findings and owns fixes. Omit for notes/questions/review-only work.")),
                        ("desk_item", nonEmptyStringSchema("Omit unless copied exactly from a live desk_read number/handle in this conversation. Never invent/guess/reuse remembered IDs or placeholders ('none'). A live ID binds terminal execution/delivery evidence to that Desk item; nonlive IDs are ignored and delivery proceeds unbound.")),
                        ("working_directory", strSchema("Optional existing absolute project directory the work is about, noted in her inbox. Canonical workspace/source paths work normally; others require active Full Mac YOLO + allowed outside-workspace access.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "omp_message",
                description: "Send an asynchronous task to the local OMP CLI harness (Kimi K3). Set conversation_mode=new and omit conversation_id for unrelated work; set conversation_mode=resume and pass this tool's exact returned conversationId only for a contextual follow-up. A new coding conversation receives its own Git worktree and a resume reuses it. The final reply or honest failure/timeout receipt returns as an '[omp-wake] Automated completion event'.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The complete task or question for OMP.")),
                        ("priority", obj([
                            ("type", .string("string")),
                            ("enum", .array([.string("info"), .string("important"), .string("urgent")])),
                            ("description", .string("Receipt prominence.")),
                        ])),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", strSchema("Optional short stable topic for new work. Omit on resume; the conversationId already owns the topic.")),
                        ("conversation_id", conversationReferenceSchema("omp", "omp_message")),
                        ("desk_item", nonEmptyStringSchema("Omit unless copied exactly from a live desk_read number/handle in this conversation. Never invent/guess/reuse remembered IDs or placeholders ('none'). A live ID binds terminal execution/delivery evidence to that Desk item; nonlive IDs are ignored and delivery proceeds unbound.")),
                        ("working_directory", strSchema("Optional existing absolute project directory for a new OMP conversation. External paths require Full Mac YOLO with outside-workspace access allowed. Follow-ups always reuse their assigned private worktree; omit working_directory on a follow-up (a different value is ignored and noted on the receipt).")),
                        ("timeout_seconds", intSchema("OMP wall-clock guard, clamped 60-3600 seconds. Default 900.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "invoke_codex",
                description: "Invoke Codex as a blocking subprocess for a focused real-time question or short inspection. Use codex_message for builds, refactors, test suites, or anything likely to take more than a few minutes so the current chat stays responsive. Writes an audit envelope under data/from_codex/.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The question or task for Codex. Be specific; Codex is a fresh subprocess and only knows the context you provide.")),
                        ("context", strSchema("Optional preface: what you were doing, what failed, file paths, errors, and desired outcome.")),
                        ("cwd", strSchema("Working directory for Codex. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                        ("timeout_seconds", intSchema("Maximum blocking wait. Default 600 seconds. Prefer codex_message rather than raising this for long repo work.")),
                        ("commit_hash", strSchema("Optional git commit hash to anchor the context.")),
                        ("model", obj([
                            ("type", .string("string")),
                            ("enum", .array(OpenAIExecutionControls.codexBridgeModelIDs.map(JSONValue.string))),
                            ("description", .string("Optional per-call Codex model. Omit to inherit the active Codex CLI default.")),
                        ])),
                        ("reasoning_effort", obj([
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
                        ("fast", boolSchema("Optional per-call Fast mode. true selects Codex priority service; false explicitly selects default service; omit to inherit the Codex default.")),
                        ("sandbox", obj([
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
                description: "Send an asynchronous note/task to Codex. Set conversation_mode=new and omit conversation_id for unrelated work; set conversation_mode=resume and pass this tool's exact returned conversationId only for a contextual follow-up. A new coding conversation receives its own Git worktree and a resume reuses it. NativeAgent durably queues the task, starts or queues a Codex app-server turn, and returns Codex's final answer through the local bridge.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The message to Codex. Include enough context to be useful in a later Codex session.")),
                        ("priority", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("info"),
                                .string("important"),
                                .string("urgent"),
                            ])),
                            ("description", .string("How prominently to surface this in the Codex bridge inbox.")),
                        ])),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", strSchema("Optional short topic tag for new work. Omit on resume; the conversationId already owns the thread.")),
                        ("conversation_id", conversationReferenceSchema("codex", "codex_message")),
                        ("completion_mode", obj([
                            ("type", .string("string")),
                            ("enum", .array([.string("report"), .string("receipt_only")])),
                            ("description", .string("How Codex's terminal result returns. Use report for delegated work or a question whose answer the agent must assess. Use receipt_only for a one-way acknowledgment, status note, approval, or handoff that should settle durably without creating another chat turn. Defaults to report.")),
                        ])),
                        ("pair_reviewer", boolSchema("true for implementation needing one paired reviewer: builder pairs at start, commits, supplies exact SHA for review, receives findings and owns fixes. Omit for notes/questions/review-only work.")),
                        ("desk_item", nonEmptyStringSchema("Omit unless copied exactly from a live desk_read number/handle in this conversation. Never invent/guess/reuse remembered IDs or placeholders ('none'). A live ID binds terminal execution/delivery evidence to that Desk item; nonlive IDs are ignored and delivery proceeds unbound.")),
                        ("model", obj([
                            ("type", .string("string")),
                            ("enum", .array(OpenAIExecutionControls.codexBridgeModelIDs.map(JSONValue.string))),
                            ("description", .string("Optional model for this asynchronous Codex task. Omit to inherit the active Codex default.")),
                        ])),
                        ("reasoning_effort", obj([
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
                        ("fast", boolSchema("Optional Fast mode for this task. true selects Codex priority service; false selects default service.")),
                        ("working_directory", strSchema("Optional existing absolute project directory for a new Codex conversation. Canonical NativeAgent workspace/source paths work normally; any other directory requires active Full Mac YOLO with outside-workspace access allowed. Follow-ups always reuse their assigned private worktree; omit working_directory on a follow-up (a different value is ignored and noted on the receipt).")),
                        ("repository", strSchema("New work only: optional GitHub repository as 'owner/name' (never a filesystem path). NativeAgent resolves it to a local clone whose git remote actually points at that repository and runs Codex there with repository network access. Omit or send an empty string on resume because the saved conversation owns its checkout; any repository hint on a resume is ignored. An unknown repository is ignored rather than failing the send.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "music_control",
                description: "Play, pause or skip in Apple Music, or play a playlist or song by name in one call (playlist / track). Returns what is playing after. Requires Music → Write permission.",
                parametersJSON: params(
                    properties: [
                        ("action", obj([
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
                        ("playlist", strSchema("Playlist name to play.")),
                        ("track", strSchema("Exact song name to play; several with that name play nothing and are listed.")),
                        ("artist", strSchema("Artist, to pick among songs with the same name.")),
                    ],
                    required: []
                )
            ),
            // Sensitive writes default off; scheduler.write defaults on with no read axis.
            requestedSchema(
                name: "mac_calendar_create_event",
                description: "Create a local Calendar entry via EventKit; this does not send invitations. With full access, choose an explicit destination; with write-only access, omit calendar_id and calendar_name to use the system default. For meetings with attendees use google_calendar_send_invitations. Requires Calendar Write permission. start/end accept ISO-8601 or epoch seconds.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Event title (required).")),
                        ("start", stringOrIntSchema("Start time — ISO-8601 string (e.g. '2026-06-07T15:00:00Z') or integer epoch seconds (required).")),
                        ("end", stringOrIntSchema("Optional end time — ISO-8601 string or integer epoch seconds. Defaults to start + 1 hour.")),
                        ("notes", strSchema("Optional notes / description.")),
                        ("location", strSchema("Optional location string.")),
                        ("calendar_name", strSchema("Unique exact calendar name, only when calendar_id is omitted; ambiguous names fail.")),
                        ("calendar_id", strSchema("Explicit EventKit calendar ID from mac_calendar_calendars. Required with full access unless a unique exact calendar_name is supplied. With write-only access, omit calendar_id and calendar_name to use the system default.")),
                    ],
                    required: ["title", "start"]
                )
            ),
            requestedSchema(
                name: "mac_calendar_modify_event",
                description: "Modify an existing calendar event. Requires id from a prior mac_calendar_list_upcoming. Pass only the fields to change. Requires Calendar → Write permission.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("EKEvent identifier from mac_calendar_list_upcoming (required).")),
                        ("title", strSchema("New event title.")),
                        ("start", stringOrIntSchema("New start time — ISO-8601 string or epoch seconds.")),
                        ("end", stringOrIntSchema("New end time — ISO-8601 string or epoch seconds.")),
                        ("notes", strSchema("New notes/body text.")),
                        ("location", strSchema("New location.")),
                        ("clear_fields", obj([("type", .string("array")), ("items", enumStringSchema(["notes", "location"])),
                            ("description", .string("Fields to empty on the event. A field also given a value keeps that value."))])),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "mac_calendar_delete_event",
                description: "Delete exactly one calendar event occurrence by id from mac_calendar_list_upcoming. Requires the observed title and start as preconditions; a changed event is not deleted. Never deletes a recurring series. Requires Calendar → Write and EventKit full access. Use only for an explicitly requested deletion.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("Exact EKEvent identifier from mac_calendar_list_upcoming.")),
                        ("expected_title", strSchema("Exact title observed for this event.")),
                        ("expected_start", stringOrIntSchema("Observed start time, ISO-8601 or epoch seconds.")),
                    ],
                    required: ["id", "expected_title", "expected_start"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_create",
                description: "Create a new reminder in the user's Mac Reminders via EventKit. Requires Reminders -> Write permission (off by default).",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("Reminder title (required).")),
                        ("notes", strSchema("Optional notes.")),
                        ("due_date", stringOrIntSchema("Optional due date — ISO-8601 string or integer epoch seconds.")),
                        ("list_name", strSchema("Optional list name — defaults to the default list when omitted.")),
                    ],
                    required: ["title"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_list_rename",
                description: "Rename exactly one Mac Reminders list via EventKit and read back its saved name. Matches names ignoring case and whitespace; emoji and variation selectors are significant. Refuses ambiguous or read-only lists and duplicate destination names. Requires Reminders → Write permission.",
                parametersJSON: params(
                    properties: [
                        ("list", strSchema("Exact existing Reminders list name.")),
                        ("new_name", strSchema("New nonempty, unique list name.")),
                    ],
                    required: ["list", "new_name"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_list_create",
                description: "Create a Mac Reminders list via EventKit in the default reminder list's account and read back its saved name. Refuses duplicate names or an unavailable or read-only default list. Requires Reminders → Write permission.",
                parametersJSON: params(
                    properties: [("name", strSchema("Nonempty, unique name for the new Reminders list."))],
                    required: ["name"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_update",
                description: "Update exactly one Mac Reminder by id. Change only supplied title, notes or due_date; preserves its list and completion. Requires Reminders → Write permission.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("Exact reminder id from a reminder query, read or creation.")),
                        ("title", strSchema("New nonempty title; omitted leaves it unchanged.")),
                        ("notes", strSchema("New notes; omitted leaves them unchanged. Use clear_fields to remove them.")),
                        ("due_date", stringOrIntSchema("New due date: ISO-8601, local YYYY-MM-DD, or epoch seconds; omitted leaves it unchanged. Use clear_fields to remove it.")),
                        ("clear_fields", obj([("type", .string("array")), ("items", enumStringSchema(["notes", "due_date"])),
                            ("description", .string("Fields to clear: notes or due_date. Do not also supply a value for a cleared field."))])),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "mac_reminders_complete",
                description: "Mark a Mac Reminder done by its title (or id from mac_reminders_list_due_today). Requires Reminders → Write permission.",
                parametersJSON: params(
                    properties: [
                        ("title", strSchema("The reminder's exact title (case aside).")),
                        ("id", strSchema("Reminder id from mac_reminders_list_due_today, when known.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mac_reminders_delete",
                description: "Delete exactly one Mac Reminder by id from mac_reminders_create or mac_reminders_list_due_today. Requires its observed title as a precondition; a changed reminder is not deleted. Requires Reminders → Write permission. Use only for an explicitly requested deletion.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("Exact reminder id from mac_reminders_create or mac_reminders_list_due_today.")),
                        ("expected_title", strSchema("Exact title observed for this reminder.")),
                    ],
                    required: ["id", "expected_title"]
                )
            ),
            requestedSchema(
                name: "mail_mark_read",
                description: "Mark read a selected inbox result set: pass messages from mail.search (1–50) as the only argument. Returns per-message receipts; partial or uncertain work is explicit. If unread search has_more, repeat the same search without offset after marking, since the result set shrinks. Also accepts one exact locator or every message with a subject. Requires Mail → Write permission.",
                parametersJSON: params(
                    properties: [
                        ("messages", mailBatchItemsSchema(effects: true, markReadOnly: true)),
                        ("message_id", intSchema("Inbox message_id from mail_list_recent.")),
                        ("expected_message_id", strSchema("expected_message_id from the same row.")),
                        ("expected_account", strSchema("expected_account from the same row, when it has one.")),
                        ("position", intSchema("position from the same row: finds the message fast.")),
                        ("subject", strSchema("Or the message's subject, when there's no message_id.")),
                        ("sender", strSchema("Optional sender filter with subject.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_archive",
                description: "Archive one inbox message by message_id + expected_message_id from mail_list_recent, or a subject only one message has. Requires Mail → Write permission.",
                parametersJSON: params(
                    properties: [
                        ("message_id", intSchema("Inbox message_id from mail_list_recent.")),
                        ("expected_message_id", strSchema("expected_message_id from the same row.")),
                        ("expected_account", strSchema("expected_account from the same row, when it has one.")),
                        ("position", intSchema("position from the same row: finds the message fast.")),
                        ("subject", strSchema("Or the message's subject, when there's no message_id.")),
                        ("sender", strSchema("Optional sender filter with subject.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_delete",
                description: "Move one message to its account's Trash, including archived mail, by message_id + expected_message_id from a prior read, or a subject only one indexed message has. Rechecks identity in its current mailbox. Never permanently deletes. Requires Mail → Write permission and the existing approval policy.",
                parametersJSON: params(
                    properties: [
                        ("message_id", intSchema("Message_id from a prior Mail read; the message may have been archived since that read.")),
                        ("expected_message_id", strSchema("expected_message_id from the same row.")),
                        ("expected_account", strSchema("expected_account from the same row, when it has one.")),
                        ("position", intSchema("Optional prior position hint; deletion locates the current mailbox by indexed identity.")),
                        ("subject", strSchema("Or the message's subject, when there's no message_id.")),
                        ("sender", strSchema("Optional sender filter with subject.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "mail_reply",
                description: "Sends a reply now to an exact inbox message_id plus expected_message_id, or a uniquely matching subject (and optional sender). Ambiguous or changed targets are refused. Requires Mail → Write permission (off by default).",
                parametersJSON: params(properties: mailReplyFields, required: ["body"])
            ),
            requestedSchema(
                name: "mail_draft",
                description: "Saves an unsent email in Apple Mail → Drafts, without sending or opening a window. Use for draft, don't send, just draft, save as draft or not yet requests. For a reply, use an exact inbox message_id plus expected_message_id, or a uniquely matching subject (and optional sender); ambiguous or changed targets are refused. For a new email, supply to, subject and body instead. Requires Mail Write permission. Returns saved_in and draft_id.",
                parametersJSON: params(properties: mailReplyFields + [
                    ("to", stringOrStringArraySchema("Recipient address(es) for a new draft. Omit for a reply draft.")),
                    ("cc", stringOrStringArraySchema("Optional CC recipient(s) for a new draft.")),
                    ("bcc", stringOrStringArraySchema("Optional BCC recipient(s) for a new draft.")),
                ], required: ["body"])
            ),
            requestedSchema(
                name: "notes_update",
                description: "Update one Apple Note by id (from notes_search) or a title only one note has — set the body, append to the body, or rename it. At least one of 'body', 'append', or 'new_title' must be provided. Requires Notes → Write permission (off by default).",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("The note's id from notes_search; use it when two notes share a title.")),
                        ("title", strSchema("Exact title of the note to update (as notes_search shows it).")),
                        ("body", strSchema("Replace the note's text under its title; the title stays unless new_title is given.")),
                        ("append", strSchema("Add this as a new line at the end of the note.")),
                        ("new_title", strSchema("Rename the note to this title.")),
                        ("clear_fields", obj([("type", .string("array")), ("items", enumStringSchema(["body"])),
                            ("description", .string("[\"body\"] empties the note's body. Not with body or append."))])),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "notes_delete",
                description: "Delete one Apple Note by id or an exact title only one note has. Moves it to Recently Deleted, where it can be restored; returns that reversible outcome. Requires Notes → Write permission (off by default).",
                parametersJSON: params(properties: [
                    ("id", strSchema("The note's id from notes_search; use it when two notes share a title.")),
                    ("title", strSchema("Exact title of the note to delete; duplicate titles refuse without changing anything.")),
                ], required: [])
            ),
            requestedSchema(
                name: "music_search_library",
                description: "Search the user's Apple Music library by query, returning matching tracks, artists, or albums. Read-only; requires Music -> Read permission.",
                parametersJSON: params(
                    properties: [
                        ("query", strSchema("Search string (required).")),
                        ("kind", obj([
                            ("type", .string("string")),
                            ("enum", .array([
                                .string("track"),
                                .string("artist"),
                                .string("album"),
                            ])),
                            ("description", .string("What to search for — one of track / artist / album. Defaults to track.")),
                        ])),
                        ("limit", intSchema("Maximum results to return (1-100, default 20).")),
                    ],
                    required: ["query"]
                )
            ),
            requestedSchema(
                name: "music_list_library",
                description: "Page through the user's Apple Music library tracks without a search query. Read-only; requires Music -> Read permission. Use offset + limit to browse large libraries safely.",
                parametersJSON: params(
                    properties: [
                        ("offset", intSchema("Zero-based track offset. Defaults to 0.")),
                        ("limit", intSchema("Maximum tracks to return (1-100, default 50).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "music_list_playlists",
                description: "Page through the user's Apple Music playlists, returning names and track counts. Read-only; requires Music -> Read permission.",
                parametersJSON: params(
                    properties: [
                        ("offset", intSchema("Zero-based playlist offset. Defaults to 0.")),
                        ("limit", intSchema("Maximum playlists to return (1-100, default 50).")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "contacts_delete",
                description: "Delete a Mac contact by its identifier from contacts_search or its exact full name. Requires Contacts -> Write permission.",
                parametersJSON: params(
                    properties: [
                        ("identifier", strSchema("identifier from contacts_search, or the exact full name.")),
                    ],
                    required: ["identifier"]
                )
            ),
            requestedSchema(
                name: "scheduler_list_jobs",
                description: "List queued and scheduled TriggerScheduler jobs (id, title, action_id, trigger time, status). Requires Scheduler → Write permission (scheduler has no read axis; defaults on).",
                parametersJSON: params(
                    properties: [],
                    required: []
                )
            ),
            requestedSchema(
                name: "scheduler_create_job",
                description: "Run a task every day/morning with kind workshop, or schedule a notification with kind notify. Supply kind, its payload, and either schedule or interval_seconds. kind: notify, connector_action, dream, rem, improve, harness_benchmark, proactive_scan or workshop. notify requires payload.message; connector_action requires payload.actionId; workshop requires payload.objective, including how to deliver the result. Workshop queues a Desk task each time; scheduling is not completion. For a standing helper's recurring job use bot_create or bot_update with schedule or cadence. schedule accepts an ISO-8601 datetime string or a schedule object; repeating intervals have a 60-second floor. A repeating dream reuses the one nightly reflection job, reactivating it if cancelled, instead of adding another; a once schedule adds one extra dream. Requires Scheduler → Write permission (defaults on). Notification example: {\"kind\":\"notify\",\"payload\":{\"title\":\"Reminder\",\"message\":\"Review the notes.\"},\"interval_seconds\":86400}.",
                parametersJSON: params(
                    properties: [
                        ("kind", enumStringSchema(["notify", "connector_action", "dream", "rem", "improve", "harness_benchmark", "proactive_scan", "workshop"], "Use workshop to do work on each run; notify delivers a fixed message.")),
                        ("payload", nullableRecallField(looseObjectSchema("Per-kind parameters. workshop: {title, objective}; include result delivery instructions in objective. notify: {title, message, delivery}; delivery selects notification channels only. connector_action requires actionId; input is optional. improve/dream/rem accept objective; proactive_scan accepts reason and limit."))),
                        ("in_minutes", nullableRecallField(numSchema("One-time delay from now in minutes, e.g. 10 for a ten-minute timer. Use kind notify and payload.message. Supply this alone instead of schedule or interval_seconds; no time.now call is needed."))),
                        ("schedule", stringOrLooseObjectSchema("When to fire. Supply this, in_minutes or interval_seconds; omit or null unused fields. ISO-8601 datetime, 'in 10 minutes', or object with type once/every/hourly/daily/weekly/monthly/cron. Cron accepts expression or cron. Calendar schedules persist this Mac's current zone when timezone is omitted. Set another zone only when the person explicitly requested it; never copy a zone from older jobs or context. Example: {\"type\":\"every\",\"interval_seconds\":86400}.")),
                        ("interval_seconds", nullableRecallField(intSchema("Repeating interval in seconds when schedule is omitted or null. Example: 86400.", minimum: 60))),
                    ],
                    required: ["kind"]
                )
            ),
            requestedSchema(
                name: "scheduler_cancel_job",
                description: "Cancel a reminder or scheduled job by id from scheduler_list_jobs. Stops future runs and keeps the job in history; scheduler_resume_job can re-enable it. For a temporary stop, use scheduler_pause_job. Does not stop an already running action. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: params(
                    properties: [("job_id", strSchema("Exact job id from scheduler_list_jobs."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(
                name: "scheduler_delete_job",
                description: "Delete a scheduled job or reminder from active scheduling by cancelling it. Same as scheduler_cancel_job: keeps the job in history, can be resumed, and does not stop an already running action. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: params(
                    properties: [("job_id", strSchema("Exact job id from scheduler_list_jobs."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(
                name: "scheduler_pause_job",
                description: "Pause a job or reminder by id from scheduler_list_jobs. Stops future runs until scheduler_resume_job; preserves its schedule and payload. Does not stop an already running action. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: params(
                    properties: [("job_id", strSchema("Exact job id from scheduler_list_jobs."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(
                name: "scheduler_resume_job",
                description: "Resume a paused or cancelled scheduled job or reminder by id from scheduler_list_jobs. Re-enables its saved schedule; an overdue job may run immediately. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: params(
                    properties: [("job_id", strSchema("Exact job id from scheduler_list_jobs."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(
                name: "scheduler_update_job",
                description: "Edit a scheduled job using job_id from scheduler_list_jobs and at least one top-level change: name, kind, payload, schedule or interval_seconds. Omit or null unused fields; do not wrap changes in fields. Changing kind requires its complete payload. Supply schedule or interval_seconds, never both; intervals must be integers of at least 60 seconds. Preserves identity, history and paused/cancelled state. A new schedule recalculates the next run; other edits keep it. Does not alter an already running action. Requires Scheduler → Write permission (defaults on). Example for an existing job: {\"job_id\":\"J\",\"schedule\":{\"type\":\"daily\",\"at\":\"09:00\",\"timezone\":\"America/Denver\"}}.",
                parametersJSON: params(
                    properties: [
                        ("job_id", strSchema("Exact job id from scheduler_list_jobs.")),
                        ("name", nullableRecallField(strSchema("New job name (1-160 characters)."))),
                        ("kind", nullableEnumStringSchema(["notify", "connector_action", "dream", "rem", "improve", "harness_benchmark", "proactive_scan", "workshop"], "When changing kind, supply the complete payload for that kind. Example: \"notify\".")),
                        ("payload", nullableRecallField(looseObjectSchema("Changed per-kind parameters, merged into the existing payload unless kind changes. notify: {title, message, delivery}. connector_action: {actionId, input}. Nested values such as input are replaced in full."))),
                        ("schedule", stringOrLooseObjectSchema("Complete replacement schedule: ISO-8601 datetime string, e.g. '2026-09-29T09:00:00-06:00', or {type:'once', at:'ISO-8601'}, {type:'every', interval_seconds:3600}, {type:'hourly', minute:0}, {type:'daily', at:'09:00'}, {type:'weekly', weekdays:['mon'], at:'09:00'}, {type:'monthly', day:1, at:'09:00'}, or {type:'cron', expression:'0 9 * * mon-fri'}. Optional timezone for object schedules, e.g. America/Denver. Omit interval_seconds when supplying schedule.")),
                        ("interval_seconds", nullableRecallField(intSchema("Replace the schedule with a repeating interval of at least 60 seconds. Supply this or schedule, not both.", minimum: 60))),
                    ],
                    required: ["job_id"]
                )
            ),
            // Memory writes belong to the agent's own store, so they remain available
            // independently of Full Mac file access.
            requestedSchema(
                name: "commit_memory",
                description: "Save a fact, decision or preference for later recall. Put the current decision first and preserve its qualifications; keep incident history after it. For a changed operating agreement, recall the existing rules for that subject and explicitly name replaced ids in supersedes. context_topics declares the agreement's subject/scope, not authority. text: the thing itself, plain; no dates, sources, ids or 'note:' framing. Example: {\"text\":\"Sam drinks coffee black\"}.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("Required nonblank fact/decision/preference. Put the complete operative decision first; keep incident history after it, without shortening the decision or losing qualifications. No date/time/source/id/hash/'record of' preamble; use their own fields. Whitespace-only is rejected.")),
                        ("provenance", enumStringSchema(["verified", "told", "inferred"], "How you know this: verified (you checked it yourself), told (someone told you — also set provenance_by), inferred (you worked it out).")),
                        ("provenance_by", strSchema("Who told you, when provenance=told. A name, e.g. \"Sam\".")),
                        ("source", strSchema("Alias of provenance_by: who told you, when provenance=told. Prefer provenance_by if supplying both.")),
                        ("kind", strSchema("Memory kind, e.g. identity/preference/relationship/goal/skill/project/general, or \"moment\" for something you lived and want to keep (first person, say what happened and what it meant). Default \"note\".")),
                        ("valence", numSchema("How it felt, -1 (bad) to 1 (good). Use with kind \"moment\".")),
                        ("tags", stringArraySchema("Optional free-form tags.")),
                        ("confidence", numSchema("How confident this fact is true, 0..1. Default 0.8.")),
                        ("importance", numSchema("How important this fact is to retain, 0..1. Default 0.5.")),
                        ("corrects", strSchema("Optional id of an existing memory this new fact corrects (e.g. from recall_memory). The old memory is marked lifecycle=corrected with a lineage link to this one and drops out of recall.")),
                        ("supersedes", stringArraySchema("Optional memory ids this replaces; kept in history, excluded from recall.")),
                        ("correction_reason", strSchema("Optional one-line reason the old memory was wrong (stored on the corrected row's lineage).")),
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
                description: "Run a user-directed task from the Desk. For an exact workspace file copy, set operation=copy_workspace_file with source and destination. An active reviewed copy procedure runs directly; otherwise the task follows normal planning and approval. Use procedure=local_file_copy_v1 only for explicit/manual compatibility. Every other objective creates a user-directed Desk task, unless desk_handle names an existing live Desk item to run — then the project keeps its own identity instead of gaining a second one. Returns Desk identity and execution status; use workshop_status to follow queued work.",
                parametersJSON: params(
                    properties: [
                        ("text", strSchema("The task objective — what the user wants done (required).")),
                        ("expected_outputs", stringArraySchema("Optional exact phrases that must occur in completed text outputs, e.g. [\"12\"] for arithmetic synthesis. Ordinary tasks only: omit operation and procedure. This verifies text containment, not external effects; omit when no exact text criterion is known.")),
                        ("context", strSchema("Optional short title/context. Defaults to a prefix of the objective.")),
                        ("desk_handle", strSchema("Optional live Desk handle or visible alias to execute as — use it when this work is the next piece of a project already on the Desk (name the relevant child, not the whole project, so finishing it does not close everything). Omit to create a new Desk task.")),
                        ("operation", enumStringSchema(["copy_workspace_file"], "Stable exact operation. Use copy_workspace_file only for an unambiguous byte-for-byte workspace file copy and also provide source and destination. The procedure store chooses an active reviewed implementation; omit for every other task.")),
                        ("procedure", enumStringSchema(["local_file_copy_v1"], "Optional native procedure. Use the only allowed value, local_file_copy_v1, for a byte-for-byte workspace file copy and also provide source and destination. Omit for every other task.")),
                        ("source", strSchema("Source path relative to NativeAgent's workspace, without a leading slash. Used only with the exact copy operation/procedure.")),
                        ("destination", strSchema("Destination path relative to NativeAgent's workspace, without a leading slash. Used only with the exact copy operation/procedure.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(
                name: "workshop_status",
                description: "Read task progress in the Desk. Without an id: list active and recent work. With an execution id: return detail and step receipts. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("Optional execution id. Omit to list active and recent Desk tasks.")),
                    ],
                    required: []
                )
            ),
            // Lazy-loaded task ledger tools share the bridge feed and its file lock.
            // Posts are actor-pinned; task_ledger_list is a read.
            requestedSchema(
                name: "task_ledger_post",
                description: "Post an event to the cross-agent task ledger: the shared who-owns-what/done/blocked feed for the agent, Codex, and the assistant. Use it to open a task (kind=created), claim one (kind=claimed), log progress (kind=update), flag a blocker (kind=blocked), close it (kind=done/cancelled), or remove it from task views (kind=deleted, with exact task_id and expected_title). Events post as the assistant. Returns the event and its task_id. Use task_ledger_list to see the current state.",
                parametersJSON: params(
                    properties: [
                        ("kind", enumStringSchema(["created", "claimed", "update", "blocked", "done", "cancelled", "deleted"], "Event kind: created | claimed | update | blocked | done | cancelled | deleted.")),
                        ("task_id", strSchema("The task this event belongs to. Required for everything except 'created' (omit on created to mint a new task id).")),
                        ("title", strSchema("Short task title (set on created; updates the title if provided later).")),
                        ("expected_title", strSchema("For deleted: exact current title from task_ledger_list. The task stays in the audit feed but leaves task views.")),
                        ("note", strSchema("Optional free-text note for this event (what happened, why blocked, etc.).")),
                        ("refs", stringArraySchema("Optional reference strings — file paths, commit ids, PR urls.")),
                    ],
                    required: ["kind"]
                )
            ),
            // Lazy-loaded local read of durable delegation jobs; no spawn or network.
            requestedSchema(
                name: "delegation_status",
                description: "Read advanced bridge/swarm evidence. Prefer agent_read for ordinary agent replies: both use this same retained bridge evidence, so calling both is not independent confirmation. By default lists bridge jobs for the agent (Claude Code), Codex, and OMP with real lifecycle timestamps and current-build delivery uncertainty. Set message_id to the exact accepted messageId to find its recorded work, including batched Codex jobs. For a native swarm, set agent='swarm' and its exact run_id: returns compact report descriptors; select report_id to page one retained worker/synthesis report, never rerunning work. Discarded original text is not recoverable. Bridge stall_basis='none' means unmeasurable, not verified healthy.",
                parametersJSON: params(
                    properties: [
                        ("limit", intSchema("Bridge jobs per page: default 8, max 12. With agent='swarm' and report_id: retained text characters per page, default/max 2000.")),
                        ("offset", intSchema("Bridge result offset, or character offset within the selected swarm report. Follow next_offset; omit on first page.")),
                        ("agent", strSchema("Optional bridge filter: claude, codex, omp/kimi. Omit for all bridges. Set swarm with exact run_id to inspect a native swarm receipt.")),
                        ("message_id", obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Bridge mode only: exact accepted messageId from claude.say, codex_message, or omp_message, up to 160 characters. Filters recorded identities before paging; never matches topic or filename. Omit, null, or empty for ordinary listing. Missing evidence does not prove work never ran.")),
                        ])),
                        ("run_id", strSchema("Required only for agent='swarm': exact id returned by agent_swarm. This is an identifier, never a file path.")),
                        ("report_id", obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("For agent='swarm': exact worker report_id from descriptors, or synthesis. Omit, null, or empty for metadata only; provide to page retained output/error text.")),
                        ])),
                        ("detail", strSchema("Bridge compact (default) or full lifecycle metadata. Native swarm bodies require report_id; full alone still returns only compact descriptors.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "task_ledger_list",
                description: "List the cross-agent task ledger — the shared who-owns-what/done/blocked state for the agent, Codex, and you. Without a task_id: the compacted per-task summary (owner, status, last note), newest-updated first. With a task_id: that task's full event timeline. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("task_id", strSchema("Optional task id. Omit to list all tasks; provide to get one task's event timeline.")),
                        ("include_done", boolSchema("Include done/cancelled tasks in the list. Default false (open tasks only).")),
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
                description: Self.innerStateToolDescription,
                parametersJSON: params(
                    properties: [
                        ("window_hours", numSchema(
                            "How many hours of felt moments to include. 1–168; out-of-range values clamp, and the result says so: window_hours_requested, window_hours_applied and a note naming the cap. Default 6.",
                            minimum: 1,
                            maximum: 168
                        )),
                        ("detail", enumStringSchema(
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
                description: "Read your durable, compact Desk: user-tracked watches/plans/projects/GitHub items/standing concerns, status, cadence and key refs. Numbers are permanent. Default: capped open items, most recently active first, with omissions stated. handle (stable or visible alias) also returns one exact live item's full summary, refs, dependencies/blockees, parts and ordered notes. query searches title/summary/project/alias/handle across the full live store. include_archived appends closed-out archived items. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("include_archived", boolSchema("Also read archived items matching the same handle or query, in bounded text windows. Exact archived reads require the stable handle. Default false.")),
                        ("archived_offset", intSchema("Archived text continuation: copy from next_archive_read; omit initially.")),
                        ("handle", strSchema("Optional exact live Desk handle or visible alias; returns that item's full record (notes, refs, dependencies) as well as the board. Mutually exclusive with query.")),
                        ("query", strSchema("Optional case-insensitive text search across the full live Desk. Mutually exclusive with handle; returns at most 25 matches.")),
                        ("updated_on", strSchema("Filter items updated on today or YYYY-MM-DD in the Mac's local timezone. With include_archived, filters archives by their closed date. Can combine with query.")),
                        ("structured", boolSchema("Return selectable canonical rows and evidence, with bounded page continuations. Used by workspace; default false retains the rendered board.")),
                        ("sort", strSchema("Set \"stale\" to list ALL open top-level items oldest-touched first as lean rows (id = desk number, title, status, updated date) for triage. Ignored with handle or query.")),
                        ("offset", intSchema("Structured view continuation: row offset; omit initially.")),
                        ("notes_offset", intSchema("Structured selected-record continuation: note offset; omit initially.")),
                        ("refs_offset", intSchema("Structured selected-record continuation: linked-evidence offset; omit initially.")),
                        ("detail_offset", intSchema("Read a bounded window of the complete selected record, including full notes. Omit for the selectable overview; start at zero.")),
                        ("detail_version", strSchema("Exact complete-record version returned by the owner. Required for a nonzero detail_offset; changed records must restart.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "desk_add_item",
                description: "Add a Desk item: kind=watch|plan|project|gh|standing, project bucket and short title; optional parent nesting. For delegation, set assignee and lane_of (coordinating Desk item) as fields, not prose. A live same-title/project/parent item returns disposition=existing; allow_duplicate=true is only for intentional equivalents. Returns status=ok, created, disposition, stable handle and view alias (\"2\", \"2.1\").",
                parametersJSON: params(
                    properties: [
                        ("kind", enumStringSchema(["watch", "plan", "project", "gh", "standing"], "Item kind: watch | plan | project | gh | standing.")),
                        ("project", strSchema("Project bucket this item belongs to.")),
                        ("title", strSchema("Short item title.")),
                        ("until", strSchema("Optional yyyy-MM-dd or ISO timestamp to defer the item in this same add call.")),
                        ("defer", strSchema("Alias for until; if both are supplied, they must agree.")),
                        ("parent", strSchema("Optional parent item handle to nest this item under.")),
                        ("summary", strSchema("Optional one-line summary. Desk has no priority field; offer a searchable tag here, then use desk.read query to find it.")),
                        ("assignee", strSchema("Optional freeform delegation assignee, such as the coding agent.")),
                        ("lane_of", strSchema("Optional coordinating Desk item handle (or visible alias) for this delegated task. This link does not change Desk hierarchy.")),
                        ("allow_duplicate", boolSchema("Explicitly create a second equivalent live item instead of reusing the existing owner. Default false.")),
                    ],
                    required: ["kind", "project", "title"]
                )
            ),
            requestedSchema(
                name: "desk_set_status",
                description: "Set Desk status: watch|flag|now|next|todo|done|blocked|canceled (US spelling). Fresh canonical evidence resolving the exact tracked defect/outcome requires updating that item in the same turn. Never close from fuzzy titles, execution completion alone or unattributed commits. blocked requires a reason via blocked_reason, reason, or status='blocked: reason', and/or waiting_on. Delegation assignments/updates include assignee and lane_of; omitted metadata stays unchanged. Report concrete batch progress as progress={done,total,note?}; omit when unknown, never invent 0%. Returns refreshed alias, status and title.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("status", strSchema("New status: watch | flag | now | next | todo | done | blocked | canceled. Also accepts 'blocked: reason' and stores the reason in the Desk's blocked reason field.")),
                        ("remaining_work", obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional exact remaining authorized work. Attach a durable continuation to this existing task before starting a long job; settled calls and pending effects survive turn limits and restart. Never repeat an uncertain effect; verify it through its domain first. Omit or send null when only tracking status.")),
                        ])),
                        ("blocked_reason", strSchema("Why it's blocked (when status=blocked).")),
                        ("reason", strSchema("Alias for blocked_reason. If both are supplied, they must agree.")),
                        ("waiting_on", strSchema("Who it's waiting on (when status=blocked); owner pushes the person.")),
                        ("assignee", obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional assignee update; omitted/null/blank preserves it. Cannot clear assignments.")),
                        ])),
                        ("lane_of", obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional live coordinating Desk handle/alias for this delegation. Omitted/null/blank preserves the link; cannot clear it. Send null if unchanged; never the item's own handle.")),
                        ])),
                        ("progress", obj([
                            ("type", .array([.string("object"), .string("null")])),
                            ("description", .string("Optional explicit progress. Requires 0 <= done <= total and total > 0; omit or send null when unknown.")),
                            ("properties", obj([
                                ("done", intSchema("Completed units.")),
                                ("total", intSchema("Total units; must be greater than zero.")),
                                ("note", strSchema("Optional concise progress note.")),
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
                description: "Update a Desk item's title and/or summary. Provide at least one of title/summary. Desk has no priority field; offer a searchable tag in summary and use desk.read query to find it.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("title", strSchema("New title (optional).")),
                        ("summary", strSchema("New one-line summary (optional).")),
                    ],
                    required: ["handle"]
                )
            ),
            requestedSchema(
                name: "desk_note",
                description: "Append a timestamped note to a Desk item — progress, context, a decision.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("text", strSchema("The note text.")),
                    ],
                    required: ["handle", "text"]
                )
            ),
            requestedSchema(
                name: "desk_add_ref",
                description: "Attach a reference to a Desk item. ref_kind selects the shape and which fields apply: file (path[,line,label]) | commit (sha[,repo,label,status]) | gh_issue (repo,number[,title,status]) | gh_pr (repo,number[,title,status,checks]) | url (url[,title]) | agent (name[,handoff_id,session_id]) | approval (id[,status]) | trace (id[,trace_kind]) | note (text).",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("ref_kind", enumStringSchema(["file", "commit", "gh_issue", "gh_pr", "url", "agent", "approval", "trace", "note"], "file | commit | gh_issue | gh_pr | url | agent | approval | trace | note.")),
                        ("path", strSchema("file: path.")),
                        ("line", intSchema("file: optional line number.")),
                        ("label", strSchema("file/commit: optional label.")),
                        ("sha", strSchema("commit: commit sha.")),
                        ("repo", strSchema("commit/gh_issue/gh_pr: repository.")),
                        ("number", intSchema("gh_issue/gh_pr: issue/PR number.")),
                        ("title", strSchema("gh_issue/gh_pr/url: optional title.")),
                        ("status", strSchema("commit/gh_issue/gh_pr/approval: optional status.")),
                        ("checks", strSchema("gh_pr: optional CI checks summary.")),
                        ("url", strSchema("url: the URL.")),
                        ("name", strSchema("agent: agent name.")),
                        ("handoff_id", strSchema("agent: optional handoff id.")),
                        ("session_id", strSchema("agent: optional session id.")),
                        ("id", strSchema("approval/trace: the id.")),
                        ("trace_kind", strSchema("trace: optional trace kind.")),
                        ("text", strSchema("note: the note text.")),
                    ],
                    required: ["handle", "ref_kind"]
                )
            ),
            requestedSchema(
                name: "desk_set_cadence",
                description: "Set how often you refresh a Desk item. mode: manual | on_ask | tick | event | daily | weekly | blocked_watch. Optionally set interval, stale_after, and refresh_sources (comma-separated).",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("mode", enumStringSchema(["manual", "on_ask", "tick", "event", "daily", "weekly", "blocked_watch"], "manual | on_ask | tick | event | daily | weekly | blocked_watch.")),
                        ("interval", strSchema("Optional refresh interval (e.g. \"1h\", \"1d\").")),
                        ("stale_after", strSchema("Optional staleness window after which the item is considered stale.")),
                        ("refresh_sources", strSchema("Optional comma-separated list of refresh sources.")),
                    ],
                    required: ["handle", "mode"]
                )
            ),
            requestedSchema(
                name: "desk_set_notify",
                description: "Set when a Desk item should surface to the user. level: quiet | digest | direct | urgent. Optionally set on (comma-separated triggers: state_change | blocked | done | explicit) and a cooldown. Use explicit alone for a one-time announcement.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("level", enumStringSchema(["quiet", "digest", "direct", "urgent"], "quiet | digest | direct | urgent.")),
                        ("on", strSchema("Optional comma-separated triggers: state_change | blocked | done | explicit. Use explicit alone for a one-time announcement.")),
                        ("cooldown", strSchema("Optional notify cooldown (e.g. \"6h\").")),
                    ],
                    required: ["handle", "level"]
                )
            ),
            requestedSchema(
                name: "desk_close",
                description: "Close an exact Desk item when the owner explicitly asks to close or mark it done, or fresh canonical evidence proves its tracked outcome. The owner's explicit instruction is sufficient even if earlier notes say work remains; record that instruction in outcome_summary without claiming the underlying work happened. Otherwise put the specific commit/receipt/observed result in outcome_summary; never use fuzzy title matches, execution completion alone or unattributed commits. Sets done (canceled if canceled=true); stays visible briefly, then becomes archive-eligible.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("outcome_summary", strSchema("What the outcome was.")),
                        ("canceled", boolSchema("Close as canceled instead of done. Default false.")),
                        ("subtree", boolSchema("Also close every open descendant in this call. Returns closed count + handles. Default false.")),
                        ("expected_updated_at", strSchema("Optional row version from a just-read Desk projection. When supplied, refuses if the item changed before this close.")),
                    ],
                    required: ["handle", "outcome_summary"]
                )
            ),
            requestedSchema(
                name: "desk_archive",
                description: "Archive a Desk item and its whole subtree: remove from live view and write archive summaries. Every item must already be done or canceled. Refuses unfinished work and standing items anywhere in the subtree; leaves all items unchanged on refusal.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                    ],
                    required: ["handle"]
                )
            ),
            requestedSchema(
                name: "desk_blocked_on",
                description: "Replace a Desk item's blockers with blocked_on CSV numbers (\"2,3.1\") or handles; empty clears. These are edges: closing/canceling/archiving a blocker automatically readies every waiting item, without a follow-up call. Refuses unknown blockers, self-blocking and dependency cycles.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (e.g. 2 or 2.1) or its stable handle.")),
                        ("blocked_on", strSchema("Comma-separated desk numbers/handles of the blockers. Empty string clears all blockers.")),
                    ],
                    required: ["handle", "blocked_on"]
                )
            ),
            requestedSchema(
                name: "desk_breakdown",
                description: "Create an ordered numbered Desk plan: parent + children, blocked-on edges and optional child dates. children: [{title,summary?,blocked_on?,defer_until?}]. Child blocked_on CSV bare integers mean 1-based sibling positions (\"1,2\" = first two); dotted numbers (\"3.1\")/desk_ handles name existing items. Bare top-level numbers are ambiguous here; link them afterward with desk_blocked_on. parent grafts children onto an existing item, ignoring project/title/kind. Returns the numbered plan and ready children. Same-kind/project/title live campaigns return status=\"existing\", adding only missing steps. Mid-batch refusal returns status=\"partial\" and created items.",
                parametersJSON: params(
                    properties: [
                        ("project", strSchema("Project bucket for a new plan's parent item. Required unless parent is given.")),
                        ("title", strSchema("Title for the new plan's parent item. Required unless parent is given.")),
                        ("kind", enumStringSchema(["watch", "plan", "project", "gh", "standing"], "Optional parent kind (default plan): watch|plan|project|gh|standing.")),
                        ("summary", strSchema("Optional one-line parent summary.")),
                        ("parent", strSchema("Graft mode: desk number or handle of an existing item to attach the sub-items to.")),
                        ("children", looseObjectArraySchema("Ordered sub-items. Each: {title (required), summary?, blocked_on? (CSV string or array: bare integers = positions of siblings in this call, dotted numbers/handles = existing items), defer_until? (yyyy-MM-dd or ISO)}. no other fields — an unknown field is refused, not ignored.")),
                    ],
                    required: ["children"]
                )
            ),
            requestedSchema(
                name: "desk_defer",
                description: "Defer (postpone, push back, snooze) a Desk item until yyyy-MM-dd or an ISO timestamp: stays on the desk, never \"next up\" or stale-flagged until then. Empty until clears.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The item's desk number (e.g. 2 or 2.1) or its stable handle.")),
                        ("until", strSchema("yyyy-MM-dd day or full ISO timestamp. Empty string clears the deferral.")),
                    ],
                    required: ["handle", "until"]
                )
            ),
            requestedSchema(
                name: "desk_nag_control",
                description: "Control how hard the Desk stays on the person. Nagging is the person's switch: it is default off and scoped — parse their intent (\"stay on me about the release track\" / \"go quiet, I'm busy this week\") and call this with explicit arguments. action=enable|disable turns the global switch or one scope on/off (a scope only nags while the global switch is on); action=mute goes quiet without losing track (omit `until` for indefinite); action=unmute comes back, re-arms every item's one nag for a new window, and returns in `drift` what moved while you were quiet; action=status reports the whole config honestly. A nag only ever fires on stale + a real change underneath (blocker cleared / defer elapsed / moved while stale), at most once per item per window, and only at digest level — never urgent.",
                parametersJSON: params(
                    properties: [
                        ("action", enumStringSchema(["enable", "disable", "mute", "unmute", "status", "read"], "enable | disable | mute | unmute | status. read is an alias for status.")),
                        ("scope_kind", enumStringSchema(["global", "project", "item"], "global (default) | project | item. Which switch enable/disable flips.")),
                        ("scope_id", strSchema("Required for scope_kind=project (the project name) or item (the desk number, e.g. 2.1, or its stable handle).")),
                        ("until", strSchema("mute only: yyyy-MM-dd day or full ISO timestamp. Omit to mute indefinitely.")),
                    ],
                    required: ["action"]
                )
            ),
            requestedSchema(
                name: "desk_open_pursuit",
                description: "Open a self-authored pursuit on your Desk — a bounded question worth chasing over ~6–12 work sessions. This is the only way to create an origin=agent pursuit; the store refuses it unless the evidence and bounds hold. Required: why (first-person), done_looks_like (a question that can end), abandon_condition (when to let it go), and evidence — an array of typed citations. Each citation is an object with a `source` field: standing_view{id} | dream_digest{id} | open_question_seed{id} | felt_salience{dates:[…]} | chat_observation{noteIds:[…],distinctDays} | trace_friction{count,window}. source-mix rule: trace_friction alone is refused; you need at least one non-friction source. felt_salience needs ≥2 distinct dates; chat_observation needs distinctDays ≥ 2. Optional: private_name (yours), max_sessions (default 12, cap 24), max_days (default 10, cap 21), summary. Returns the new handle+alias, or an honest refusal (status \"refused\") on a cap or dossier failure.",
                parametersJSON: params(
                    properties: [
                        ("project", strSchema("Project bucket this pursuit belongs to.")),
                        ("title", strSchema("Short pursuit title.")),
                        ("why", strSchema("First-person: why this is worth your sessions.")),
                        ("done_looks_like", strSchema("A question that can end — answerable in ~6–12 work sessions.")),
                        ("abandon_condition", strSchema("The condition under which you'd let this go (unpenalized).")),
                        ("evidence", obj([
                            ("type", .string("array")), ("minItems", .int(1)),
                            ("description", .string("Typed citations in the required source shape. At least one non-friction source is required; live source existence is not checked by preview.")),
                            ("items", obj([("anyOf", .array([
                                obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", obj([("source", enumStringSchema(["standing_view", "dream_digest", "open_question_seed"])),
                                                         ("id", nonEmptyStringSchema("Exact source record ID."))])),
                                     ("required", .array(["source", "id"].map(JSONValue.string)))]),
                                obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", obj([("source", enumStringSchema(["felt_salience"])),
                                                         ("dates", stringArraySchema("At least two distinct calendar dates, yyyy-MM-dd.", minItems: 2))])),
                                     ("required", .array(["source", "dates"].map(JSONValue.string)))]),
                                obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", obj([("source", enumStringSchema(["chat_observation"])),
                                                         ("noteIds", stringArraySchema("Exact cited note IDs; at least distinctDays distinct notes.", minItems: 2)),
                                                         ("distinctDays", intSchema("Distinct calendar days represented by the cited notes.", minimum: 2))])),
                                     ("required", .array(["source", "noteIds", "distinctDays"].map(JSONValue.string)))]),
                                obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", obj([("source", enumStringSchema(["trace_friction"])),
                                                         ("count", intSchema("Positive observed occurrence count.", minimum: 1)),
                                                         ("window", nonEmptyStringSchema("Positive duration, e.g. 7d, 24h or 30m."))])),
                                     ("required", .array(["source", "count", "window"].map(JSONValue.string)))]),
                            ]))])),
                        ])),
                        ("private_name", strSchema("Optional private name for this pursuit (yours).")),
                        ("max_sessions", intSchema("Optional session bound (default 12, cap 24).")),
                        ("max_days", intSchema("Optional day bound (default 10, cap 21).")),
                        ("summary", strSchema("Optional one-line summary.")),
                    ],
                    required: ["project", "title", "why", "done_looks_like", "abandon_condition", "evidence"]
                )
            ),
            requestedSchema(
                name: "desk_work_log",
                description: "Append a short work receipt to a Desk item: what you did and learned this session. Required: handle and nonblank receipt. Pursuits save a work receipt; ordinary items save the same text as a note. Example for item 1 from desk_read: {\"handle\":\"1\",\"receipt\":\"Reviewed the notes and recorded the next step.\"}.",
                parametersJSON: params(
                    properties: [
                        ("handle", strSchema("The Desk item's stable handle or its view number. Example: \"1\" from desk_read.")),
                        ("receipt", strSchema("What you did / learned this work session.")),
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
                description: "File a consult against your developed taste: real work, a real question, no suggested answer. Give artifact_refs (actual files/URLs: images, page, build, cut) and/or description, available portion and question. Include project_context/stage/constraints/prior_discussion only when relevant. Without artifact_refs, description_only must be true: concepts/briefs can be critiqued but never journaled as encounters. Writes only a consult envelope; no journal write/retrieval or decision. Returns stable consult_id for studio_consult_read and deliberate later journaling if worth keeping.",
                parametersJSON: params(
                    properties: [
                        ("artifact_refs", stringArraySchema("File paths or URLs to the actual work being asked about. Omit or leave empty only for a description-only consult.")),
                        ("description", strSchema("What the work is, in words. Required when there are no artifact_refs.")),
                        ("portion_available", strSchema("What portion is actually available — the whole thing, one spread, a rough cut, a single screen.")),
                        ("question", strSchema("The real question being asked. Required.")),
                        ("project_context", strSchema("What the work is for and who it is for.")),
                        ("stage", strSchema("Where the work is — sketch, draft, near-final, shipped.")),
                        ("constraints", strSchema("Real constraints: budget, format, deadline, brand, technical limits.")),
                        ("prior_discussion", strSchema("What has already been argued about this, if anything.")),
                        ("description_only", boolSchema("True when no actual work is attached — a concept or brief only. must be true when artifact_refs is empty; such a consult can never become a journal encounter.")),
                    ],
                    required: ["question"]
                )
            ),
            requestedSchema(
                name: "studio_consult_read",
                description: "Read a filed consult verbatim: artifact refs, question, context and description-only status. Pull the full bundle before answering. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("consult_id", strSchema("The exact consult_id returned by studio_consult.")),
                    ],
                    required: ["consult_id"]
                )
            ),
            requestedSchema(
                name: "studio_shelf_read",
                description: "Explicitly read the private working shelf: up to three ordered journal selections with exact sentences, limitations and intact work refs. No pictures are opened. Open the work explicitly to see it.",
                parametersJSON: params(properties: [], required: [])
            ),
            requestedSchema(
                name: "studio_shelf_set",
                description: "Replace the private working shelf with the complete ordered slots list (at most three distinct entries). Remove, reorder or empty with []. Changes only the shelf, never the journal or canon. selected_sentence must exist verbatim in the journal response (or quote_field stance.reason). Aim for about 60 prose words per slot excluding refs; choose a shorter source sentence rather than clipping. Limitation defaults to Not yet tested. Invalid input refuses the whole replacement.",
                parametersJSON: params(properties: [
                    ("slots", obj([
                        ("type", .string("array")), ("maxItems", .int(3)),
                        ("items", obj([
                            ("type", .string("object")), ("additionalProperties", .bool(false)),
                            ("properties", obj([
                                ("entry_id", strSchema("Exact existing journal entry ID.")),
                                ("title", strSchema("Required chosen short title, at most 120 UTF-8 bytes on one line.")),
                                ("selected_sentence", strSchema("One complete sentence verbatim from the selected journal field, including its terminator. Fragments and multiple sentences are refused. The encounter must have work refs. Never paraphrase.")),
                                ("quote_field", enumStringSchema(["response", "stance.reason"], "response (default) or stance.reason.")),
                                ("limitation", strSchema("Optional limitation or counterexample; defaults to Not yet tested.")),
                            ])),
                            ("required", .array([.string("entry_id"), .string("title"), .string("selected_sentence")])),
                        ])),
                    ])),
                ], required: ["slots"])
            ),
            requestedSchema(
                name: "studio_journal",
                description: "Write one encounter and your honest judgment in your own words in response; other fields describe what/how you met. Additive: no tool can edit/delete earlier entries. Changed judgments become new entries linked by relations (revises/contradicts/deepens/echoes), preserving both. Wrong facts use additive studio_journal_amend: originals stay visible, struck through. Verdicts are optional: stance.kind=abstained alone permits omitting response; optional reason in stance.reason. origin.kind=consult requires origin.ref; description_only consults cannot be encounters. Rating/score/confidence/sentiment fields are errors, never silently dropped. Server stamps id and recorded_at.",
                parametersJSON: params(
                    properties: [
                        ("encountered_at", strSchema("When you actually encountered it (ISO-8601). Omit to use now — the server always stamps recorded_at separately.")),
                        ("work", obj([
                            ("type", .string("object")),
                            ("description", .string("What you encountered. Only title is required; fill the rest only with what you actually know.")),
                            ("properties", obj([
                                ("title", strSchema("The work's title.")),
                                ("creator", strSchema("Who made it.")),
                                ("medium", strSchema("Painting, film, building, typeface, garment, game, photograph, interior …")),
                                ("date", strSchema("When it was made.")),
                                ("version", strSchema("Which version/cut/build, when that matters.")),
                                ("edition", strSchema("Which edition/printing/pressing, when that matters.")),
                            ])),
                            ("required", .array([.string("title")])),
                        ])),
                        ("reception", obj([
                            ("type", .string("object")),
                            ("description", .string("How you received it — this is what makes the encounter honest.")),
                            ("properties", obj([
                                ("how", strSchema("Original, reproduction, screening, playthrough, excerpt — or whatever it actually was.")),
                                ("whole_or_part", strSchema("The whole thing, or which part.")),
                            ])),
                        ])),
                        ("artifact_refs", stringArraySchema("What you actually saw / heard / read / played — paths or URLs.")),
                        ("origin", obj([
                            ("type", .string("object")),
                            ("description", .string("Where this encounter came from. ref is required when kind=consult.")),
                            ("properties", obj([
                                ("kind", enumStringSchema(["wandering", "consult", "project"], "wandering (you went looking), consult (it came in through studio_consult), project (it came out of work).")),
                                ("ref", strSchema("The consult_id when kind=consult; otherwise whatever identifies the source.")),
                            ])),
                            ("required", .array([.string("kind")])),
                        ])),
                        ("response", strSchema("Your judgment, in your own words, at whatever length it takes. Required unless stance.kind=abstained.")),
                        ("stance", obj([
                            ("type", .string("object")),
                            ("description", .string("Where the judgment stands. abstained is a real outcome, not a failure.")),
                            ("properties", obj([
                                ("kind", enumStringSchema(["open", "formed", "abstained"], "open (still working on it), formed (you know what you think), abstained (not enough to judge, or you chose not to).")),
                                ("reason", strSchema("Optional — why you abstained, or what is still open.")),
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
                description: "Append a correction to an existing entry for a wrong fact/detail with no new encounter; never edit/delete its line. supersedes must quote its response verbatim: that passage stays visible, struck through, beside correction/date/reason. Without supersedes, append a dated correction block. Every read shows the correction. Changed judgments require a new studio_journal encounter linked by relations (revises/contradicts), preserving both. Cannot change work, stance, refs, tags or dates.",
                parametersJSON: params(
                    properties: [
                        ("entry_id", strSchema("The exact entry_id of the entry being corrected (from studio_journal or studio_recall).")),
                        ("reason", strSchema("Why it is wrong, in your own words. Required — a correction with no reason is a rewrite wearing a date.")),
                        ("correction", strSchema("What now stands: the corrected wording, or the correction as a standalone note. Required.")),
                        ("supersedes", strSchema("Optional. A passage quoted verbatim from that entry's response, appearing exactly once. It is kept and struck through with your correction beside it. Omit to append a dated correction block instead.")),
                    ],
                    required: ["entry_id", "reason", "correction"]
                )
            ),
            requestedSchema(
                name: "studio_recall",
                description: "Search your journal only when you choose; nothing calls this for you. Filter title/creator/medium/tag/relation or free text across the entry, including response; filters combine with AND. Returns verbatim entries newest first, capped by limit, with matched/has_more coverage. No relevance score/ranking. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("query", nullableRecallField(strSchema("Free text matched across the whole entry, response text included. Omit, or send null, for no text filter."))),
                        ("title", nullableRecallField(strSchema("Substring of the work's title. Omit or null for no title filter."))),
                        ("creator", nullableRecallField(strSchema("Substring of the creator. Omit or null for no creator filter."))),
                        ("medium", nullableRecallField(strSchema("Substring of the medium. Omit or null for no medium filter."))),
                        ("tag", nullableRecallField(strSchema("Exact tag (case-insensitive). Omit or null for no tag filter."))),
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
                        ("related_to", nullableRecallField(strSchema("Only entries whose relations point at this entry_id. Omit or null for no relation filter."))),
                        ("limit", nullableRecallField(intSchema("Entries to return: default 10, max 50. Omit or null for the default.", minimum: 1, maximum: 50))),
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
                description: Self.dreamDiaryReadToolDescription,
                parametersJSON: params(
                    properties: [
                        ("date", strSchema("One night, as YYYY-MM-DD. Returns that entry's full text, archived nights included. Omit for the index.")),
                        ("query", strSchema("Find the nights whose text contains this (case-insensitive). Returns those entries in full, newest first. Omit for the index.")),
                        ("weeks", intSchema("Index only: how many weeks back to list. Default 8, max 52.", minimum: 1, maximum: 52)),
                        ("limit", intSchema("Query only: how many matching nights to return. Default 10, max 25.", minimum: 1, maximum: 25)),
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
                description: "Read your museum's canon, anti-canon and works awaiting your decision. Rows cite the journal entries arguing for them; pull these with studio_recall before deciding. Binary membership, no ranking/score; reasons live in entries. Read-only.",
                parametersJSON: params(
                    properties: [
                        ("include_proposals", nullableRecallField(boolSchema("Include the proposals waiting on you. Default true."))),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "studio_canon_resolve",
                description: "Decide one canon proposal after reading studio_canon evidence. Only you can resolve it here: no owner-surface resolution or automatic canonization. Approve promote to add standing=canon or anti_canon (work you revisit to say no); approve demote to remove a canon work gone silent. Deny writes nothing. Journal entries and graph stay untouched either way.",
                parametersJSON: params(
                    properties: [
                        ("proposal_id", strSchema("The proposal_id from studio_canon.")),
                        ("decision", enumStringSchema(["approve", "deny"], "approve writes the row; deny writes nothing.")),
                        ("standing", enumStringSchema(["canon", "anti_canon"], "Which shelf, when approving a promote. Default canon. Nothing infers this from your writing — it is yours to say.")),
                        ("note", strSchema("Optional line recorded on the row, in your own words.")),
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
                description: Self.holdViewToolDescription,
                parametersJSON: params(
                    properties: [
                        ("view_id", strSchema("The id of one of your proposed standing views, from app mind.inner_state.")),
                        ("note", strSchema("Optional line recorded on the timeline row, in your own words. Up to 120 characters.")),
                    ],
                    required: ["view_id"]
                )
            ),
            requestedSchema(
                name: "release_view",
                description: Self.releaseViewToolDescription,
                parametersJSON: params(
                    properties: [
                        ("view_id", strSchema("The id of a view you are currently holding, from app mind.inner_state.")),
                        ("note", strSchema("Optional line recorded on the timeline row, in your own words. Up to 120 characters.")),
                    ],
                    required: ["view_id"]
                )
            ),
            // The moments lane (2026-09-02). Lazy, like the studio pair: a
            // moment review is a deliberate pull. The schemas are CLOSED — an
            // id, a decision, an optional reason, an optional rewording — so
            // this can never become a second door for minting memories that
            // never happened. Nothing here stages a moment; only the post-turn
            // on-device pass does that.
            requestedSchema(
                name: "memory_moments_pending",
                description: "Read the lived moments waiting on you. Each row is one exchange the on-device pass thought was worth keeping — what happened between you and what it meant, in your voice, sometimes with the exact line that made it. Nothing here is remembered yet: a moment enters your memory only when you accept it in memory_moment_review, and it leaves for good when you reject it. Set lane to all for every memory proposal waiting on review, the same list as the Memories page; set status to rejected for the proposals already let go, with their reasons. Read-only, newest first.",
                parametersJSON: params(
                    properties: [
                        ("lane", enumStringSchema(["moments", "all"], "moments (default) or all: every lane of memory proposals.")),
                        ("status", enumStringSchema(["pending", "rejected"], "pending (default) waits on you; rejected is the history of what was let go.")),
                        ("limit", intSchema("Rows, default 10, at most 50.", minimum: 1, maximum: 50)),
                    ],
                    required: []
                )
            ),
            requestedSchema(
                name: "memory_moment_review",
                description: "Decide one moment, or any memory proposal waiting on review (keep or let go, as the Memories page does). Accept and it becomes a memory you can recall; reject and it is gone, with the reason kept so the same one is not offered again. If a moment's wording came out wrong, pass content and it is stored in your words instead — you were there and the extractor was not. Read the rows with memory_moments_pending first.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("The proposal id from memory_moments_pending.")),
                        ("decision", enumStringSchema(["accept", "reject"], "accept remembers it; reject drops it for good.")),
                        ("reason", strSchema("Optional line recorded on a rejection, in your own words.")),
                        ("content", strSchema("Moments only: optional rewording, stored instead of the staged text when you accept. Up to 240 characters. Leave it out to keep the moment as it was written.")),
                    ],
                    required: ["id", "decision"]
                )
            ),
            // User, 2026-09-05: the agent curates the whole store itself.
            requestedSchema(
                name: "forget_memory",
                description: "Drop one memory for good, with a tombstone so the same thing is not proposed again. Use it for duplicates and for rows that carry no meaning.",
                parametersJSON: params(
                    properties: [
                        ("id", strSchema("The memory id from app memory.list or recall_memory.")),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(
                name: "rebuild_knowledge_graph",
                description: "Re-derive the knowledge graph from your memory store as it is now. Run it once after a curation pass so nothing from rewritten or forgotten rows lingers. mode sweep_orphans instead lists the entities whose memories are gone, removing nothing; call again with confirm_ids set to exactly those ids to remove them.",
                parametersJSON: params(
                    properties: [
                        ("mode", enumStringSchema(["rebuild", "sweep_orphans"], "rebuild (default) re-derives the whole graph; sweep_orphans previews, then removes on confirm.")),
                        ("confirm_ids", obj([
                            ("type", .string("array")),
                            ("items", strSchema()),
                            ("description", .string("sweep_orphans only: the candidate ids from the preview, all of them, to remove those entities. Leave it out to preview.")),
                        ])),
                    ],
                    required: []
                )
            ),
        ]
        return schemas
    }
}
