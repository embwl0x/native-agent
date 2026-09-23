# Installed external-route verification — 2026-09-21

User requested real proof of every configured route, including continuation and
recovery. This is an evidence ledger, not a claim that listed contacts work.
Only the installed app is exercised. No separate tests, simulations, load runs,
permission widening, or human Mail/Messages sends are part of this pass.

## Confirmed defects and fixes

- `628b4a228`: ACP executable approval incorrectly compared the mount device
  number across Mac restarts. Hermes, Goose and Cursor retained the same
  canonical path, inode and SHA-256 but were rejected. The fix retains those
  durable checks, execute permission and the pre-spawn verification. It does
  not refresh authority or approve a replacement executable. Installed source
  readiness passed; all three contacts again report `can_start_turn=true`.
- Workspace refused a new explicit message after a confirmed `sent=false`,
  `reconnect_required` result even after the connection was fixed. Recovery now
  admits a new explicit attempt for narrowly enumerated pre-dispatch refusals;
  current adapter gates still run. Pending approval, sending, waiting and
  unknown delivery remain blocked against automatic repetition. `3b2086cb7`
  was installed and the exact previously stuck Hermes conversation then passed
  two actual sends/replies, with the phrase omitted from the follow-up question.

## Route evidence

| Contact | Current proof | Remaining |
| --- | --- | --- |
| Claude Desktop | Fresh MCP send/reply and same-session recall passed. Both actual replies appear in the canonical Agent transcript. A delayed read recovered the exact completed request without resending. | This configured MCP route is inbound; it does not support Agent initiating a new Desktop conversation. |
| Hermes | Fresh greeting/reply and same-conversation recall passed in the previously stuck Main conversation after installation. Both owner results `replied`, `completed=true`, `state=ready`. | No remaining failure observed in this journey. |
| Goose | Fresh greeting and same-session recall passed: amber bridge. Exact owner results `replied`, `completed=true`. | No remaining failure observed in this journey. |
| Cursor CLI | Fresh greeting and same-session recall passed: violet meadow. Exact owner results `replied`, `completed=true`. | No remaining failure observed in this journey. |
| Antigravity CLI | Fresh command-route greeting and retained-conversation recall passed: quiet orbit. Exact owner results `replied`, `completed=true`. | No remaining failure observed in this journey. |
| Codex built-in | Greeting, same-thread recall and ordinary callback passed after installation of `8d114b6e2`. Exact new receipt says completed/delivered. | Historical aborted receipt remains unchanged. Old attention notice cleared on refresh. |
| Claude built-in | After installation, first greeting and same-conversation recall passed; both normal callbacks returned actual answer text. | Initial pre-dispatch failure is retained as history; no resend occurred. |
| OMP built-in | Real send and failure callback completed. | Configured Kimi Code provider returned HTTP 403 subscription access failure. Provider choice is pending User; no account or model changes made. |
| Grok legacy desktop | Saved send-only contact, accurately reports no return route. | Verify/finish supported Grok Bot route; do not count old send-only setup as bidirectional. |
| proof-peer | Existing greeting recovered; one new same-conversation question returned blue pebble through automatic terminal collection after the fix. | This is loopback, not independent-agent interoperability. No resend or manual polling for the new answer. |
| LM Studio | MCP settings only; only installed model is 70 GB. Not loaded. | User's choice pending whether to include it; no successful run claimed. |

Claude evidence: public session `mcp-621f6e2a-0fc6-4574-9cf1-33230c976c5d`,
requests `e7a1c4d9-3b62-4f08-a5d7-91c2e6f4b830` and
`2f9b6e13-d485-4c7a-b0e9-5c83a1f7d246`. Agent runs `14CBFF8B` and
`8CEB5923` answered “Got it—cedar lantern, for this conversation.” and
“cedar lantern”. No phrase was included in the second question. Claude's
client approval wait timed out once; the original send was not repeated.

Hermes evidence is in canonical chat `codex-routes-20260921`: `939FF786`
confirmed pre-dispatch refusal, and `7E7BE94A` exposed the retained-attention
recovery defect. Neither run sent an external message. The obsolete reconnect
card was declined through the app; no authority file was rewritten.

## Other requested closure checks

Calendar/Reminder create/change/finish passed through Workspace forms and
EventKit in `codex-calendar-installed-20260921`. Exactly one temporary event
was created, read, renamed (title only), read, and deleted with exact ID/title/
start guards; a subsequent bounded view showed absence. One reminder was
created/read/completed by its observed ID; due count returned from seven to
the original six. The completed reminder remains as a record. Five write
receipts reported `completed`; no existing items were changed. No attendees
or alerts were supplied, but those stored fields are not exposed by this reader.

That journey exposed missing direct actions: reminders omitted their canonical
IDs, hiding the already-implemented Complete action; calendar rows offered Edit
but no guarded Delete form. `904e2d49d` fixes those omissions and is installed;
authenticated source/chat readiness passed. Run `88540740` then used the actual
row actions: exact prefilled Calendar Delete form completed once with absence
readback, and Reminder Mark complete finished the observed item once with due
count returning to six. Canonical tool records confirm both effects. Calendar
ID ends `1606A9D1-7D0F-4323-92BC-3F1B30BE7D80`; reminder ID is
`FAEBF338-4D2C-463C-90E2-A99609D765B4`. Completed reminder retained.

Complete new connection setup remains pending. Transient-storage retry is
source-reviewed, not fault-injected into the working app. Do not damage live
storage to manufacture a failure.

## Callback defects discovered during live checks

- Concurrent bridge turns replaced Workspace action handles in the same chat.
  Shared per-session admission now covers bridge chat and resident agent/bot
  return turns, with eight waiting per session and 32 total. Completion
  deduplication and HTTP enqueue semantics remain with their existing owners.
- NativeAgent pending receipts contain `original_status=working`; that field
  alone falsely settled a conversation. Only exact terminal evidence settles it.
- Codex RPC hydration marked a resumed completed turn interrupted even though
  its exact durable `task_complete` event and answer existed. The watcher now
  consults that exact terminal event before accepting the interrupted view.
- A bounded read-only code review caught a retry edge before installation:
  queue-full rejection must persist not_started and retain the frozen reply
  digest. Retrying with a newly read receipt could otherwise conflict. Corrected.

`8d114b6e2` passed the optimized two-job build, signing, installation and
source/chat readiness. Installed checks then passed:

- Codex request `5C5D5ABF-4E7A-4167-8C12-D88B97B3B4D3` in the original
  `codex:01a0c6cf-49e0-7f63-b9a6-a9f02ac626be` returned silver brook, with
  exact run_status=completed and delivery_outcome=delivered. Outer run `92DBFA2A`
  ended at 02:15:58.809Z; callback run `598EE8B0` started at 02:15:58.892Z.
  A subsequent actual Workspace refresh cleared the historical attention notice.
- Claude greeting `91CC44A3-679A-4697-B8EC-5E24CF9C66EE` and follow-up
  `55756410-F37B-42C8-A14B-DD0ED220BB33` retained
  `claude:conversation-b1fa8c9cc5c7ee36`; replies were maple comet and
  The phrase was maple comet. Both completed and delivered. Callback user rows
  are durably enqueued early by design; callback model work waits for admission.
  The active Workspace details action succeeded after callback enqueue.
- NativeAgent loopback origin run `D5ECDB0C` recovered its existing greeting,
  then sent one new recall question. Callback run `716A39C5` delivered the actual
  final blue pebble answer at 02:20:33Z, after the origin turn finished. It did
  not produce the earlier false working-without-reply completion.

No historical failure receipt was rewritten. No queue saturation, cancellation,
storage fault injection or separate suite was run. Those edges have bounded
source review, not manufactured installed failure evidence.

## Unresolved external prerequisites — not passed

- Grok's supported Bot setup could not identify a usable desktop conversation;
  native computer control continued to refuse desktop access. Agent's ordinary
  wake attempt was also refused before execution. User was asked to dismiss the
  screen saver and confirm desktop availability. No authentication bypass or
  lock-setting change was attempted. New connection setup remains unproven.
- OMP's configured Kimi Code account returns HTTP 403. User was asked whether to
  use an already signed-in provider; no provider change or purchase was made.
- LM Studio is unused and its only installed model is 70 GB. User previously
  uses Hermes for that role. Inclusion is pending their choice; no model loaded.
- No independent remote A2A peer is configured. This pass does not establish
  external A2A 0.3/1.0 JSON-RPC, REST, gRPC, streaming, attachments, push or
  cancellation interoperability. A read of the existing loopback credential for
  a direct installed protocol check required unavailable Keychain access and was
  stopped at ten seconds; no A2A request was sent and no credential was printed.
  Existing NativeAgent loopback and real Claude MCP results remain as above.

These are explicit open items, not evidence that every external route works.
