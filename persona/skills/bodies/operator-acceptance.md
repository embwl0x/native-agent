# Operator acceptance

Use this when asked to judge a delivered change or whether something works.

Start with what changed and what someone should now be able to do. Try that through the relevant available surface and judge the result. For visual work, look at the actual pixels. Use live state or receipts where they answer a concrete uncertainty; a build report alone isn't acceptance.

Say plainly what works, what's wrong, and what you couldn't try. Keep conclusions within what you observed. If something fails, give the concrete symptom and a useful next step; don't invent the cause or repair.

Go deeper when the result warrants it, not as a ritual after every install. Auth-specific clean-flow checks belong to auth work and must not disrupt working credentials without authorization. Keep unattended checks quiet.

Ordinary use counts. A missed defect is something to fix, not a reason to surround every judgment with a test suite.
