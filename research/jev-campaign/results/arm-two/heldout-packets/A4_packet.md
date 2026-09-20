# Source packet

You are given a set of documentation excerpts. Each is printed once, with its
identifier and what metadata is known about it.

## Research question

Assess what these sources actually establish about what is permitted, restricted or required: which restrictions changed, which survived a change and still apply, which exceptions hold only within a named scope, and where a correct answer depends on a source that is no longer current.

---

## 05158f86
product: Chrome for Developers Blog | version_label: Improving content filtering in Manifest V3 | date: 2023-11

Until recently, we allowed each extension to offer users a choice of 50 lists (or “static rulesets”), and for 10 of these to be enabled simultaneously. In discussions with the community, extension developers provided convincing evidence showing this was too low for certain use cases. After looking at the performance of the API in Chrome with these discussions in mind, we are now allowing up to 50 to be enabled simultaneously. (Notably, this is significantly higher than the limit of 20 requested in the WECG.) We also allow for 100 rulesets in total. This is shipping in Chrome 120 and increasing the limits is supported by both Firefox and Safari who both provided early input on this proposal.

## 095a5599
product: Chrome Extensions | version_label: Manifest V2 support timeline | date: 2025-03-31

All users on all channels of Chrome now have Manifest V2 extensions disabled by default, but users continue to be able to turn their Manifest V2 extensions back on. [...] Just as before, Enterprises using the ExtensionManifestV2Availability policy will continue to be exempt from any browser changes until at least June 2025. Starting in June, the branch for Chrome 139 will begin, in which support for Manifest V2 extensions will be removed from Chrome. Unlike the previous changes to disable Manifest V2 extensions which gradually rolled out to users, this change will impact all users on Chrome 139 at once. As a result, Chrome 138 is the final version of Chrome to support Manifest V2 extensions (when paired with the ExtensionManifestV2Availability key).

## 2741637b
product: Chrome for Developers Blog | version_label: Improving content filtering in Manifest V3 | date: 2023-11

We determined that some filter rules, such as those with an action of block or allow , are much safer and are less likely to be abused. [...] Starting with Chrome 121, the higher limit of 30,000 rules applies to safe DNR rules, which we are defining as rules with an action of block , allow , allowAllRequests or upgradeScheme . [...] This is available in Chrome as the MAX_NUMBER_OF_DYNAMIC_RULES constant. The rule limit for all other dynamic net request rules stays at 5,000.

## 688c66f7
product: Chrome Extensions | version_label: chrome.webRequest API reference | date: 2025-02

webRequestBlocking Required to register blocking event handlers. As of Manifest V3, this is only available to policy installed extensions. [...] As this function uses a blocking event handler, it requires the "webRequest" as well as the "webRequestBlocking" permission in the manifest file.

## a65606cd
product: Chrome Extensions | version_label: chrome.declarativeNetRequest API reference | date: 2025-06

An extension can have up to 5000 session rules. This is exposed as the MAX_NUMBER_OF_SESSION_RULES. Before Chrome 120, there was a limit of 5000 combined dynamic and session rules. [...] An extension can have at least 5000 dynamic rules. This is exposed as the MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES. Starting in Chrome 121, there is a larger limit of 30,000 rules available for safe dynamic rules, exposed as the MAX_NUMBER_OF_DYNAMIC_RULES. Any unsafe rules added within the limit of 5000 will also count towards this limit. Before Chrome 120, there was a 5000 combined dynamic and session rules limit.

## e8621005
product: Chromium Blog | version_label: Manifest V2 phase-out begins | date: 2024-05-30

Based on input from the extension community, we also increased the number of rulesets for declarativeNetRequest, allowing extensions to bundle up to 330,000 static rules and dynamically add a further 30,000. [...] This month, we made the transition even easier for extensions using declarativeNetRequest with the launch of review skipping for safe rule updates. If the only changes are for safe modifications to an extension’s static rule list for declarativeNetRequest, Chrome will approve the update in minutes. Coupled with the launch of version roll back last month, developers now have greater control over how their updates are deployed.

## f67dbbf9
product: Chrome for Developers Blog | version_label: Resuming the transition to Manifest V3 | date: 2023-11

We will begin disabling Manifest V2 extensions in pre-stable versions of Chrome (Dev, Canary, and Beta) as early as June 2024, in Chrome 127 and later. [...] Enterprises using the ExtensionManifestV2Availability policy to ensure the continued functioning of Manifest V2 extensions in their organization will have one additional year - until June 2025 - to migrate the Manifest V2 extensions in their organization. Browsers with the policy enabled will not be impacted by the rollout of the deprecation until that time.
