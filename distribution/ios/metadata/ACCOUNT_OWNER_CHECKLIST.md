# App Store Connect owner checklist

These steps require the NativeAgent Apple Developer/App Store Connect account
and cannot be completed or truthfully verified from source alone.

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
