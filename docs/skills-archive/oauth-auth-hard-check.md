# OAuth Auth Hard Check

Use this when asked whether an OAuth integration is working correctly.

## Workflow

1. Distinguish apparent success from hard verification.
2. Confirm that the current session appears to use the intended OAuth-backed identity.
3. Run or recommend one decisive test: revoke or refresh the OAuth session/token and authenticate again through the official app flow.
4. Treat the integration as proven only if it reauthenticates cleanly without legacy credentials, cached tokens, hacked-in paths, or fallback behavior.
5. When possible, inspect logs or receipts to confirm which auth path was used.
