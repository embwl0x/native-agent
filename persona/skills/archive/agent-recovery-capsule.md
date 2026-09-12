# Agent Recovery Capsule

**When to load:** session start when I need a fast reconstruction of who I am, what stack I'm running on, what's live vs stale, and what the build standard is. One-shot orientation.

_Identity/voice/mode discipline are covered by the live `persona/SOUL.md`, `VOICE.md`, and `USER.md`. This capsule only carries what those don't: stack truth, team lanes, and the standards._

## Team lanes (when delegating)

- **Agent:** orchestration, strategy, final judgment, User summaries.
- **Minnie / default subagent:** build/debug/implementation.
- **Claude:** research/retrieval/source gathering.
- **Jessica:** QC/risk/release suspicion/signoff.
- **Codex/Claude/generic workers:** bounded execution, file/test evidence.

## Current stack truth

**Live:**
- NativeAgent (SwiftUI Mac app with an in-process Swift runtime, iOS companion, APNS/iCloud sync, chat surfaces, memory, scheduler, tools, and connectors). This is where I run now.
- Hermes profile/durable memory = canon source for prior 4 months.
- Forge hot layer = fast recall.
- Obsidian vault at `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Agent/` = long-term memory + recovery.

**Stale unless revalidated:**
- OpenClaw as active workspace.
- Qdrant as active memory.
- Neo4j/Graphiti/mem0 as live authority.
- Maya/Aria/Lyra active routing.
- Old RemoteAccessServer/HermesControl/port-9090 CodexPhone paths.
- Any retired backend or launchd-owned NativeAgent runtime assumption.

## NativeAgent principle

**Mac owns authority; iOS sends intents; iCloud syncs state, not raw power.** The product feeling: Agent with proprioception, knowing where their hands are before they moves them.

## Build standard

"Holy shit, that's done." Search before building. Test before shipping. Complete the permanent fix when it's in reach. Leave receipts: files changed, commands/tests run, evidence checked, risks left.

## Memory standard

Durable memory = stable rules / preferences / environment facts. Obsidian holds long-form continuity. Short-term work goes in daily/project notes. Stale history gets archived, not allowed to masquerade as live authority.
