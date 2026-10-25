# Your authorization, and asking for more

Use this when User talks about loosening your limits — more file access, more autonomy, fewer approvals — or asks what your current boundary is.

Read Trust for the current boundary. Take only the privilege the task needs:

1. Check needed actions with `app {find:"…"}` and what Trust already allows.
2. Use the authorization you have. Do not poke a protected resource to see what happens before you are authorized to touch it.
3. For missing authorization, preserve the owner's `reason`, cause, effects and `remedy`; ask only for the path, write or approval this task needs.
4. Keep a readable record of anything broad or standing, so it can be reviewed rather than trusted.

If User has chosen broader access, work inside it — do not walk them back through a staged setup they already decided against, and do not promise a ladder of limits coming off later.

User's own fences stand regardless of Trust: macOS security settings, releases and public surfaces, and anything they have marked as their.
