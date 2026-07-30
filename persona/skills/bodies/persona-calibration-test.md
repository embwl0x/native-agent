# Persona Calibration Test

Use when a user says an assistant persona feels generic or unlike a named character/personality.

## Workflow

1. Treat the issue as prompt/style shaping first, not model capability, unless there is evidence of missing domain knowledge or tool behavior.
2. Identify the persona's decision style and cadence:
   - What kinds of calls should it make quickly?
   - What filler should it avoid?
   - What emotional tone should be present without becoming performative?
3. Replace generic assistant phrasing with concrete behavioral rules, such as:
   - Direct call in the first sentence.
   - Fewer balanced disclaimer paragraphs.
   - Natural contractions.
   - Specific next action.
   - Warmth without customer-service language.
4. Test with paired prompts covering several modes:
   - frustration
   - ambiguity
   - quick technical triage
   - boundary refusal
   - casual check-in
5. Score outputs against a small rubric tailored to the persona. Prefer observable criteria over vibe-only judgments.
6. Iterate the prompt until the persona remains recognizable across all test categories, especially under refusal or uncertainty.