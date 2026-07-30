# NativeAgent Production Deploy Triage

## When to Use
Use when a user reports an accidental or questionable NativeAgent production deployment, especially when staging was intended.

## Procedure
1. Treat it as a production incident until proven harmless, but do not roll back blindly.
2. Freeze additional deploys or automation that could compound the incident.
3. Verify local observability first:
   - Check whether the installed NativeAgent app and Swift runtime are running.
   - If reachable, inspect relevant release, production, support, workflow, or capability surfaces.
   - If unreachable, state that live production health cannot be verified from the current session.
4. Identify exactly what was deployed:
   - Artifact/version/commit/config/env/secrets bundle.
   - Intended staging artifact versus actual production artifact.
   - Whether local git history can identify the deployed change.
5. Check high-risk side effects before deciding rollback:
   - Migrations or schema changes.
   - Background jobs or scheduled tasks.
   - Data writes or destructive operations.
   - External notifications, billing, emails, connector calls, or agent autonomy changes.
   - Auth, secrets, permissions, sandbox, persistence, or production-hardening settings.
6. Use NativeAgent release/production surfaces when available, such as `/v1/release/checklist`, `/v1/production/hardening`, `/v1/production/export`, support bundle, migration plan, workflow rollback, and capability pack rollback.
7. Recommend rollback only when the deployed version is unsafe, unknown, or production-impacting and a known-good rollback path exists.
8. If the deployed artifact matches staging, has no migrations, no external side effects, and health is clean, classify as a near miss plus monitoring and follow-up hardening.

## Reporting Style
Lead with containment status and what was verified. Clearly separate verified facts from unknowns. End with the immediate priority list and rollback criteria.
