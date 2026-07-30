# NativeAgent Guardrail Rollout

Use this when discussing or planning how to relax NativeAgent's sandbox, write permissions, persistence, or approval boundaries.

## Rule
Do not recommend removing all guardrails at once. Treat permission expansion as a staged rollout with verification at each step.

## Recommended Sequence
1. Keep current guardrails until the Swift runtime, tool catalog, or filesystem proves a capability exists.
2. Enable writes only in app-owned paths first.
3. Add validated tool and skill persistence next, using proposal/validation flows where available.
4. Expand filesystem access only behind explicit approvals.
5. Require audit logs for broader or persistent actions.
6. Avoid claiming persistence, write access, or tool execution unless verified by the actual environment.

## Response Pattern
When the user says guardrails will eventually be removed, acknowledge the current guardrails as intentional development safety, then recommend staged loosening: app-owned writes, validated persistence, explicit approvals, and audit logs.
