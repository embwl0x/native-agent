# Shared folder controls

Production sharing and search sections, rendered in DEBUG without a window,
screen capture, AppModel, or user data. The shared BotsShelfSnapshots helper
uses an unattached NSHostingView followed by ImageRenderer so native fields
and checkboxes appear correctly. All eight light/dark PNGs were inspected.

Choose Folder fills the editable name and exact path. Sharing still requires
the existing explicit action and retains the write-access choice. Search
shows untouched, searching, empty, or failed state locally; successful results
retain the eight-row presentation and identify additional loaded matches.

Validation (2026-09-09):

- NativeAgentApp product build with --disable-build-manifest-caching: passed.
- NativeAgentAppTests target build: passed.
- Existing SettingsReportsOnlyWave9ActionTests suite: 9 tests passed.
- After the DEBUG rendering correction, both builds and the existing
  workspaceSearchActionReturnsTheRuntimeCapAfterAColdActionReload test passed.
- Timer inventory: passed, 192 sites; no timer changes.
- Architecture blueprint: passed, 16 families / 507 table rows.
- git diff --check: passed.

Reproduce the images by setting CONNECTORS_SNAPSHOT_DIR to this directory
when running the existing shared-folder search test. Use the task's required
Git configuration exports and --force-resolved-versions --skip-update flags.
No additional test cases or gates were introduced.

The native chooser was not opened, and the app was not installed or launched.
Existing backend limitation outside this area: nonexistent shared folders are
silently skipped during search. Thrown search failures now have distinct UI.
