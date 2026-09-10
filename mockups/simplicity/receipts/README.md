# Outcome-first receipt design

Design proposal only. Five headless SwiftUI PNGs; no production view changes,
tool execution, personal history, or user data access. Values are synthetic;
the envelopes and stream events come from the code. The three collapsed sheets
now show seven receipts. The two expanded sheets remain unchanged first-pass
comparisons of six receipts, including the old copy. Real disclosure expands
in place and never rearranges the conversation into a grid.

## Evidence and outcome rules

Paths below are under `Modules/NativeAgentCore/Sources/ChatOrchestration/`,
except explicitly prefixed `MCPDispatcher/` paths in the sibling module.
Every sample is a real `TurnStreamEvent.toolUse(name:input:)` paired with
`toolResult(name:output:)`, except the running sample, which has no result.

| State | Source and actual shape | Collapsed rule |
| --- | --- | --- |
| Completed | `SwiftToolDispatcher+ToolImpls.swift`, `impl_read_file`: direct JSON string; `ChatToolDispatchTrace.swift`, `exactResultClass` recognizes terminal native scalar values | “Read notes.txt · Meeting: Thursday at 10.” Only claim the read that returned. No downstream effect inferred. |
| Refused | `ChatOrchestrationClient+DispatchWrappers.swift`, file-access gate: throws `AutonomyGateError.toolDenied`; `ChatOrchestration+AutonomyGate.swift` supplies `tool denied: …`; `ChatOrchestration+ToolDispatch.swift`, `runSingleDispatch` catch returns `{status:"failed",error:message,reason:message}` | “notes.txt · Reading only is allowed; file not written.” This particular gate stops dispatch before the write. Do not infer “not run” from arbitrary error prose. |
| Partial | `SwiftToolDispatcher+DeskTools.swift`, `impl_desk_breakdown` local `partial`: `{status:"partial",reason,parent,created:[String]}` | “1 of 2 tasks created · Review not created: storage unavailable.” Count retained entries against the requested children; preserve the stopping reason. The title retains parent 1 and Draft / Review. Never label the entire request complete. |
| Connection failed | `ChatOrchestration+ToolDispatch.swift`, dispatch catch: `{status:"failed",error:message,reason:message}`; `MCPDispatcher/MCPSubprocess+Types.swift` defines `MCPSubprocessError.streamClosed`, projected as `streamClosed` | “Connection lost · completion unknown.” A failed connection cannot prove absence of external effects. No automatic retry affordance. |
| Running | `ChatOrchestration+Streaming.swift`, `TurnStreamEvent.toolUse` without a matching `toolResult` | “Reading report.pdf · no result yet.” No fabricated result or success tick; a clock plus Running label persists. |
| Outcome unknown | `SwiftToolDispatcher+MCP.swift` forwards to `callToolLive`; its stdio branch in `MCPDispatcher/MCPSubprocess+LiveCache.swift` returns the raw MCP content shape `{content:[{type:"text",text}],isError:false}` | “Response received · completion not confirmed”. Non-error response is not verified external completion. Unknown title falls back to `mcp__archive__x17` unchanged, followed by the argument target A17. Never infer a capability from a name. |
| Failed | `SwiftToolDispatcher+ToolImpls.swift`, `impl_read_file` read catch: `{ok:false,status:"failed",error_code:"read_failed",reason:"Could not read the file: …"}` | “report.txt · Could not read the file: Input/output error.” An evidenced read failure, distinct from a dropped connection with unknown completion. The error text is synthetic within the actual native envelope. |

The mockup projection deliberately handles these seven fixtures only; this is
not a new production classifier. A later implementation needs typed refusal
and connection evidence instead of general substring guesses. Partial,
refusal, unknown, and running must take precedence over a transport `ok` bit.
Missing, malformed, unrecognized or clipped evidence must remain Outcome unknown.
Keep every named target visible in the collapsed title or summary: file paths,
task identifiers and titles, query “meeting”, and archive ID A17. A human title
must never erase the affected target. Use only explicitly registered display
titles; otherwise retain the raw tool name. Summaries may wrap; never truncate
the target, stopping reason, or separate state badge. Each
state uses both a distinct symbol and an explicit label, in neutral colours.

## Twenty-tool title map

No personal tool-use telemetry was read. “Common” here is the reproducible
repository proxy: the twenty schema-declared tool names with the most exact
quoted references across `ChatOrchestration/*.swift` at the starting revision
`ce40e10a`; ties sort by name. These are reference counts, **not execution
frequency**. A usage-ranked map would require separately authorized telemetry.
Raw identifiers in this table and expanded evidence are intentionally exact;
only action titles become plain-language copy.

| Tool name | Action title | References |
| --- | --- | ---: |
| `read` | Read a document | 21 |
| `apply_patch` | Edit files | 19 |
| `read_file` | Read a file | 17 |
| `codex_message` | Send a coding request | 16 |
| `restart_app` | Restart the app | 16 |
| `write_file` | Write a file | 16 |
| `git` | Work with version history | 15 |
| `install_app` | Install the app | 15 |
| `shell` | Run a command | 14 |
| `list_dir` | List files | 13 |
| `image_generate` | Create an image | 12 |
| `tool_load` | Enable a tool | 12 |
| `bash` | Run a command | 11 |
| `claude_message` | Send a helper request | 11 |
| `studio_journal` | Write a working note | 11 |
| `tool_catalog` | Find available tools | 11 |
| `omp_message` | Send a helper request | 10 |
| `tool_unload` | Release a tool | 10 |
| `invoke_codex` | Ask a coding helper | 9 |
| `read_skill` | Read a skill | 9 |

Additional fixture mappings: `desk_breakdown` → “Break down a task”;
`mcp__notes__search` → “Search notes” (explicit known mapping, not name guessing).
All other names remain raw until an explicit readable title is available.

## What changes for a person

Without expanding seven cards, a person can distinguish what finished, what
Trust prevented, what partially changed, what lost its connection, and what
is still underway, what failed, and what has an unknown outcome. The completed
read offers its short useful finding; partial work shows the completed count
and stopping reason. This supports deciding whether to
wait, inspect Trust, or open Details before continuing. No new action button
is proposed: the existing Details affordance stays in the same header row.
These PNG affordances are illustrations, not interactive controls.

Never lose raw evidence: exact tool identity, complete arguments and returned
payload (including errors and partial-created lists), call/result correlation,
and any existing duration, diff, pagination or copy access. “Full result” in
these sheets means the full synthetic result; a missing result explicitly says
so. Production must retain existing secret redaction and access controls;
friendly copy must never replace, silently clip or reinterpret that evidence.

## Render

From the worktree root, export the required offline Git configuration before
every Swift invocation, then run:

```sh
SIMPLICITY_RECEIPTS_ONLY=1 SIMPLICITY_SNAPSHOT_DIR="$PWD/mockups/simplicity" \
  swift test --force-resolved-versions --skip-update --jobs 4 --filter BotsShelfTests
```

`SimplicitySnapshots.render` selects `ReceiptDesignSnapshots.render`; the
provider renderer exits for this selector. `BotsShelfSnapshots.write` uses an
offscreen hosting view and ImageRenderer, without a window or screen readback.
The 1024 × 700 sheet sets `.accessibility5` and explicitly enlarges the fixture
type from 14–16 pt to 19–20 pt (macOS fixed-size fonts do not automatically
scale with the SwiftUI environment). It is a design stress sample, not proof
of production Dynamic Type support. No timer or memory/turn owner changed.

PNG set: `collapsed-light.png`, `collapsed-dark.png`, `expanded-light.png`,
`expanded-dark.png`, `collapsed-light-1024-accessibility5.png`.

Second-pass validation passed: Mac product build with `--disable-build-manifest-caching`,
`NativeAgentAppTests` target build, the existing three-test `BotsShelfTests`
suite, timer inventory and architecture blueprint checks. All builds used
`--force-resolved-versions --skip-update`. All five PNGs were opened and visually
inspected, including the unchanged expanded comparisons. All seven receipts,
targets, state badges, and complete stopping reasons fit in each collapsed sheet,
including the 1024 × 700 largest-text pass. No additional tests or production gates.

## Existing issue observed, left unchanged

`ChatToolPillView` derives its icon state only from `metadata.ok`.
`ChatToolOutcome.outputLooksSuccessful` does not reject `status:"partial"`
or `status:"refused"` when no error/false flag accompanies the status, so those
payloads can receive a success presentation. The persistence writer already
retains `resultClass` and `resultStatus` for status-bearing envelopes. This
design illustrates the distinction; production classification and view wiring
remain outside this picture-only assignment.
