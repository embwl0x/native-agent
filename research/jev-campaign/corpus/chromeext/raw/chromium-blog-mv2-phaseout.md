<!-- url: https://blog.chromium.org/2024/05/manifest-v2-phase-out-begins.html -->
<!-- fetched: 2026-09-17 -->

Chromium

## Manifest V2 phase-out begins

May 30, 2024

|

-

x.com

-

Facebook

-

LinkedIn

-

Mail

-

Copy link

David Li

Product Manager, Chrome Extensions

Share

-

x.com

-

Facebook

-

LinkedIn

-

Mail

-

Copy link

Update (10/10/2024): We’ve started disabling extensions still using Manifest V2 in Chrome stable. Read more details in the MV2 support timeline documentation .
In November 2023, we shared a timeline for the phasing out of Manifest V2 extensions in Chrome. Based on the progress and feedback we’ve seen from the community, we’re now ready to roll out these changes as scheduled.
We’ve always been clear that the goal of Manifest V3 is to protect existing functionality while improving the security, privacy, performance and trustworthiness of the extension ecosystem as a whole. We appreciate the collaboration and feedback from the community that has allowed us - and continues to allow us - to constantly improve the extensions platform.
Addressing community feedback
We understand migrations of this magnitude can be challenging, which is why we’ve listened to developer feedback and spent years refining Manifest V3 to support the innovation happening across the extensions community. This included adding support for user scripts and introducing offscreen documents to allow extensions to use DOM APIs from a background context. Based on input from the extension community, we also increased the number of rulesets for declarativeNetRequest, allowing extensions to bundle up to 330,000 static rules and dynamically add a further 30,000. You can find more detail in our content filtering guide . 
This month, we made the transition even easier for extensions using declarativeNetRequest with the launch of review skipping for safe rule updates . If the only changes are for safe modifications to an extension’s static rule list for declarativeNetRequest, Chrome will approve the update in minutes. Coupled with the launch of version roll back last month, developers now have greater control over how their updates are deployed.
Ecosystem progress
After we addressed the top issues and feature gaps blocking migration last year, we saw an acceleration of extensions migrating successfully to Manifest V3. Over the past year, we’ve even been able to invite some developers - such as Eyeo, the makers of Adblock Plus - and GDE members like Matt Frisbie to share their experiences and insights with the community through guest posts and YouTube videos .
Now, over 85% of actively maintained extensions in the Chrome Web Store are running Manifest V3, and the top content filtering extensions all have Manifest V3 versions available - with options for users of AdBlock, Adblock Plus, uBlock Origin and AdGuard.
What to expect next
Starting on June 3 on the Chrome Beta, Dev and Canary channels, if users still have Manifest V2 extensions installed, some will start to see a warning banner when visiting their extension management page - chrome://extensions - informing them that some (Manifest V2) extensions they have installed will soon no longer be supported. At the same time, extensions with the Featured badge that are still using Manifest V2 will lose their badge.
This will be followed gradually in the coming months by the disabling of those extensions. Users will be directed to the Chrome Web Store, where they will be recommended Manifest V3 alternatives for their disabled extension. For a short time after the extensions are disabled, users will still be able to turn their Manifest V2 extensions back on, but over time, this toggle will go away as well.
Like any big launches, all these changes will begin in pre-stable channel builds of Chrome first – Chrome Beta, Dev, and Canary. The changes will be rolled out over the coming months to Chrome Stable, with the goal of completing the transition by the beginning of next year. Enterprises using the ExtensionManifestV2Availability policy will be exempt from any browser changes until June 2025.
We’ve shared more information about the process in our recent Chrome extensions Google I/O talk . If you have any additional questions, don’t hesitate to reach out via the Chromium extensions mailing list.

Posted in:
