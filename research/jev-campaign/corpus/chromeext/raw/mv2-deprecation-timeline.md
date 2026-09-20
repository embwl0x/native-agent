<!-- url: https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline -->
<!-- fetched: 2026-09-17 -->

-

Home

-

Docs

-

Chrome Extensions

-

Develop

##
Manifest V2 support timeline

Stay organized with collections

Save and categorize content based on your preferences.

Understand when Manifest V2 will stop working for extensions

## Aug 31st 2026: All remaining Manifest V2 extensions removed from the Chrome Web Store

All remaining Manifest V2 extensions are removed from the Chrome Web Store. Manifest V2 extensions installed on Chrome 138 or earlier will remain installed, but will be unable to receive any updates and cannot be reinstalled from the Chrome Web Store once removed from Chrome.

## Jul 24th 2025: Manifest V2 is disabled everywhere

With Chrome 138 all users on all channels of Chrome have now Manifest V2
extensions disabled. Users can no longer turn them back on.

For Enterprises, the
ExtensionManifestV2Availability
policy will be removed with Chrome 139. This change will affect all users on
Chrome 139 simultaneously.

Therefore, Manifest V2 extensions will cease to function for any user upgrading
to Chrome 139 and subsequent versions.
The Chromium release schedule
provides further release information.

## March 31st 2025: Manifest V2 is disabled with the option to re-enable extensions

All users on all channels of Chrome now have Manifest V2 extensions disabled by
default, but users continue to be able to turn their Manifest V2 extensions back
on. The second phase, where users can no longer be able to turn them back on has
begun to roll out to some users in Canary. This change will continue to slowly
roll out to more users.

Just as before, Enterprises using the
ExtensionManifestV2Availability
policy will continue to be exempt from any browser changes until at least June
2025. Starting in June, the branch for Chrome 139 will begin, in which support
for Manifest V2 extensions will be removed from Chrome. Unlike the previous
changes to disable Manifest V2 extensions which gradually rolled out to
users, this change will impact all users on Chrome 139 at once. As a result,
Chrome 138 is the final version of Chrome to support Manifest V2 extensions
(when paired with the ExtensionManifestV2Availability key). You can find the
release information about Chrome 138 and 139, include ChromeOS's LTS support, on
the Chromium release schedule

## October 9th 2024: an update on Manifest V2 phase-out.

Over the last few months, we have continued with the Manifest V2 phase-out.
Currently the chrome://extensions page displays a warning banner for all users
of Manifest V2 extensions. Additionally, we have started disabling Manifest V2
extensions on pre-stable channels.

We will now begin disabling installed extensions still using Manifest V2 in
Chrome stable. This change will be slowly rolled out over the following weeks.
Users will be directed to the Chrome Web Store, where they will be recommended
Manifest V3 alternatives for their disabled extension. For a short time, users
will still be able to turn their Manifest V2 extensions back on. Enterprises
using the
ExtensionManifestV2Availability
policy will be exempt from any browser changes until June 2025. See our May
2024 blog
for more context.

## June 3rd 2024: the Manifest V2 phase-out begins.

Starting on June 3rd on the Chrome Beta, Dev and Canary channels, if users still
have Manifest V2 extensions installed, some will start to see a warning banner
when visiting their extension management page - chrome://extensions - informing
them that some (Manifest V2) extensions they have installed will soon no longer
be supported. At the same time, extensions with the Featured badge that are
still using Manifest V2 will lose their badge.

## June 2022: Chrome Web Store - no new private extensions

Chrome Web Store stopped accepting new Manifest V2 extensions with visibility
set to "Private".

## January 2022: Chrome Web Store - no new public / unlisted extensions

Chrome Web Store stopped accepting new Manifest V2 extensions with visibility
set to "Public" or "Unlisted". The ability to change Manifest V2 extensions from
"Private" to "Public" or "Unlisted" was removed.
