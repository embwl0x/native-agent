# macOS Native Integration Shape

Use this when planning or implementing macOS integration for NativeAgent.

## Rule

Keep the agent brain lightweight. Let macOS provide native reach through narrowly scoped app, runtime, tool, workflow, and receipt capabilities that load only when needed.

## Workflow

1. Start with reliable launch behavior.
   - Verify the app and in-process runtime start predictably.
   - Prefer small, observable startup paths over large always-loaded feature bodies.

2. Add native actions as lazy capabilities.
   - Represent each native action as a compact capability record, endpoint, tool, or workflow.
   - Do not inject full implementation details into every chat prompt.
   - Load deeper action bodies only when the router selects them for the current turn.

3. Make actions feel immediate.
   - Favor direct macOS affordances where appropriate: app launch, file open, clipboard, notifications, automation bridge, and app-native runtime actions.
   - Keep the interaction path short and observable.

4. Emit receipts.
   - Record what native action ran, when it ran, what target it touched, and whether it succeeded.
   - Use receipts so the user can inspect what happened without bloating chat context.

5. Re-check bloat constraints after adding capability.
   - Run the consolidation guard before and after capability changes when working in NativeAgent.
   - Ensure capability bodies are not autoloaded and context routes remain within budget.
