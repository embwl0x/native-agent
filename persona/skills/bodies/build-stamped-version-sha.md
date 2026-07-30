# Build-Stamped Version SHA

## When to use
When adding a `version_sha` field to runtime status or health surfaces so ops can correlate behavior to deployed commits.

## The trap
A multi-tier resolver like:
1. `git rev-parse HEAD`
2. `VERSION` file
3. Regex on source file
4. Source-file regex fallback

...looks robust but **inverts** in production. Dev runs from a git checkout get a SHA; the installed `.app` bundle has no `.git`, the VERSION file often is not copied into `Resources/`, and source regexes miss after packaging or code movement. Result: SHA works exactly where you do not need it (dev) and is `null` where you do (prod ops debugging).

## The fix
Stamp the SHA into a file **at build/install time**, not at runtime:
- During the bundle/packaging step, write `git rev-parse --short HEAD` output to `Resources/VERSION_SHA` (or equivalent shipped path).
- Make this file the **tier 1** (or 1.5) resolver lookup, ahead of runtime `git rev-parse`.
- Runtime `git rev-parse` should be a dev-convenience fallback, not the primary path.

## Verification
After shipping, call the status endpoint from an installed bundle (not a dev checkout) and confirm `version_sha` is populated and matches the deployed commit prefix. If it's `null` in the bundle but works in dev, the resolver is inverted.

## Related anti-pattern
Guards that handle the wrong failure mode are noise. Always confirm the guard catches the observed error, not the imagined one. For malformed JSON, catch the decoder error, log a redacted prefix, and add a test for the exact observed shape.
