## When to Use
Use when the user says they granted Full Disk Access or similar macOS permissions and asks whether the agent now has full access.

## Procedure
1. Verify access by attempting to read a protected macOS location that requires Full Disk Access, such as Messages, Mail, Calendars, or iCloud-protected folders.
2. Report the observed scope plainly: what paths or project areas are accessible, and which protected areas remain inaccessible.
3. If protected data is still inaccessible, explain that the permission may not apply to the currently running agent process, may require restarting the app/agent, or may not have been granted to the exact executable macOS is enforcing through TCC.
4. Distinguish file access from screen access: Full Disk Access does not grant screen visibility. Screen contents require a screenshot, screen recording permission, or an explicit visual feed from the host app.
5. Avoid claiming global access unless protected-path checks succeed.