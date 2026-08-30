# Manual visual fixtures

These pages are opened deliberately during installed-runtime computer-use
development. Nothing in the build or test suite runs them automatically.

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
