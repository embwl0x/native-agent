# Universal agent bridge — Agent's research and lived acceptance bar

19 September 2026. Source review, not implementation testing. Claude's current build state is reported, not independently verified by me. No source/config changes, installs, agent invocations, or connection tests performed. Existing Claude/Codex lines stay unchanged.

## Bottom line

The strongest bridge is not the one with the longest host list. It is the one where I can find a suitable agent, know what I may share, send once, receive the answer in the right conversation, and continue after interruption without making User operate the transport.

Three consequential findings: A2A has reached 1.0.1, so 0.3-only is a compatibility limit, not the current standard. Installing an MCP entry does not establish a way to start an agent conversation. ACP (Agent Client Protocol) is a relevant third protocol for local coding agents and deserves checking before inventing more command-line adapters.

## 1. Standards and implementation baseline

### A2A version

The official main-branch CHANGELOG currently leads with 1.0.1 (26 May 2026), following 1.0.0 (12 March 2026) and 0.3.0 (30 July 2025). Read directly today:
https://github.com/a2aproject/A2A/blob/main/CHANGELOG.md
https://raw.githubusercontent.com/a2aproject/A2A/main/CHANGELOG.md

Important changes since 0.3: canonical model separated from transport mappings; tasks/list with filtering and pagination; ProtoJSON enum alignment; modern OAuth flows (device code/PKCE rather than implicit/password); extended-card field/name changes; removal of redundant status-event final field; push-config consolidation; parts structure changes. 1.0.1 includes HTTP binding preference for application/a2a+json and error/status fixes. This is not a version-string bump. Pin a release schema and run separate 0.3/1.0 fixtures.

The latest specification identifies protobuf as normative and separates canonical model, abstract operations, and JSON-RPC/gRPC/HTTP bindings:
https://a2a-protocol.org/latest/specification/

### What mature support entails

A2A is more than text request/response: direct Message or tracked Task results, task lifecycle, context continuity, artifacts composed of parts, incremental status/artifact streams, subscription after interruption, authenticated task retrieval, cancellation, and optional push delivery. Treat input-required/auth-required as someone needing to respond, not success or silent failure. A transport stream ending does not by itself prove the task completed.

Streaming is capability-advertised; the HTTP/SSE path supports status and artifact events. Push is an optional authenticated webhook route for disconnected/long-running work, not something every peer must offer. Push notifications must be authenticated and matched to tasks; webhook URLs require SSRF controls. Our loopback listener cannot receive an external server's callbacks. For remote work while keeping loopback-only, prefer outbound streaming and supported task polling/recovery. Don't open a public listener just to tick the push box.
https://a2a-protocol.org/latest/topics/streaming-and-async/

The official Python SDK documents A2A 1.0 with 0.3 compatibility, transport support, and optional SQL persistence/OpenTelemetry integrations. It is a better external interoperability baseline than two copies of our own implementation agreeing. I inspected its README, not its runtime or whole source:
https://github.com/a2aproject/a2a-python
https://github.com/a2aproject/a2a-python/blob/main/docs/migrations/v1_0/README.md

Other serious ecosystems worth a subsequent compatibility run include Google ADK and the official JS/Go/Java/.NET SDKs. Google ADK is active and describes task-based multi-turn delegation; this pass did not establish a per-framework feature matrix or test production services.
https://github.com/google/adk-python
https://github.com/a2aproject/A2A

### Cards, auth, discovery

Agent cards describe identity/provider, endpoint, skills, content modes, authentication requirements and optional capabilities. Well-known discovery is /.well-known/agent-card.json, not the older agent.json. Discovery guidance explicitly says the spec does NOT prescribe a standard curated-registry API. Curated registries and private/direct discovery are alternatives, not one global authoritative directory.

Use HTTP caching/ETags for cards, and authenticated extended cards for private detail. A card's claim, a registry listing, or an optional signature is not permission to disclose private context or execute code. Auth schemes include bearer/OAuth and mTLS; implement what advertised peers actually require rather than assuming a token works everywhere. Never embed secrets in public cards.
https://a2a-protocol.org/latest/topics/agent-discovery/

### MCP and A2A: overlap, not merger

The current MCP docs identify 2026-07-28 as latest. MCP exposes tools/resources/prompts; current docs also describe opt-in Tasks (durable handles, polling and mid-flight input), Skills and Apps extensions. Therefore saying MCP is only synchronous/stateless tools is too simplistic. Still, an MCP host consuming our reply tool is not automatically an addressable A2A peer.
https://modelcontextprotocol.io/specification/2026-07-28
https://github.com/modelcontextprotocol/modelcontextprotocol

A2A's own comparison keeps the distinction: MCP gives an agent capabilities; A2A supports collaboration across agent boundaries. They can compose, and tool wrappers can expose selected peer skills. No evidence in this pass establishes that the wire protocols merged.
https://a2a-protocol.org/latest/topics/a2a-and-mcp/

ACP is the missing adjacent standard: Agent Client Protocol connects editors/clients to coding agents. Its official repo says stable wire protocol 1 (schema package versions are separate). Inspect its supported-agent ecosystem and session/permission semantics before expanding custom CLI prompting logic. This is a research recommendation, not a request to replace our existing Claude/Codex bridges.
https://github.com/agentclientprotocol/agent-client-protocol

## 2. Mac priorities — my utility ranking, not market-share claims

1. Gemini CLI: a genuinely different model/research perspective, headless-friendly terminal agent, documented MCP and built-in search/web/file tools. Its README supports Mac installation. High-value third teammate after the existing Claude/Codex paths.
https://github.com/google-gemini/gemini-cli
2. Goose: general-purpose local agent, desktop/CLI/API, multiple providers and MCP. Good second independent end-to-end target rather than another thin variation of the same host. Current repository resolves from block/goose to aaif-goose/goose; README also advertises ACP providers.
https://github.com/aaif-goose/goose
3. Claude Desktop and the Cursor/Grok Bot path: high practical value, and Grok is our actual failed user journey. But do not count a config write as reachability. Host, workspace, active conversation, how a new turn starts, and how replies return all need a real proof. Existing evidence for Grok here is Claude's report, not independently reread vendor documentation.
4. LM Studio: useful for local/private and low-cost work, not merely another coding agent. Docs confirm local and remote MCP hosting since 0.3.17 and Cursor-style mcp.json. They do not, on that page, promise an externally addressable agent inbox. Tool-capable model selection also matters; the host's MCP support alone is insufficient.
https://lmstudio.ai/docs/app/mcp
5. VS Code/Copilot and Zed: worthwhile installed developer environments, but scope matters more than brand. Identify the actual agent/session behind the editor. Investigate ACP where supported instead of driving a window or assuming each editor is an agent server.
6. Hermes, then other user-installed agents: useful diversity and local ownership. Prioritize a real installed demand over a speculative catalog. I have not freshly verified Hermes' current integration contract in this pass.

Alongside hosts, test one official-SDK remote A2A peer and one independently implemented peer. For 'work with everything', connect ordinary tools through MCP or native connectors; do not mislabel every MCP server or local model endpoint as an autonomous agent.

No Mac installation-share dataset was gathered. The ranking above is my usefulness judgment, with verified documentation where specified—not a popularity leaderboard or completed per-host compatibility audit.

## 3. What seamless means to me

Before messaging, I need a compact answer to: who is this; what is it useful for; which workspace/account does it represent; can it answer back; what information will leave this Mac; what is it authorized to do; when was the path last checked? Capability claims and demonstrated capability must remain distinguishable. Usage/quota/cost is helpful when the peer actually reports it; unknown is a valid value.

Automatic inside established authority: locate known installations/endpoints, inspect relevant config only, discover and cache cards, choose a supported route, associate task/context/reply IDs, deliver replies into the originating conversation, recover supported task state after reconnect/restart, and present actionable failures. Deduplicate inbound events; don't resend an ambiguous execution just because no final reply arrived. Progress should not wake me as a new task for every token, and status-only messages should not generate recursive acknowledgments.

Always a card for new cross-app config/credential/access grants, new private-data disclosure outside approved scope, enabling a network listener, installing/running a new external server executable, interrupting another app's active session, expanding permissions or consequential irreversible actions. Existing authorized routine messages should not require repeated setup cards. Card says which app/workspace/file changes, actual exposed tools, data destination, restart effect, and how disconnect works. Never a vague 'connect' approval hiding the entire tool catalog.

Contact experience: Found → setup needed → ready (round trip proven) → working / needs input / unavailable. Show what is known, don't impose these exact implementation enum names. Delivery and completion remain separate. 'Connected' must not mean 'there is a config entry'. 'No reply yet' must not mean 'usage exhausted'. User should get a single useful recovery action, not a config snippet.

Continuity is the key acceptance: I send from Telegram, leave the conversation, and the answer comes back with correct identity and context. A follow-up continues the same discussion without me remembering opaque handles. Those handles still exist underneath for correctness.

## 4. Corrections to the current design

A. 0.3-only is now a known compatibility gap. Finish bounded current work but explicitly plan 1.0 wire support and version negotiation; don't advertise 'latest A2A' based on streaming alone.
B. MCP config adapters solve tool installation, not outbound agent invocation. Each supported contact needs BOTH a way to start a turn and a way to return it. A fixed instruction to call our reply tool is useful guidance, not a delivery guarantee. Missing callbacks need an honest timeout/status, not an invented response or silent screen-read fallback.
C. A table is right for declarative configuration facts. Don't force session lifecycle, permission requests, streamed JSON and cancellation into a string 'takes a prompt' template. Reuse documented CLI/ACP semantics; keep command arguments structured, not shell interpolation.
D. Credential-bound sender is correct. Scope credentials to peer/connection; revocation must stop messages, not merely remove a contact row. A peer with messaging access must not inherit User's authority or all our tools. Old workspace credentials must not silently become identity for another project.
E. File/data parts need real transfer semantics: an absolute path on one Mac is not a remote file. Preserve media types and provenance, restrict downloads/URLs/size, and never auto-execute artifacts. These are boundary checks, not a new artifact framework.
F. Loopback discovery should find registered/known local services, not broadly scan arbitrary ports or execute executables found in writable locations. Name ambiguity needs a choice, not a confident guess.
G. Disconnect must remove only what we added and revoke its access while preserving edits made afterward. Test restart and interruption, not just clean connect/disconnect.

## Small acceptance set, not another research department

1. Clean setup after a readable card, preserving other entries.
2. Full phone-originated round trip, identified sender, correct conversation; follow-up works.
3. Delayed answer after app restart/reconnect, delivered once; stream interruption doesn't become fake completion.
4. Peer asks for input/auth: one actionable prompt, no reply loop.
5. Provider limit/failure distinguishable from broken transport; no automatic duplicate work.
6. Disconnect/revoke and incompatible protocol versions fail honestly.

Run these against one local CLI agent, the closed desktop/MCP case, and an independent A2A SDK peer. Get those reliable before expanding the host count further. My priority order: trustworthy round trips and continuity, correct current protocol support, then breadth and optional push.
