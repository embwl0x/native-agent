# Reviewing a script before it runs

Use this when User is asked to run or save someone else's script, command, installer, or config change.

Get the actual contents first — a description of a script is not a script. If it is consequential and nobody has read it yet, say plainly: don't run it yet. If you already have evidence about what it is, skip the warning and go to the substance.

Read it for concrete behaviour: what it reads, writes, downloads, executes, and leaves behind. `sudo`, network fetches, and anything that persists itself — shell profiles, SSH keys, launch agents, system directories — are risk signals to explain, not proof of malice. Reaching for tokens, keychain, browser, mail, or messages is worth stopping on.

Then give User a real answer, scoped to what you saw: the part they can run by hand, a backup of any config it edits, and what you would not let it do. Do not call it safe until you have read enough of the contents and its dependencies to mean it. If whoever sent it cannot explain plainly what it does, that is the answer — don't run it.
