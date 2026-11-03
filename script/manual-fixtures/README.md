# Manual visual fixtures

These pages are opened deliberately during installed-runtime computer-use
development. Nothing runs them automatically.

- `readpage-{hn-front,hn-comments,article,forecast}.html` are small authored,
  saved HTML examples for the dfix-readpage extraction change. They preserve
  representative nested HN layout tables, omitted closing tags, inline prose,
  relative links, cookie chrome and forecast rows without storing a live site's
  changing content. Open a saved page only for a small, requested check through
  the installed app; the old source-slicing comparison harness is removed.
  `readpage-saved-hn-front.html` and `readpage-saved-hn-comments.html` are also
  actual saved public HN HTML, fetched once on 2026-10-28 from
  `https://news.ycombinator.com/` and
  `https://news.ycombinator.com/item?id=50271640`. These retain the original
  page layout for a requested installed-app read.
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
  not create a giant jump. Keep any requested installed-app observation to a
  small number of native input actions; this page is not a campaign entry point.
  Some OS file-open handlers discard the query: use the browser address bar
  with the full `file:///...` URL and verify the visible mode before acting.

Provider stubs and instructions to seed synthetic traces or route the resident
agent through a campaign are removed. Verification uses small observations of
the installed app under AGENTS.md; these static pages confer no authority to
change provider settings, user data or the agent's mind.
