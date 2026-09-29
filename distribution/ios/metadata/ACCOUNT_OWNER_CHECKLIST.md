# App Store Connect owner checklist

These steps require the NativeAgent Apple Developer/App Store Connect account
and cannot be completed or truthfully verified from source alone.

## 0.5.0 build 15 — 2026-09-25

- [x] Claude's redesign and notification/approval fixes landed on private
  `main` at `dcda587ec`; this candidate bumps iOS to `0.5.0 (15)`.
- [x] Signed archive and local IPA export passed the release script from clean
  commit `c032c937c`; fresh production CloudKit schema, App Store signing,
  APNS, entitlements, privacy metadata, and icon checks passed. The archive
  completed with no compiler warnings.
- [x] Uploaded `0.5.0 (15)` through Xcode on 2026-09-25 at 17:24 CDT; Xcode
  reports **Uploaded to Apple**. This confirms transfer, not processing or
  TestFlight availability.
- [x] Apple processing completed; App Store Connect reports build 15
  **Validated**, with production APNS/CloudKit entitlements, iOS minimum 17.0,
  and no non-exempt encryption. The User Internal group (one tester) is attached,
  and build-specific What to Test guidance is saved.
- [x] Created the public `0.5.0` version draft in App Store Connect and saved
  its updated What's New text, promotional text, and App Review notes. Build 15
  is selected and saved; the version is **Ready for Review** in a draft
  submission. The final Submit for Review action has not been taken.
- [ ] Install the processed build on the physical phone and check chat,
  background and tapped notifications, and approval cards with the current Mac.
- [ ] Submit the ready `0.5.0` App Store draft for review after the physical
  check. Existing App Store screenshots still show the older UI; refresh them
  from the installed release when feasible.
- The Mac's proposal-approval action needs the next Mac DMG. Older Mac builds
  show “Answer on your Mac” on those cards; do not claim remote proposal
  decisions are available before that Mac release.

## 0.4.11 upload — 2026-09-12

App Store Connect showed `0.4.11` as **Ready for Distribution** on 2026-09-25;
the earlier unchecked processing and submission items below are historical
checklist entries, not the current live status.

- [x] Prepared `0.4.11 (14)` from approved private source `a1d4494df` plus
  version/build and release-note changes in
  `e5a30e0efda759d7242413dcf8acd1bd0fe48bed`.
- [x] Fresh production CloudKit export, release readiness, signed archive,
  local IPA export validation, and deterministic release-script checks passed.
  The approved source's 579-test iOS gate was supplied by the release owner;
  it was not rerun for the metadata-only release commit.
- [x] Uploaded through Xcode on 2026-09-12. Xcode reported **Upload succeeded**
  and **Uploaded package is processing** at 16:32 CDT.
- [ ] Confirm processing completed and build availability in TestFlight.
- [ ] Create/select the `0.4.11` App Store version, attach build 14, apply its
  release notes, verify existing review information/screenshots, and submit.
  App Store Connect browser sign-in is required; this version has not been
  submitted for review or verified as publicly released.

## Earlier release history and standing account checklist

- [x] Register the explicit iOS App ID
  `io.github.embwl0x.nativeagent.ios`.
- [x] Register the shared CloudKit container
  `iCloud.io.github.embwl0x.nativeagent` and associate it with both the iOS
  App ID and the Developer ID Mac App ID
  `io.github.embwl0x.nativeagent.mac`.
- [x] Create or confirm the App Store Connect app record using the exact iOS
  production bundle ID. Do not upload a build under a temporary identifier.
- [x] Confirm the marketing version and integer build number are greater than
  the prior App Store Connect build. App Store Connect verified on 2026-09-07:
  `0.4.1 (12)` is Ready for Distribution and is the latest uploaded build.
  Current update candidate: `0.4.6 (13)`.
- [x] Confirm the production iCloud container and deploy its CloudKit schema to
  production before TestFlight.
- [x] Confirm the App ID enables iCloud/CloudKit, push notifications, and
  time-sensitive notifications.
- Replace the required public metadata below in App Store Connect:
  - [x] Support URL: **https://nativeagent.app/support**
  - [x] Privacy policy URL: **https://nativeagent.app/privacy**
  - [x] Marketing URL: **https://nativeagent.app**
  - [x] Copyright/rights holder: **2026 NativeAgent**
- Complete App Privacy answers from the shipped binary and privacy policy.
- Provide review contact details and, if requested, pairing instructions. Never
  commit review credentials to this repository.
- [x] Upload the exported IPA with Xcode or Transporter.
  - [x] TestFlight `0.3.0 (10)` completed Apple processing, installed on the
    physical iPhone, paired to the production CloudKit Mac build, and passed
    current chat/provider/notification testing.
  - [x] `0.4.1 (12)` completed processing and is Ready for Distribution.
  - [x] `0.4.6 (13)` uploaded through Xcode on 2026-09-07 and completed Apple
    processing; available to the existing internal TestFlight group. Exact
    binary source: `096bd1c4c351deeecc6fac6887cc919d706c772b`.
    Signed archive/export and fresh production CloudKit checks passed;
    571 iOS simulator tests passed with zero skips, as did release fixtures.
  - [x] Submitted `0.4.6 (13)` for App Review on 2026-09-07. Apple reports
    **Waiting for Review**, with automatic release after approval. Submission:
    `4434bafd-00d0-44b4-8272-62c4e15b8813`. Not yet publicly released.
  - [ ] Verify `0.4.6 (13)` on a physical device; earlier build results below
    are historical evidence, not proof of this candidate.
- Test the processed build through TestFlight on a fresh, ordinary Apple
  account paired to a release Mac build.
- [x] Historical build 10: verify production iCloud/CloudKit pairing, provider/model projection,
  chat request/reply continuity, skills/tools snapshot sync, and explicit
  notification receipts on that TestFlight build.
- [x] With direct APNS disabled, verify three distinct CloudKit visual alerts
  about ten seconds apart while the phone remains locked. Build 10 passed 3/3.
- Verify approvals, memories, Workshop, offline/restart behavior, and a fresh
  ordinary Apple-account pairing before submitting for review.
- Add final screenshots for each required iPhone/iPad display class.
- For every new-app review, attach a current physical-device walkthrough that
  begins with app launch and shows the typical paired flow. Keep the seven-part
  Guideline 2.1 response in `APP_REVIEW_2_1_RESPONSE.md` current with the exact
  submitted build, tested devices/OS versions, setup path, external services,
  regional behavior, and regulatory/content status.
- Submit manually only after App Store Connect reports no missing compliance,
  privacy, export, age-rating, or availability fields.
