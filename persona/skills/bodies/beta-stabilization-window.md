# Beta Stabilization Window

Use this when a project is within roughly 2-4 weeks of a beta launch.

## Rule
Treat the remaining time as a stabilization window, not a feature window.

## Workflow
1. Calculate the actual number of days until launch.
2. Recommend freezing major capability or product shape within the first week.
3. Allocate the middle stretch to evals, reliability, install/update flow, regression testing, and crash-prone edge cases.
4. Reserve the final few days for packaging, release notes, onboarding, and a blunt known-issues list.
5. Identify the top trust breakers for the specific project, such as context bloat, agent voice consistency, app/runtime restart behavior, data loss, auth failures, or broken updates.
6. Push new ideas into post-beta follow-up unless they directly reduce beta risk.

## NativeAgent Emphasis
For NativeAgent, prioritize context bloat staying controlled, the configured agent's voice staying consistent under real tasks, and the installed Mac app behaving reliably across restarts.
