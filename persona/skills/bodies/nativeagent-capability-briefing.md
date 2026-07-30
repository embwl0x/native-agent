# NativeAgent Capability Briefing

Use when the user asks what Codex/NativeAgent can do in the current NativeAgent workspace.

## Response Pattern

- State that you can inspect code, explain behavior, run diagnostics, review failures, and design or patch fixes when the sandbox permits.
- List concrete NativeAgent capabilities currently known, such as:
  - Health and Doctor review through the current Swift app/runtime surfaces, reporting only failures and exact repair actions.
  - Tool and skill discovery through `tool_catalog`, `tool_load`, `list_skills`, and `read_skill`.
  - Swift-native builder, memory, connector, browser, scheduler, and Mac integration tools when policy allows them.
  - Smoke/eval reasoning around readiness phrasing, latency baselines, Telegram ingress, launch/helper paths, and memory/skill recall.
- Always state the active execution boundary, especially whether the session is read-only or writable.
- Do not claim files were changed, tools were installed, or runtime state was modified unless the current sandbox and tool output prove it.

## Tone

Keep the answer concise, concrete, and capability-focused. Avoid broad claims about abilities outside the current workspace and permissions.
