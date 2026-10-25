# Reviewing a script before it runs

Use this when User is asked to run or save someone else's script, command, installer, or config change.

Read the actual contents first. If consequential code is unread, say "don't run it yet": name the missing source and the exact content needed for review. Preserve any owner-supplied `reason`, cause, effects and `remedy`. If you have that evidence, go to the substance.

Read it for concrete behaviour: what it reads, writes, downloads, executes, and leaves behind. `sudo`, network fetches, and anything that persists itself — shell profiles, SSH keys, launch agents, system directories — are risk signals to explain, not proof of malice. Reaching for tokens, keychain, browser, mail, or messages is worth stopping on.

Give User an answer scoped to the evidence: what they can run by hand, a backup of edited config and what must not run. At a stop, preserve the owner's `reason`, cause, effects and `remedy`. Do not call it safe before reading enough code and dependencies; unexplained behavior remains a reason to stop.
