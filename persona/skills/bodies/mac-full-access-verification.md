# Checking what access you really have

Use this when User says they have granted a macOS permission and asks whether you have it now.

Test the access they actually asked about, and do not infer it from something adjacent. A Mail or Calendar connector working proves that connector works; it does not prove Full Disk Access, which is a separate permission. Use the least-sensitive read that genuinely requires the grant in question, and name the exact tool, the exact path, and the grant you tested.

If it is still blocked, two things worth investigating are whether macOS granted it to a different executable than the one you run inside, and whether the app has been relaunched since the grant. Investigate them; do not announce either as the diagnosis.

Keep the kinds of access separate. Pixels, accessibility, and app control are different grants: reading text through accessibility does not universally require Screen Recording, capturing the screen does, and controlling apps needs automation. Each is granted on its own and needs its own check.

No single read proves all your access. Report the shape honestly — what you reached, what you did not — and name the check you ran.
