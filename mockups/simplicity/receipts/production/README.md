# Production receipt evidence

These sheets render the actual `ToolPillView` from `ChatToolPillView.swift`.
The seven approved `TurnStreamEvent` fixtures pass through the production
`ChatMessageMetadata` decoder using the writer's `inputJSON` / `resultSummary`
keys. No tools execute and no resident data is loaded.

`collapsed-{light,dark}-{1280,1024-largest}-1.png` contains all seven states.
`expanded-{light,dark}-{1280,1024-largest}-{1,2}.png` contains the same sequence
on two consecutive pages, with the first receipt's Details open in place.
1280 sheets are 1280 × 800; largest-text sheets are 1024 × 700 and set
accessibility5. The production card explicitly scales its text to 19 pt for
accessibility sizes because fixed macOS fonts do not scale automatically.

The card registers the approved action-title table, retains unknown raw names,
shows argument targets, and classifies envelopes independently of `metadata.ok`.
The direct string result of `read_file` is a registered native completion
contract. Other tools need an explicit positive status to show Completed.
The projected gate error and `streamClosed` use their specific envelope forms;
arbitrary result prose is not searched for refusal or connection keywords.

Details remains in the same view identity and preserves the raw tool name,
existing input/result text selection and write-file diff. Existing redaction,
4,000-character model decode limits, 8,000-character detail display limits, and
diff limits remain. The collapsed target and summary are independently bounded
to 180 and 240 characters; Details retains the available underlying evidence.
Missing or malformed/clipped result JSON cannot prove completion. No new retry,
tool execution, timer, turn, or memory behavior is introduced.

Reproduce with the task's offline Git exports, then:

```sh
SIMPLICITY_RECEIPTS_ONLY=1 SIMPLICITY_SNAPSHOT_DIR="$PWD/mockups/simplicity" \
  swift test --force-resolved-versions --skip-update --jobs 4 \
  --filter 'AppChatReportOnlyTruthSeamsTests|MacHighRiskSurfaceBehaviorEvalTests/toolPillNeverTreatsMissingMetadataAsSuccess|BotsShelfTests'
```

Validation: Mac product build with `--disable-build-manifest-caching`,
`NativeAgentAppTests` target build, all 13 selected tests, timer inventory,
architecture blueprint, and `git diff --check` passed. All 12 PNGs were opened
and visually inspected. Keyboard handlers and accessibility labels are wired
in production; no interactive Mac UI or VoiceOver session was driven.

The Core helper's legacy `ok` treatment of partial/refused responses remains
outside this change; the production card no longer uses that bit as proof of
completion. The prior approved design PNGs remain untouched.
