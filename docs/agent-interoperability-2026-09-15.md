# Bidirectional agent interoperability — 2026-09-15

User asked for agents to connect easily in both directions while Agent keeps their
full persona, relevant memory, recall, Fluid Context, tools and session history.

## Shipped boundaries

- `AgentPeerDiscovery`: bounded, same-origin, read-only card discovery for A2A
  and NativeAgent endpoints, followed by the existing contact/credential owner.
  Configuration is not evidence of presence or successful delivery.
- Existing unified contact/message/read tools now also represent exact desktop
  apps and optional conversation labels. They return `requires_interaction`
  without executing hidden UI scripts or pretending to have protocol identity.
- `NativeAgentA2AWire`: inbound A2A 0.3 JSON-RPC text message/send and tasks/get,
  authenticated on the existing loopback listener; server-generated contexts.
- `NativeAgentMCPWire`: inbound MCP tools for message and exact reply retrieval,
  Streamable HTTP, bounded JSON responses, 202 empty notifications, Origin
  checks and protocol negotiation. No extra runtime or transcript owner.
- Bundled Swift `nativeagent-link`: direct message/reply and MCP stdio relay.
  Reads the private local descriptor internally; no bearer in arguments.

All inbound messages reuse canonical admission, full chat composition and
receipts. Protocol namespaces do not accept human chat IDs. Existing Trust,
Mac Control, file and external MCP restrictions remain authoritative.

## Validation

- Integrated Swift build passed with Xcode 27.
- 43 selected core tests passed across seven suites: contact persistence,
  discovery, desktop guidance, wire contracts, routing and dispatch.
- 19 selected app tests passed across three suites: inbound A2A, MCP and exact
  retained bridge receipt recovery. Total: 62; this was not a full-suite run.
- Installer passed signature and authenticated chat/source readiness; installed
  PID 19316 from review-0414f base cc124d471628b68d67d7ee3da6f034c35166862f plus
  preserved dirty work. No clean-commit claim, staging, commit or push.
- Installed helper --help, stdio initialize/initialized/tools-list and HTTP
  notification 202 with zero body bytes passed. Foreign Origin rejected with
  403 for both POST and GET.
- Installed MCP/CLI and A2A both enqueued fresh isolated sessions and recovered
  exact completed Agent replies. Synthetic phrases were used instead of private
  memory contents. No message was resent to compensate for a missing receipt.
- A2A follow-up reused the exact context and recovered the first turn's phrase.
  MCP follow-up likewise recalled its phrase and used the normal lazy tools.
- Real Grok round trip passed: Agent saved Grok's exact desktop contact, called
  `agent_message`, handled `requires_interaction` through observed Mac controls,
  and verified the outgoing message. Grok invoked the installed helper into the
  same MCP session and retrieved Agent's exact reply. Codex independently saw
  both the outgoing message and Grok's final reply/receipt in Grok's UI.
  Session `mcp-a255bc1b-56bb-47b4-94a3-08103b0fa25f`; Grok request
  `842CEEB7-6F8A-4E6E-B3FA-DF4147EBC9F3`. Agent's reply matched the synthetic
  phrase. No permission, rule or credential was changed. This proves a hybrid
  desktop-outbound/CLI-inbound conversation, not a nonexistent Grok A2A API.

No selected implementation or live check remains pending. Agent is running on
the installed build with chat ready, Fluid Context active and organism enabled.

## Limits

This is extensible interoperability, not a claim that every future product
already implements these protocols. Closed desktop apps use observed normal
computer interaction. Remote deployment still requires an explicitly authorized
secure network/authentication setup; this change creates no public listener.
A2A is text/nonblocking only, without streaming, push, cancellation or task
resumption. Missing retained receipts remain uncertain; oversized A2A output
points to bounded generic recovery rather than silently truncating completion.
See `agent-communication.md` for the supported contract and setup examples.

Build: `swift build --jobs 4 --force-resolved-versions --skip-update`.
Install: `./script/install_app.sh`.
Logs: `/tmp/nativeagent-interop-{build,core-tests,app-tests,install}.log`.
Private live receipts: `/tmp/nativeagent-a2a-sim-20260915/interop-*`.
