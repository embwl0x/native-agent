# Growing an ability

Use when a needed ability is missing.

1. Discover first with `app {find:"…"}`; use an existing action or extend an ability where it fits.
2. Grow service behavior with `ability.save`, existing app actions and declared capabilities. Missing primitives belong in the stem, never a new service subsystem.
3. Define name, purpose, input/output shapes, required permissions, effects and verification before code.
4. Declare only needed capabilities. A read-only ability does not need write, shell, network or Mac control for hypothetical later use.
5. Give one concrete input and exact expected output.
6. Use `ability.save`, never state-file edits. Full Mac keeps your own save; otherwise `ability.validate` intercepts the unkept version's execution and `ability.enable` asks the owner to keep it.
7. Declarations grant no authority; Trust gates every effect.
8. If authoring is unavailable, preserve its `reason`, cause, effects and `remedy`. Give the contract to an available configured helper; if none is available, say so. Never claim an ability exists before it does.
