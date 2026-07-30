# NativeAgent Skill Manifest Spec — v1

**Status:** Canonical for installable capability packages. Conversational procedure skills use the production contract below.
**Written:** 2026-05-06  
**Informs:** Tasks 1.2 (CLI scaffolder), 1.3 (skill builder agent), 1.4 (OAuth template), 1.5 (lifecycle UI)

---

## Production conversational procedure contract

NativeAgent also has agent-authored procedure skills: small Markdown guides
for repeatable behavior. They are not connector packages, executable tools,
memories, or permission objects.

The model-visible lifecycle is intentionally compact:

1. `list_skills` returns the manifest fields (stable id/name, description,
   triggers, status, and source) without body text.
2. `read_skill(name)` lazy-loads one relevant body by manifest name or id.
   The agent must not preload every body.
3. `save_skill(name, description, triggers, content)` is the only supported
   conversational create/update path. It uses the same locked Skills owner as
   the Mac UI. Agents must never inspect, infer, or directly edit
   `skills/registry.json` or body paths.

Use a procedure skill only when the user explicitly requests it or a behavior
has proven reusable. Facts and preferences belong in MemoryV2. Skill content is
guidance only and cannot create tools, permissions, approval bypasses, or
safety authority; TrustCenter, effect-time validation, receipts, and domain
verification remain authoritative. Read-only bridge profiles cannot save
skills.

Runtime procedure bodies live under the app data root's
`skills/bodies/<stable-id>.md`; committed persona procedures may live under
`persona/skills/bodies/`. This is an implementation detail owned by NativeAgent,
not a model-facing authoring API.

---

## 1. Vocabulary

The runtime previously had four overlapping nouns for the same concept: connector, tool, skill, capability. This spec retires all but one.

**Skill** is the single noun. A skill is a user-installable plugin that adds capabilities to the agent. Everything that was previously called a connector, a tool, or a capability is now a skill with a specific type.

| Old term | New term |
|---|---|
| connector | skill, `type: "connector"` |
| tool (sandboxed script) | skill, `type: "tool"` |
| capability | marketing word only — not a code noun |
| workflow | informal grouping — not a registry object |

Skill types:

| Type | What it is |
|---|---|
| `connector` | External service integration. Owns OAuth, scopes, and a set of declared tools the Swift runtime calls on the user's behalf. No separate process is required for app-native connectors; credentials are held by the app-owned credential stores. |
| `tool` | Sandboxed code that runs on the user's Mac. Spawned via `sandbox-exec`. Communicates over JSON stdin/stdout. |
| `agent_persona` | A complete agent identity: SOUL, VOICE, USER docs and a recommended model list. Used in multi-agent council/relay (Beyond B.2). No executable — the Swift runtime reads docs into the persona compiler. |
| `composite` | A skill that chains and wires other skills together. Declares `requires` — a list of skill names it depends on. |

"Capability" does not appear in code, registry files, or API responses going forward.

---

## 2. Directory Layout

Each installed skill lives under:

```
~/Library/Application Support/NativeAgent/skills/<name>/
```

Where `<name>` exactly matches the `name` field in `manifest.json` (lowercase, hyphenated).

```
<name>/
  manifest.json        required — schema defined in §3
  README.md            optional — shown verbatim in the skill card UI
  entrypoint           required for type=tool; optional otherwise
  oauth.json           optional — OAuth client config (client_id, scopes, endpoints)
  resources/           optional — static assets bundled with the skill
  state/               optional — per-skill mutable local state; runtime may write here
```

The runtime never writes to any skill directory except `state/`.

### Global Registry

A single flat file tracks all installed skills:

```
~/Library/Application Support/NativeAgent/skills/registry.json
```

Format: JSON array of registry entries (see §4 for the `state` field).

```json
[
  {
    "name": "github",
    "version": "1.0.0",
    "type": "connector",
    "state": "installed",
    "installedAt": "2026-05-06T12:00:00Z",
    "lastUsedAt": "2026-05-06T18:22:00Z",
    "path": "~/Library/Application Support/NativeAgent/skills/github"
  }
]
```

The runtime never treats in-memory skill state as durable; it reads `registry.json` on demand.

---

## 3. manifest.json Schema

All fields use camelCase. JSON only — no YAML, no TOML.

### 3.1 Universal Required Fields

```json
{
  "schemaVersion": 1,
  "name": "github",
  "version": "1.0.0",
  "type": "connector",
  "description": "Create issues, list repos, and search GitHub from chat.",
  "author": {
    "name": "Example Author",
    "email": "author@example.com",
    "url": "https://example.com/nativeagent/author"
  }
}
```

| Field | Type | Rules |
|---|---|---|
| `schemaVersion` | integer | Must be `1` for this version of the spec |
| `name` | string | Lowercase, hyphens only, no spaces, globally unique in the registry |
| `version` | string | Semver (`MAJOR.MINOR.PATCH`) |
| `type` | string | Enum: `connector` \| `tool` \| `agent_persona` \| `composite` |
| `description` | string | One sentence, plain English, shown verbatim in the skill card UI |
| `author.name` | string | Required |
| `author.email` | string | Optional |
| `author.url` | string | Optional |

### 3.2 Conditional Fields by Type

#### type=`connector`

```json
"oauth": {
  "provider": "github",
  "scopes": ["repo", "issues:write"],
  "deviceFlow": true
},
"endpoints": {
  "baseUrl": "https://api.github.com",
  "authHeader": "Bearer {token}"
}
```

| Field | Rules |
|---|---|
| `oauth.provider` | Slug string identifying the OAuth provider. Must match a Swift-runtime-known provider or be `custom` |
| `oauth.scopes` | Array of strings — the exact scopes requested during device flow |
| `oauth.deviceFlow` | Boolean. `true` = use RFC 8628 device authorization grant. `false` = redirect-based (requires WKWebView; Sprint 2+) |
| `endpoints.baseUrl` | HTTPS base URL for API calls |
| `endpoints.authHeader` | Template string. `{token}` is substituted with the Keychain-stored access token |

An `oauth.json` file in the skill directory holds the client-side secrets (`client_id`, `client_secret` if required). It is **never** stored in the manifest itself.

#### type=`tool`

```json
"entrypoint": "main.swift",
"runtime": "swift",
"sandbox": {
  "read": ["app_data"],
  "write": [],
  "network": false,
  "processes": false
}
```

| Field | Rules |
|---|---|
| `entrypoint` | Relative path from skill directory to the executable. Must exist on disk. |
| `runtime` | Enum: `node` \| `swift` \| `binary`. The selected executable must be provided by the user/tool environment; NativeAgent does not vendor or author Python runtimes. |
| `sandbox.read` | Array of named path tokens: `app_data`, `user_home`, `user_selected` |
| `sandbox.write` | Same tokens. Empty array = no write access beyond `state/` |
| `sandbox.network` | Boolean. `true` = `(allow network*)` in sandbox profile |
| `sandbox.processes` | Boolean. `true` = allow spawning child processes. Default `false`. |

The Swift tool runner generates the `sandbox-exec` profile at call time from these fields. The mapping of tokens to real paths follows the current tool execution logic (§6).

#### type=`agent_persona`

```json
"persona": {
  "soulPath": "resources/SOUL.md",
  "voicePath": "resources/VOICE.md",
  "userPath": "resources/USER.md"
},
"recommendedModels": ["gpt-5.5", "claude-opus-4-7"]
```

| Field | Rules |
|---|---|
| `persona.soulPath` | Relative path to the SOUL doc. At least one of soul/voice/user must be present. |
| `persona.voicePath` | Relative path to the VOICE doc. Optional. |
| `persona.userPath` | Relative path to the USER doc. Optional. |
| `recommendedModels` | Array of model slugs, ordered by preference. Informational — the runtime uses this when routing to this persona. |

#### type=`composite`

```json
"requires": ["github", "notion"]
```

| Field | Rules |
|---|---|
| `requires` | Array of skill `name` strings. Every listed skill must be `installed` before this skill may be activated. |

### 3.3 Universal Optional Fields

These apply to all skill types:

```json
"tools": [
  {
    "name": "gh.create_issue",
    "description": "Create a GitHub issue in a repository.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "owner": {"type": "string"},
        "repo": {"type": "string"},
        "title": {"type": "string"},
        "body": {"type": "string"}
      },
      "required": ["owner", "repo", "title"]
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "issueNumber": {"type": "integer"},
        "url": {"type": "string"}
      }
    }
  }
],
"permissions": [
  "network.public",
  "keychain_read",
  "keychain_write"
],
"tags": ["github", "dev", "issues"],
"homepage": "https://example.com/nativeagent/github-skill",
"license": "MIT"
```

#### `tools` array

Each entry is a callable tool the agent may invoke:

| Field | Rules |
|---|---|
| `name` | Dot-namespaced: `<skill>.<verb>`. Lowercase. |
| `description` | One sentence shown to the LLM as the tool description. |
| `inputSchema` | JSON Schema (draft-07) object describing the argument shape. |
| `outputSchema` | JSON Schema describing the result shape. Optional but recommended. |

#### `permissions` strings

The following strings are the complete allowed set:

| Permission | What it grants |
|---|---|
| `network.localhost` | TCP connections to 127.x and ::1 |
| `network.public` | Any outbound TCP/HTTPS |
| `app_data_read` | Read `~/Library/Application Support/NativeAgent/` |
| `app_data_write` | Write `~/Library/Application Support/NativeAgent/` |
| `keychain_read` | Read Keychain items under the `NativeAgent` service name via Swift proxy |
| `keychain_write` | Write/update Keychain items under the `NativeAgent` service name via Swift proxy |
| `file_user_selected_read` | Read files the user explicitly selected via Open panel |
| `file_user_selected_write` | Write to user-selected file locations |
| `screen_capture` | Take screenshots via `screencapture` (requires Trust Center approval per-use) |
| `microphone` | Access microphone input (Sprint 3) |
| `camera` | Access camera input (Sprint 3) |

Undeclared permissions are denied. The runtime enforces permissions at call time — a skill cannot request a permission it did not declare at install.

---

## 4. Lifecycle States

A skill moves through the following states. The state is stored in `registry.json`.

```
drafted ──► installed ──► active
                │            │
                └────────────┴──► dormant
                
Any state ──► quarantined
```

| State | Meaning |
|---|---|
| `drafted` | Manifest registered, schema validation passed, NOT loaded into live dispatch. Visible in the Skills UI for user review. No API calls may be routed to it. |
| `installed` | User approved the skill. OAuth flow completed (if needed), token stored in Keychain or the app-owned credential store. The skill is ready to receive calls. The runtime loads it lazily on first call. |
| `active` | The skill is warm — called within the last hour, or currently in use. The runtime may keep connector state cached. |
| `dormant` | Installed but not called in the last 4 hours. The runtime flushes cached state. Will re-warm on next call without user interaction. |
| `quarantined` | Cannot receive calls. Entered from any state when: (a) validation fails, (b) a secrets scan flags the skill, (c) user disables it, or (d) OAuth token is revoked. UI shows the reason. |

### State Transitions

| Transition | Trigger |
|---|---|
| `drafted → installed` | User clicks Install in Skills UI; OAuth completes if required |
| `installed → active` | First API call dispatched to the skill |
| `active → dormant` | 4 hours of inactivity (runtime background eviction) |
| `dormant → active` | API call dispatched to the skill |
| `any → quarantined` | Validation failure, secrets flag, revocation, or user disable |
| `quarantined → drafted` | User re-validates and re-reviews the skill (re-enters review flow) |

---

## 5. Validation Rules

`nativeagent-skill validate <path>` runs these checks in order. All must pass for state to advance past `drafted`.

### 5.1 Schema Validation
- `manifest.json` must parse as valid JSON
- All required fields (§3.1) must be present and correctly typed
- `type` must be one of the four valid enum values
- Conditional fields for the declared type must be present
- `schemaVersion` must be `1`

### 5.2 File Existence
- For `type=tool`: `entrypoint` path (relative to skill dir) must exist on disk
- If `oauth` block is declared in the manifest: `oauth.json` must exist in the skill directory
- If `persona.*Path` fields are declared: those relative paths must exist

### 5.3 Secrets Scan
All files in the skill directory (recursive, text files only) are scanned for:
- Any string matching `sk-[A-Za-z0-9]{20,}`
- Any string matching `Bearer [A-Za-z0-9._-]{20,}`
- Any string matching `ghp_[A-Za-z0-9]{36}`
- Any string matching `xoxb-` or `xoxp-` (Slack tokens)
- Any key named `secret`, `token`, `password`, `api_key`, `private_key` with a non-empty string value in JSON/YAML files

A match in any file quarantines the skill immediately.

### 5.4 Permissions Audit (Heuristic)
The validator checks that declared permissions are plausibly used:
- `network.public` declared → `entrypoint` must reference `http`, `https`, or `requests` / `urllib` / `fetch`
- `keychain_read` or `keychain_write` declared → `entrypoint` must reference `keychain` or the runtime credential-helper pattern
- `screen_capture` declared → `entrypoint` must reference `screencapture`
- `microphone` or `camera` declared → `entrypoint` must reference `AVFoundation` or `SFSpeechRecognizer`

A mismatch produces a **warning**, not a blocking failure, in v1. Warnings are shown to the user during review.

### 5.5 Sandbox Profile (type=tool only)
- `sandbox.read` and `sandbox.write` must contain only valid token strings from the §3.2 table
- `sandbox.network` and `sandbox.processes` must be booleans
- The validator dry-runs `sandbox-exec -p <generated_profile> /bin/true` and checks exit code 0

### 5.6 Author Signature
Not enforced in v1. Planned for v2: Ed25519 signature over `manifest.json` verifiable against a published key. Validator emits an INFO note when no signature is present.

---

## 6. Plugin Interface

### 6.1 type=`tool` — JSON stdin/stdout Protocol

The Swift tool runner spawns the entrypoint via `sandbox-exec`, pipes JSON to stdin, and reads JSON from stdout.

**Request (runtime → process stdin):**
```json
{
  "tool": "gh.create_issue",
  "args": {
    "owner": "example-owner",
    "repo": "NativeAgent",
    "title": "Sprint 1 done"
  },
  "context": {
    "runId": "abc123",
    "userId": "local",
    "sessionId": "sess-456"
  }
}
```

**Success response (process stdout → runtime):**
```json
{
  "ok": true,
  "result": {
    "issueNumber": 42,
    "url": "https://example.com/example-owner/NativeAgent/issues/42"
  }
}
```

**Failure response:**
```json
{
  "ok": false,
  "error": "github_api_error",
  "detail": "422 Unprocessable Entity: Validation Failed"
}
```

Rules:
- Process must write exactly one JSON object to stdout and then exit
- Exit code 0 is expected; non-zero exit with no stdout is treated as a crash and the call fails
- Timeout: `manifest.timeoutSeconds` (default 10). SIGKILL sent on timeout.
- Process must not write to stderr in normal operation (stderr is captured for debugging only)
- The process runs under `sandbox-exec` with a profile generated from `sandbox.*` fields

### 6.2 type=`connector` — Swift Runtime Implementation

App-native connectors do not spawn a separate process. The Swift runtime implements connector logic directly through NativeAgentCore modules and app-owned credential stores.

Each connector must implement:

| Method | Signature | Description |
|---|---|---|
| `auth_status` | `() → {connected: bool, user: str\|null, expiresAt: str\|null}` | Returns current OAuth state |
| `auth_connect` | `() → {deviceCode: str, userCode: str, verificationUri: str, expiresIn: int}` | Initiates device flow |
| `auth_poll` | `(deviceCode: str) → {ok: bool, token: str\|null, error: str\|null}` | Polls for device flow completion |
| `auth_revoke` | `() → {ok: bool}` | Revokes token and removes from Keychain |
| `tool_<name>` | `(args: dict) → result: dict` | One method per declared tool |

The runtime maps `{"tool": "gh.create_issue", "args": {...}}` to the registered Swift connector action.

### 6.3 type=`agent_persona` — No Executable Interface

The runtime reads `soulPath`, `voicePath`, and `userPath` contents at session start when this persona is selected. No process is spawned. The persona docs are injected into the system prompt compiler the same way the default SOUL/VOICE/USER docs are today.

### 6.4 type=`composite` — Dependency-Checked Dispatch

A composite skill has no executable interface of its own. When called, the runtime resolves the composite's declared `tools` to the appropriate child skills and dispatches each call to the child's interface (type=tool or type=connector). All `requires` skills must be in `installed` or `active` state before any composite call proceeds.

---

## 7. Example: GitHub Manifest

See `docs/example_manifests/github.json`.

---

## 8. Open Questions (Deferred)

These decisions are deliberately out of scope for v1. Each is a named open question so downstream tasks know what they are NOT blocked on.

**OQ-1: Marketplace distribution channel.**  
How skills are discovered, hosted, and downloaded from outside the local machine. Local skills ship first. Marketplace is Sprint 2+.

**OQ-2: Skill signing and cryptographic provenance.**  
v1 has no signature enforcement. v2 will use Ed25519. The exact key distribution and revocation mechanism is unresolved.

**OQ-3: Inter-skill data sharing for composite skills.**  
A composite skill can call child skills in sequence, but the protocol for passing output from skill A as input to skill B is not defined. Today: the composite's own `entrypoint` owns that orchestration. A shared memory bus or typed channel protocol is deferred.

**OQ-4: schemaVersion migration path.**  
When schemaVersion bumps to 2, what happens to installed v1 skills? Migration shim, rejection with user notice, or auto-upgrade? Not decided.

**OQ-5: Cross-platform skills.**  
The `sandbox` field assumes macOS `sandbox-exec`. iOS skills (Sprint 4) will need a different sandbox model. The manifest schema will need a `platform` field or per-platform overrides. Not designed yet.

**OQ-6: Skill update and version pinning.**  
If a skill at version 1.0.0 is installed and the author releases 1.1.0, how does the update reach the user? Auto-update vs. manual review vs. pinned version are all unresolved for the marketplace era.
