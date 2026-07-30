# Untrusted Script Review

Use this skill when a user is asked to run or save a third-party script, command, installer, or config updater.

## Rule

Do not run vague or unseen scripts. Treat scripts as untrusted until their contents, purpose, and side effects are clear.

## Workflow

1. Ask for the exact script contents or command before execution.
2. Identify what the script reads, writes, downloads, executes, or persists.
3. Ask what config it is expected to change and why it must be saved locally.
4. Check for high-risk patterns:
   - `curl | sh` or `wget | sh`
   - `bash <(...)`
   - `sudo`
   - writes to `~/.ssh`, shell profiles, env files, launch agents, cron jobs, system directories, or package manager hooks
   - token, key, credential, browser, mail, or message access
   - network calls, remote code downloads, telemetry, or phone-home behavior
5. Prefer running only the needed safe parts manually.
6. Back up any config file before allowing edits.
7. If the sender cannot clearly explain what the script does, recommend not running it.

## Response Pattern

Start with a direct warning such as: `Don't run it yet.` Then request the script contents and explain the review steps concisely.