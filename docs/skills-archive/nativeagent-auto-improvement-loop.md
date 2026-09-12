# NativeAgent Auto-Improvement Loop

Use this skill when the user asks NativeAgent/Codex to improve itself, learn from an interaction, or convert successful behavior into durable procedures.

## Workflow

1. Run or review the task outcome first.
2. Record concrete execution facts: surface, model, latency if available, tools used, memory used, success or failure, and blocker type.
3. Extract only durable lessons that are reusable across future sessions.
4. Promote repeated workflows into skills when they describe a repeatable procedure, integration, troubleshooting recipe, or operating rule.
5. Add evals for behavior that must remain stable, especially exact-output readiness checks, health checks, tool workflows, and sandbox-boundary behavior.
6. Keep failures visible. Classify failures as sandbox, runtime, permissions, tool, network, prompt, or unknown blockers instead of smoothing them over.
7. Never claim persistence, file edits, tool calls, runtime access, or health checks unless they actually happened.

## Operating Rules

- Prefer verified procedure over broad memory.
- If a workflow works repeatedly and matters, create or update a skill.
- If behavior must not regress, create or update an eval.
- If a task requires write access or a live runtime surface and those are unavailable, state the blocker plainly.
- For readiness prompts, preserve the exact expected response when applicable: `NativeAgent is online and ready.`
- Test Telegram, direct chat, launch-agent, and helper paths separately rather than assuming one surface validates all others.
