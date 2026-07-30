# NativeAgent Telegram Image Send Rollout

## When to use
Use when planning or implementing NativeAgent support for sending images/photos to Telegram chats.

## Workflow
1. Treat this as an outgoing media feature first, not a full inbound Telegram media pipeline.
2. Inspect the existing Telegram bridge before editing: find the current text send path, update handler behavior, receipt schema, app diagnostics model, and tests.
3. Add a Swift-native Telegram `sendPhoto` path alongside the existing `sendMessage` path.
4. Validate image sources conservatively: allow app-owned files, approved workspace files, or explicit URLs; do not allow arbitrary secret-path reads.
5. Add or generalize an app-native action with caption support.
6. Record receipts with media-specific fields: `kind=image`, `messageId`, `chatId`, caption preview, and media metadata.
7. Update Swift/app diagnostics so the Telegram tab can show image-send test status and recent image receipts.
8. Add tests for disabled polling, missing token, missing allowlist, mocked Telegram success/failure, validation failures, and receipt shape.
9. Keep live sends manual or opt-in; smoke tests should mock Telegram and avoid sending real images by default.
10. Run the normal validation path, including `script/test.sh`, relevant smoke tests, and context/prompt-bloat checks.
11. Confirm `capabilities.summary.autoloaded == 0` and sampled context routes remain under budget.

## Reporting
Summarize the shipped surface, safety constraints, receipt fields, diagnostics updates, test coverage, and any live-send verification status.
