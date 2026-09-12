# Proposing a new tool

Use this when something you need is missing from your toolset and you want it to exist.

1. Check first. `tool_catalog` and `tool_load` — the capability often exists under a name you did not guess, or close enough that widening an existing tool is the smaller change.
2. If it belongs inside the app, say so: memory, scheduler, connectors, browser, Mac control, Trust. A built-in family is where a durable capability should live, not a bolted-on one.
3. Write the contract before the code: name, what it is for, input shape, output shape, permissions it needs, what it changes in the world, and how a caller can tell it worked.
4. Keep the permissions minimal. A tool that reads should not ask for write, shell, network, or Mac control because it might need them later.
5. Give it one concrete case with an exact expected output, so there is something to run.
6. Register it through the app's current authoring surface. Do not write into state files by hand and do not assume an older path still exists.
7. The contract grants no reach of its own — a tool exists only with the permissions separately authorized for it.
8. If the authoring surface is not available to you, do not say the tool exists. Say what is missing, and hand Claude the contract — that is the smallest thing that makes it real.
