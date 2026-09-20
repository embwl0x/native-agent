# Answer key — frozen question set (arm two)

Maps QUESTIONS.md Q1–Q7 to the gold answers in `gold.md`. Do not expose to the system under test.

**Q1 — Chrome 138 + ExtensionManifestV2Availability, then 139.**
Answer: Yes, they run on 138 — Chrome 138 is the final version supporting MV2 *when paired with the policy key*. On Chrome 139 the policy is removed and MV2 stops functioning, for all users at once, not as a gradual rollout.
Requires: 095a5599 + 79250f1d.
Changes practice: Yes. It sets the hard date for a fleet's migration; getting it wrong means either migrating a year early or being broken on a forced update.

**Q2 — 12,000 dynamic redirect rules.**
Answer: No. The 30,000 dynamic allowance covers only *safe* rules (block, allow, allowAllRequests, upgradeScheme). redirect is unsafe, capped at 5,000, and those unsafe rules also count against the 30,000.
Requires: 2741637b + a65606cd.
Changes practice: Yes. Determines whether a redirect-heavy blocker is buildable at all, or must move rules to static rulesets / other actions.

**Q3 — 4,000 regex rules in a static ruleset.**
Answer: No. Regex rules are capped at 1,000 per rule type regardless of the static allowance, and each must compile to under 2KB. The cap was untouched by every limit increase.
Requires: 7c82d4f5 (alone sufficient); a naive read of e8621005's 330,000 figure contradicts it.
Changes practice: Yes. Forces regex rules to be rewritten as urlFilter/pattern rules before the list is authored.

**Q4 — Blocking webRequest in MV3.**
Answer: Yes, but only for policy-installed extensions — webRequestBlocking remains available to them in MV3. Store-distributed MV3 extensions must use declarativeNetRequest. The exemption concerns MV3 extensions installed by policy, and is orthogonal to the MV2 deprecation.
Requires: 7fbc0fa1 + 688c66f7.
Changes practice: Yes. An enterprise-distributed product can keep a blocking interception architecture; a store product cannot.

**Q5 — Remote code execution in MV3.**
Answer: Generally no. Two named-API carve-outs exist (Debugger API, User Scripts API) and the exemption covers only the code within those APIs; plus insertCSS for remote *stylesheets*, devtools inspectWindow.eval, and chrome.debugger.sendCommand. Sandboxed/isolated contexts are exempt from the remote-code load restriction but full functionality must still be determinable.
Requires: a9519154 + 30473f4d.
Changes practice: Yes. Decides whether a config-driven or server-updated logic design can ship at all, and which narrow APIs are the only legal route.

**Q6 — Enabled static rulesets before Chrome 120.**
Answer: 10 enabled simultaneously, out of 50 offered. Raised to 50 enabled / 100 total in Chrome 120.
Requires: 05158f86. Reading only the current reference 7c82d4f5 gives the wrong answer (50).
Changes practice: Marginal today — historical/compatibility question; matters only when supporting older Chrome.

**Q7 — Review time for a static-rule-only update.**
Answer: It may qualify for expedited/skipped review and be approved in minutes rather than days, but only if the change is confined to safe modifications of the static rule list.
Requires: e8621005; scope limit reinforced by 7c82d4f5 / 2741637b's definition of safe rules.
Changes practice: Yes. Shapes release cadence — filter-list updates can ship same-day if the developer keeps code changes out of them.
