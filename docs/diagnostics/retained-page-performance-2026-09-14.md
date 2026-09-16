# NativeAgent retained-host final trace metrics — September 14, 2026

Measured installed final-mask build, process 95797, at 1040 × 712. Tests completed before recording. CA and CPU are separate recordings of the same four-cycle Trust scrolling workflow, not simultaneous samples. No matched pre-change percentage is claimed.

## Core Animation

Trace: `/tmp/nativeagent-retained-final-ca.trace`; exported table: `/tmp/nativeagent-retained-final-ca.xml`.
Trace start: 2026-09-14T16:24:16.883-05:00.

| Selection | Commits | Maximum | p95 | Over 16.7 ms |
| --- | ---: | ---: | ---: | ---: |
| Whole four-cycle interaction | 86 | 46.648 ms | 37.562 ms | 7 |
| Input windows only | 14 | 3.722 ms | 3.722 ms | 0 |

Input-overlap selection produces the same result as selecting commits whose start falls inside input. Percentiles use the nearest-rank method.

Warm cycles 1–3 contain two delayed commits each, starting 272–341 ms after cycle start, lasting 37–47 ms. Cycle 0 has one 21 ms commit beginning 66 ms after start. All seven exceedances occur after the provided input-end timestamps. This is not a whole-interaction frame-budget pass.

CA windows, Unix milliseconds (start / input end / cycle end):

```text
1789421061971 / 1789421062030 / 1789421062465
1789421062465 / 1789421062528 / 1789421063378
1789421063378 / 1789421063412 / 1789421064278
1789421064278 / 1789421064312 / 1789421065162
```

## CPU

Trace: `/tmp/nativeagent-retained-final-cpu.trace`; exported table: `/tmp/nativeagent-retained-final-cpu.xml`.
Trace start: 2026-09-14T16:23:34.182-05:00.

Main-thread sampled CPU in milliseconds. Categories are mutually exclusive by stack, using priority: external AX query, AX focus update, other AX work, layout/render, other. A category describes the sampled call path, not definitive application ownership.

| Cycle and phase | AX query | AX focus | Other AX | Layout/render | Other | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 input | 6 | 0 | 2 | 4 | 3 | 15 |
| 0 whole | 78 | 5 | 5 | 5 | 7 | 100 |
| 1 input | 4 | 0 | 0 | 6 | 2 | 12 |
| 1 whole | 65 | 7 | 26 | 56 | 21 | 175 |
| 2 input | 3 | 0 | 0 | 0 | 1 | 4 |
| 2 whole | 75 | 10 | 32 | 63 | 16 | 196 |
| 3 input | 2 | 0 | 0 | 4 | 6 | 12 |
| 3 whole | 60 | 6 | 27 | 56 | 26 | 175 |

The delayed work is not solely a hierarchy-query artifact. Warm cycles show one graph/render and accessibility-graph update burst at approximately +200–400 ms, followed by a separate external AX query burst at approximately +700–900 ms. `_XCopyHierarchy` accounts for 236 ms across the after-input intervals.

Within the three warm +200–400 ms bursts, inclusive sampled costs include window layout 225 ms, AttributeGraph update 197 ms, `AccessibilityViewGraph.needsUpdate` 76 ms, and accessibility initial-attachment work 23 ms (including 16 ms in combined-child attachment). Conventional `sizeThatFits` contributes only 15 ms there. These inclusive values overlap and must not be added.

This supports investigating scroll-driven accessibility attachment/preference invalidation. The optimized stacks do not distinguish hidden retained-host root replacement from visible Trust lazy-section updates. No named application host-update function is hot; app-specific samples consist of a two-millisecond geometry callback and one millisecond copying the mood-tint modifier. Absence of named app frames does not prove framework-only ownership. Neither hidden Chat nor native-control sizing is established as the dominant remaining owner.

CPU windows, Unix milliseconds (start / input end / cycle end):

```text
1789421019164 / 1789421020226 / 1789421020665
1789421020665 / 1789421020728 / 1789421021578
1789421021578 / 1789421021612 / 1789421022466
1789421022466 / 1789421022528 / 1789421023378
```

Conclusion: event-input handling is brief in this sample, but delayed graph/accessibility work still exceeds a 16.7 ms commit budget. These observations should not be presented as every UI frame passing or all remaining stalls being caused by external inspection.

## Isolated scrolling diagnostic, before the Trust loading fix

This subsequent recording intentionally omitted accessibility reads and screenshots until after tracing finished, to separate ordinary scrolling from follow-up inspection. It used the normal installed app (process 98074), without malloc stack logging and with no build active. It predates the pending fix for repeated loads when Trust lazy sections reappear.

Trace: `/tmp/nativeagent-isolated-scroll-ca.trace`; export: `/tmp/nativeagent-isolated-scroll-ca.xml`.
Trace start: 2026-09-14T16:29:06.969-05:00; duration: 15.270608 seconds.
Scroll input began at Unix ms **1789421351138** and ended at **1789421351198**. No follow-up AX read or screenshot occurred until **1789421370811**, after the trace ended. The later scrollbar value of 0.156 confirmed that scrolling occurred.

| Selection | Commits | Maximum / nearest-rank p95 | Over 16.7 ms |
| --- | ---: | ---: | ---: |
| Input | 3 | 0.408 ms | 0 |
| Input plus one second after input end | 9 | 21.400 ms | 1 |
| One second after input end, excluding input | 6 | 21.400 ms | 1 |
| Remaining trace | 1 | 24.824 ms | 1 |
| Whole trace | 10 | 24.824 ms | 2 |

The 21.3995 ms commit starts **68.313 ms after input begins**. The later 24.82425 ms commit starts **4,760.211 ms after input begins**. The repeated 40–47 ms pairs at approximately +270/+330 ms seen with immediate inspection did not occur in this isolated run.

This controlled omission of follow-up inspection supports inspection contributing to those paired delays. It does not prove the specific sharing-window mechanism, exclude all ordinary scrolling costs, or establish that every stall was caused by inspection. One smaller scroll-follow-through exceedance and one later update remain observable. These are pre-Trust-load-fix diagnostic results; a final isolated measurement is still needed for that change.

## Final isolated measurement after the Trust loading fix

Current installed changes, normal app process 99696, warm Trust page at 1040 × 712. Tests completed before tracing; malloc stack logging was off. This is the final measurement for the current changes.

Trace: `/tmp/nativeagent-trust-load-isolated-final.trace`; export: `/tmp/nativeagent-trust-load-isolated-final.xml`.
Trace start: 2026-09-14T16:34:05.182-05:00; duration: 15.273836 seconds.
Scroll began at Unix ms **1789421652796** and input ended at **1789421652881**. No AX read or screenshot occurred until **1789421668995**, after tracing ended.

| Selection | Commits | Maximum / nearest-rank p95 | Over 16.7 ms |
| --- | ---: | ---: | ---: |
| Input | 3 | 0.411 ms | 0 |
| Input plus one second after input end | 8 | 23.398 ms | 1 |
| One second after input end, excluding input | 5 | 23.398 ms | 1 |
| Remaining post-interaction trace | 0 | Not applicable | 0 |
| Whole trace, including activity before the scroll | 9 | 23.398 ms | 2 |

The scroll-follow-through commit lasts **23.397542 ms**, beginning **92.040 ms after input starts**. The second whole-trace exceedance is **22.865875 ms**, occurring **6,184.408 ms before input**, and must not be counted as a scrolling stall.

The comparable previous isolated run had one 21.3995 ms scroll-follow-through exceedance; the final run has one 23.397542 ms exceedance. These single runs show **no measured reduction in that scrolling latency** and do not support a percentage improvement claim. No later post-interaction commit occurred during the remainder of the final recording, whereas the preceding run had a 24.82425 ms event at +4.760 seconds; that absence is limited to this short recording and does not prove elimination of background updates.

Final conclusion: input handling is brief, and the repeated inspection-associated 40–47 ms pairs are absent during isolated scrolling. A single approximately 23 ms follow-through commit remains, so the final result is not an all-frames-under-16.7-ms claim. The loading fix addresses repeated section loads; this CA measurement alone does not prove the internal mechanism or a rendering speedup.
