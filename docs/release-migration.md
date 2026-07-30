# NativeAgent Release Migration Guide

_Added R10-N9. Last updated: 2026-06-21._

This document covers upgrade steps for operators and developers moving between
NativeAgent releases.

---

## Historical: Python Runtime Bundle Layout

This section records the retired R10-era Python bundle migration. It is not the
current release architecture. Current NativeAgent releases are Swift-native:
`NativeAgent.app` owns the live runtime in-process, and releases must not depend
on an external interpreter backend, launchd service, or interpreter files inside the app bundle.

Former migration notes:

- Older builds copied a single Python entry point into the app bundle.
- Transitional builds copied a Python module tree and added a compatibility
  symlink for custom deploy scripts.
- Those compatibility paths are retired for live runtime use. If a custom
  deploy pipeline still expects Python resources, remove that dependency before
  adopting a Swift-native release.

---

## Historical: Standalone Interpreter Hash Verification

Older development builds downloaded a standalone CPython archive and verified it
with a local SHA-256 constant. Swift-native releases do not bundle CPython for
the app runtime. Treat any required Python tooling as external developer tooling,
not as a release artifact or runtime dependency.

---

## State file format changes

### processed_ids.json (Mac)

- No format change. The file is a JSON array of UUID strings.
- R10-N8 adds corruption recovery: if the file is unreadable, the Mac starts
  with an empty deduplication window (safe — at worst a message is replayed once).

### pairings.json (retired LAN transport)

The LAN pairing file belonged to the retired network transport. Current iOS
pairing uses iCloud KVS/Drive with HMAC-signed envelopes.

### approvals/requests.json (retired runtime store)

Approval execution is now Swift-owned and receipt-backed. Historical approval
stores should be migrated or ignored according to the current app-owned import
path; do not start an old background service to process them.

---

## v1 → v2 upgrade checklist

1. **Stop any legacy launchd service** if one is still installed:
   `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.nativeagent.NativeAgentDaemon.plist`
2. **Build and install** the new bundle:
   `./script/install_app.sh`
3. **Launch `NativeAgent.app`** and verify the app UI opens. The live runtime is
   in-process; there is no separate health probe for an external interpreter backend.
4. **Check the iOS companion** through iCloud snapshots/actions if paired.
5. **Run release verification** before distribution:
   `./script/verify_release_artifact.sh --bundle dist/NativeAgent.app`
