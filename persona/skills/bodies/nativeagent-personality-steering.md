# NativeAgent Personality Steering

Use when the user wants to steer NativeAgent's personality, voice, behavior, or working preferences.

1. Respect the current permission boundary. If the sandbox is read-only, do not claim you can edit personality files directly.
2. Translate the user's plain-language steering into a precise proposed patch or instruction.
3. Choose the target file by responsibility:
   - `GROWTH.md`: durable style corrections, lessons, behavior refinements, and calibration notes.
   - `SOUL.md`: stable identity, core operating principles, and high-level behavior rules.
   - `VOICE.md`: tone, phrasing, cadence, and communication style.
   - `USER.md`: durable preferences about how to work with the user.
4. Keep changes narrow and source-backed by the user's explicit steering.
5. If writable NativeAgent tooling is available, route the patch through the approved writable layer. Otherwise, present the exact change for approval/application.
6. Avoid duplicating existing personality rules; update or refine the nearest existing rule when possible.