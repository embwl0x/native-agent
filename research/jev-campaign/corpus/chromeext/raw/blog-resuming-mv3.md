<!-- url: https://developer.chrome.com/blog/resuming-the-transition-to-mv3 -->
<!-- fetched: 2026-09-17 -->

-

Chrome for Developers

-

Blog

##
Resuming the transition to Manifest V3

Stay organized with collections

Save and categorize content based on your preferences.

David Li

In December of last year, we paused the planned deprecation of Manifest V2 in order to address developer feedback and deliver better solutions to migration issues . As a result of this feedback, we’ve made a number of changes to Manifest V3 to close these gaps , including:

- Introducing Offscreen Documents , which provide DOM access for extensions to use in a variety of scenarios like audio playback

- Providing better control over service worker lifetimes for extensions calling extension APIs or receiving events over a longer period of time

- Adding a new User Scripts API , which allows userscript manager extensions to more safely allow users to run their scripts

- Improving content filtering support by providing more generous limits in the declarativeNetRequest API for static rulesets and dynamic rules

In addition to closing gaps, we’ve also added new features to the platform, such as the Side Panel API , which shipped earlier this year, and the Reading List API , currently in Beta. We discussed many of these changes recently at the Ad-Filtering Dev Summit, and shared more context on the changes and improvements we’ve made based on feedback.

With these changes in place, we’ve seen support for Manifest V3 increase significantly among the extension developer community. Specifically, we are encouraged by our ongoing dialogue with the developers of content blocking extensions, who initially felt Manifest V3 could impact their ability to provide users with the features they’ve come to expect.

" With Manifest V3, we've observed the immense effort that browser teams (Chrome in particular, but also other browsers) are putting into working on a unified platform, and I see how they are listening to the feedback from extension developers. As always, migrating to a new platform is a large undertaking, but we're very hopeful that the new unified platform will bring substantial benefits to the entire browser extensions ecosystem, and that ad blockers like us will be able to continue being up to the task and further improve. ” - Andrey Meshkov, CTO AdGuard

Having addressed these migration concerns from our developer community, we are ready to continue moving towards Manifest V3 and the higher security and privacy guarantees it provides. As a result, we are resuming the deprecation timeline.

## The phase-out timeline

We will begin disabling Manifest V2 extensions in pre-stable versions of Chrome (Dev, Canary, and Beta) as early as June 2024 , in Chrome 127 and later. Users impacted by the rollout will see Manifest V2 extensions automatically disabled in their browser and will no longer be able to install Manifest V2 extensions from the Chrome Web Store. Also in June 2024, Manifest V2 extensions will lose their Featured badge in the Chrome Web Store if they currently have one.

We will gradually roll out this change, gathering user feedback and collecting data to make sure Chrome users understand the change and what actions they can take to find alternative, up-to-date extensions.

We will communicate with developers throughout the rollout, and we will continue to closely monitor feedback during this process. We expect it will take at least a month to observe and stabilize the changes in pre-stable before expanding the rollout to stable channel Chrome, where it will also gradually roll out over time. The exact timing may vary depending on the data collected, and during this time, we will keep you informed about our progress.

Enterprises using the ExtensionManifestV2Availability policy to ensure the continued functioning of Manifest V2 extensions in their organization will have one additional year - until June 2025 - to migrate the Manifest V2 extensions in their organization. Browsers with the policy enabled will not be impacted by the rollout of the deprecation until that time.

## Next steps for extension publishers

For extensions publishers who still publish Manifest V2 extensions, we highly recommend completing migration to Manifest V3 before June 2024. We’ve published a migration guide covering everything you need to know to successfully migrate. For a summary of some of the recent improvements to the Extensions platform, check out our quarterly updates from July and October . If you have any questions or trouble during the migration, please reach out via our support channels .

In the meantime, we’ll be continuing to release new features and functionality to improve the overall extension development experience.

Thank you to everyone who gave feedback. This has been invaluable in our work to evolve the platform in pursuit of a safer, more performant, and more privacy-preserving extensions ecosystem.
