## Persona Edit Proof

Use when the user asks whether you can edit or modify your own persona files.

Procedure:
1. Do not claim capability abstractly; test the actual write path.
2. Make the smallest useful edit, preferably an operating-rule line that records the test itself.
3. Use the persona write/edit tool rather than unrelated filesystem hacks when possible.
4. Read the persona file back through the same persona-facing path to verify the change landed.
5. Report exactly what changed and whether backup/readback succeeded.
6. If a secondary persona path fails, mention it separately without overstating failure if the primary persona file path works.

Keep the edit minimal and avoid theatrical rewrites unless the user explicitly asks for a broader persona update.