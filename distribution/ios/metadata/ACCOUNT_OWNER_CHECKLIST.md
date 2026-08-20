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
  the prior App Store Connect build. Approved App Store baseline: `0.3.0 (10)`.
  Current update candidate: `0.4.1 (11)`.
- [x] Confirm the production iCloud container and deploy its CloudKit schema to
  production before TestFlight.
- [x] Confirm the App ID enables iCloud/CloudKit, push notifications, and
  time-sensitive notifications.
- Replace the required public metadata below in App Store Connect:
  - [x] Support URL: **https://nativeagent.app/support**
  - [x] Privacy policy URL: **https://nativeagent.app/privacy**
  - [x] Marketing URL: **https://nativeagent.app**
  - Copyright/rights holder: **REQUIRED**
- Complete App Privacy answers from the shipped binary and privacy policy.
- Provide review contact details and, if requested, pairing instructions. Never
  commit review credentials to this repository.
- [x] Upload the exported IPA with Xcode or Transporter.
  - [x] TestFlight `0.3.0 (10)` completed Apple processing, installed on the
    physical iPhone, paired to the production CloudKit Mac build, and passed
    current chat/provider/notification testing.
  - [ ] Upload and process update candidate `0.4.1 (11)` after its release gate
    and physical-device verification pass.
- Test the processed build through TestFlight on a fresh, ordinary Apple
  account paired to a release Mac build.
- [x] Verify production iCloud/CloudKit pairing, provider/model projection,
  chat request/reply continuity, skills/tools snapshot sync, and explicit
  notification receipts on the current TestFlight build.
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
