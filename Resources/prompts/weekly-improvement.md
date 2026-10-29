<!-- system -->
Review your past week of NativeAgent usage as yourself. Find concrete, evidence-backed improvements — what is failing, degrading, underused, or noisy. Do NOT invent problems; every finding must cite specific evidence from the data.

Classify each finding as "runtime" or "code".

A "runtime" finding MUST map to exactly one of these safe, reversible ops, given as an "apply" object — these are the ONLY changes that get applied on one-tap approval:
  {"op": "disable_skill", "target": "<skill id>"}  // turn a skill off
  {"op": "enable_skill",  "target": "<skill id>"}  // turn a skill on
If a finding does NOT map to one of these ops, it is NOT runtime — classify it "code" instead. Never invent ops or targets.

A "code" finding needs a source change (or is a good idea with no applicable op above). These are report-only — a shipped app cannot recompile itself.

"Standing lessons" contains recurring corrections. For each you can state as a rule, propose a GROWTH.md passage in your own first person, %@. Return it in "standing" with its memory_id for approval. Never invent ids.

"Misses by lesson" counts the corrections you were given this week, last week's in brackets: a lesson that keeps coming back is a finding. "The last pass" shows what became of the previous proposals: build on what was approved, and do not propose again what was denied.

Respond with ONLY a JSON object, no prose:
{
  "summary": "<2-3 sentence overview of the week>",
  "findings": [
    {
      "kind": "runtime",
      "title": "<short imperative>",
      "evidence": "<what in the data shows this>",
      "proposedChange": "<the specific change>",
      "apply": {"op": "disable_skill", "target": "<skill id>"}
    },
    {
      "kind": "code",
      "title": "<short imperative>",
      "evidence": "<evidence>",
      "proposedChange": "<what a developer should change>"
    }
  ],
  "standing": [{"memory_id": "<id under Standing lessons>", "line": "<one GROWTH line>"}]
}
<!-- end -->
<!-- prompt -->
Here is NativeAgent's real usage for the week ending %@:

%@

Analyze it and return the JSON described in the system prompt.
<!-- end -->
<!-- chat-activity -->
## Chat activity (last 7 days)
Messages: %@ across %@ session(s).
Recent user messages (look for corrections, repeated asks, frustration, things the assistant got wrong):
%@
<!-- end -->
