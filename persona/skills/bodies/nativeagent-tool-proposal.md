# NativeAgent Tool Proposal

Use this when the user asks to create or promote a reusable NativeAgent tool.

## Workflow

1. Start from the current Swift runtime and tool catalog. Use `tool_catalog` / `tool_load` to see whether a matching tool already exists.
2. Prefer built-in Swift tool families when the behavior belongs in NativeAgent itself: memory, scheduler, connectors, browser, Mac integration, builder, or trust/policy.
3. If a new durable tool is needed, describe the tool contract first: name, purpose, input schema, output shape, permissions, side effects, and verification.
4. Keep permissions minimal. Read-only utilities should not request write, network, shell, connector-send, or Mac-control reach.
5. Add tests or a concrete smoke case before promotion. At least one case should have an exact expected output.
6. Register the tool through the current Swift-native registry or authoring surface available in the app. Do not invent an old HTTP route or write directly into state files unless that is the documented current path.
7. If validation or promotion fails, report only the failing check and exact repair action.

## Small Utility Pattern

For a small utility, keep the contract boring:

```json
{"message":"some text"}
```

returns:

```json
{"ok":true,"characterCount":9,"wordCount":2}
```

Count characters from the raw `message` string length. Count words by splitting on whitespace after trimming. Invalid or missing input should return a safe structured error response rather than throwing an uncaught exception.

## Blockers

If the current Swift runtime has no tool-authoring or registry surface available from the session, do not claim the tool was created. State the missing surface and propose the smallest Swift-native implementation or test needed to make it real.
