# macOS GUI Control Loop

Use this when designing or explaining how a macOS agent can navigate apps or desktop UI reliably.

## Core Pattern

Build the agent around a tight observe -> act -> verify loop.

1. Observe the current state with both pixels and structure:
   - Use ScreenCaptureKit, screenshots, or live frames for visual context.
   - Use the Accessibility API for UI structure: buttons, fields, focused windows, labels, roles, values, and enabled state.

2. Plan a small action:
   - Choose one bounded UI action at a time.
   - Prefer accessibility-targeted actions when available.
   - Fall back to coordinate clicks only when structural targeting is unavailable or insufficient.

3. Act through a controlled input layer:
   - Use CGEvent or equivalent drivers for mouse, keyboard, scrolling, hotkeys, and typing.
   - Keep actions explicit and receipt-producing.

4. Verify immediately:
   - Re-observe the screen and accessibility tree after each action.
   - Check whether the expected state change occurred before continuing.
   - If verification fails, retry, re-plan, or ask for help rather than assuming success.

## NativeAgent Shape

For NativeAgent, keep the core agent lightweight. Expose GUI control as lazy Swift-native capabilities rather than injecting large UI-control bodies into every prompt.

Recommended components:

- ScreenCaptureKit for visual state.
- macOS Accessibility API for structured UI metadata.
- CGEvent input for keyboard, mouse, scroll, and hotkeys.
- A small planner that emits one action at a time.
- Receipts for observations, actions, and verification results.

## Operating Rule

Pixels provide human-like context. Accessibility metadata provides precision. Input events provide reach. Verification prevents overconfidence. A GUI agent needs all four to navigate reliably.
