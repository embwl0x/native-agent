# NativeAgent Personality Smoke

Use when asked to smoke test or diagnose NativeAgent personality/persona surfaces.

## Workflow

1. Check the current Swift app/runtime surface first. Prefer existing app actions or dispatch tools such as `get_persona_doc`, `persona_read`, and the compiled turn-context path.

2. If the live app/runtime surface is unavailable, report that clearly as a runtime availability issue, not necessarily an implementation failure.

3. Validate the direct Swift behavior when possible:
   - Persona docs include `SOUL.md`, `VOICE.md`, `GROWTH.md`, and generated/read-only `USER.md`.
   - Compiled chat context includes the expected surface, fingerprint, bounded persona docs, clock/runtime tail, and no broad skill/tool dump.
   - Save paths reject generated `USER.md` and only allow writable persona docs.
   - Any save round trip still updates fingerprints correctly.
   - Compiled context size is checked for obvious prompt bloat.

4. Save smoke artifacts under `.runtime/` when useful, such as `.runtime/personality-direct-smoke-summary.json`.

5. Final report should separate:
   - Live runtime reachability.
   - Direct Swift handler results.
   - Any artifact paths.
   - Bottom-line implementation health.

## Operating Rules

- Do not claim the running app surface is healthy if only direct handlers were tested.
- Do not treat local environment blockers as product bugs without corroboration.
- Watch for prompt bloat and the project rule that capability/personality bodies should stay bounded and lazily loaded.
