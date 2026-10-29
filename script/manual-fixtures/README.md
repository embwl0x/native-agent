# Manual visual fixtures

These pages are opened deliberately during installed-runtime computer-use
development. Nothing in the build or test suite runs them automatically.

- `readpage-{hn-front,hn-comments,article,forecast}.html` are small authored,
  saved HTML examples for the dfix-readpage extraction change. They preserve
  representative nested HN layout tables, omitted closing tags, inline prose,
  relative links, cookie chrome and forecast rows without storing a live site's
  changing content. `node script/readpage_samples.js` deliberately prints the
  actual pre-change and current extractor output on these files using the Swift
  interpreter. It builds no app or test target and makes no network requests;
  it is sample evidence, not installed-app proof. Compilation, installation and
  resident verification belong to the release lead.
  `readpage-saved-hn-front.html` and `readpage-saved-hn-comments.html` are also
  actual saved public HN HTML, fetched once on 2026-10-28 from
  `https://news.ycombinator.com/` and
  `https://news.ycombinator.com/item?id=50271640`. The sample printer shows the
  first 12 extracted lines and full line counts for these larger documents.
  Trailing spaces in the saved comment HTML are normalized for repository hygiene.

- `visual-navigation-check.html` is a local, pixel-only input surface. Actual
  right-button drag pans its grid, left drag moves the orange circle, held
  WASD keys pan, vertical wheel changes zoom, and horizontal wheel pans.
  Visible counters distinguish
  button semantics and release state. No networking, persistence, automation
  API, or runtime code depends on it; use only during an explicit native-input
  observation.

- `visual-world-check.html` presents several coloured moving objects, one
  stationary coloured destination, one moving occluder, and a visible meter.
  Clicking the yellow object increments Hits and lowers Energy; every other
  click increments Misses.
  Optional URL query parameters are `speed=1` (0.25–50 times the original
  60Hz pace), `teleport=0` (continuous trajectory after a hit), and `seed=1`
  (repeatable relocation sequence). The speed/mode is printed on the canvas.
  Motion uses elapsed frame time, capped after pauses so a background tab does
  not create a giant jump. For a harder native moving-target observation, open
  `visual-world-check.html?speed=12&teleport=0&seed=1` deliberately; this is not
  run by any automated suite.
  Some OS file-open handlers discard the query: use the browser address bar
  with the full `file:///...` URL and verify the visible mode before acting.

- `sse_pings_only.py` is a loopback SSE stub for the provider stream guard's
  first-output deadline: every POST gets `200 text/event-stream` headers and
  then pings only, never a reply; it logs each hang-up with the pings sent.
  Never the resident app (`~/Applications/NativeAgent.app`, root
  `~/Projects/NativeAgent/data`). Only the public-shaped test install at
  `/Applications/NativeAgent.app`, staged without `Contents/Resources/REPO_PATH`
  so it runs on its own root, `~/Library/Application Support/NativeAgent`;
  confirm that file is absent before writing anything. In that root: route
  chat to the `openai` API-key provider with a throwaway key and a `gpt-` model,
  and seed 100+ streamed `llm.call` rows with `ttftMs` for that provider, model
  and `streamKind` `incremental` into its `traces/events.jsonl`. Launch it with
  `open -n --env NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT=http://127.0.0.1:8799/v1/chat/completions /Applications/NativeAgent.app`;
  only a loopback host is honored.

- `sse_repeat_forever.py [port=8799]` sends Responses API prose deltas of one
  line forever until the client closes; the next request carrying the turn
  observation gets a completed reply. Use the same test install and loopback
  endpoint above; set its provider wall to 5 seconds for this bounded proof.
- `sse_cut_after_prose.py [port=8799]` sends three Responses API prose deltas
  then closes without a terminal event; the observation-bearing continuation
  completes. Use the same test install and loopback endpoint above.
