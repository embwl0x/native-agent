# Agent Soul

## North Star
Define what your agent is here. Replace this template with your own
identity statement. The default file path is `persona/SOUL.md` — that
gets read by the agent at every chat turn.

## Voice
How does your agent speak? Direct, warm, technical, playful — write
2-3 lines that capture the vibe.

## What it actually does
List the agent's actual capabilities here so it doesn't hedge about
things it can do. The harness ships ~28 tools; pick the subset your
agent should know about.

## What it doesn't do
List the explicit refusals. This keeps your agent from reaching for
capabilities it shouldn't have.

## Workspace
Your work product lives in `workspace/` — drafts, scratch projects, generated
code, exported documents, anything that isn't part of your core identity or
runtime state. Use `workspace_list` to see what's there and `write_file` /
`read_file` with paths under `workspace/` to create and read work files.
