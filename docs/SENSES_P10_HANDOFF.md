# P10 Senses surfaces handoff

Branch: `wA/s10-surfaces`. Work stayed in this worktree. No app launch,
quit, install, bridge call, separate automated tests or test targets.

## Built

- `Sources/NativeAgentApp/SensesView.swift`: native per-sense switches, corner/version, last use, uses/corrections, recorded growth cost, queued growth needs, recent grown versions and live news; optional daily USD budget input.
- `Sources/NativeAgentApp/ShellRailPages.swift`: Capabilities/Senses tabs.
- `Sources/NativeAgentApp/ContentView.swift`: routes Capabilities to those tabs.
- `Sources/NativeAgentApp/QuietSelfAdminRender.swift`: uses the same tabbed page for offscreen page reads.
- `Sources/NativeAgentApp/SetupView.swift`: Settings → Senses route and budget control.
- `Sources/NativeAgentApp/WorkPaneSenseView.swift`: separate script-enabled WKWebView, ephemeral data store, in-memory HTML, sealed navigation/resource policy, no file access, denied popups/media prompts, and exactly one sense-version event channel.
- `Sources/NativeAgentApp/WorkPane.swift`: conditional Sense tab when an enabled sense version presents a view.
- `Modules/NativeAgentCore/Sources/AgentWorkspace/HerScreen.swift`: compact MY SENSES section, bounded have/growing/just changed rows.
- `Modules/NativeAgentCore/Sources/Senses/SensesContract.swift`: additive cost and interactive-view/event seams (verbatim diff below).
- `Modules/NativeAgentCore/Package.swift`: AgentWorkspace depends on Senses.
- `project.yml`: app links Senses; regenerated with XcodeGen.
- `script/timer_inventory.tsv`: classifies the sole new sleep as visible_ui. Registry/ledger/news have no complete push invalidation API; sampling runs every five seconds only while the page or Work pane is mounted and stops on cancellation.
- `docs/ARCHITECTURE_BLUEPRINT.md`: surface owners and HerScreen projection.
- This file: exact contract/text/integration and installed-check handoff.

## Integration still needed

- P2 assembly must install the registry, ledger, runner and source into SensesHub.
- P6 should set `SenseRecord.growthCostUSD` with actual provider spend for the version. Historical/unrecorded costs remain nil and display “not recorded”; built-in versions display $0.
- The interactive-view producer calls `await SenseNewsBoard.shared.present(SenseInteractiveView(senseID:version:title:html:))`; call `present(nil)` to close it. Inline scripts/styles and data/blob images are supported. No network, external script assets or file URLs.
- P2's runner optionally conforms to `SenseViewEventReceiver` and forwards an event only to that sense/version, with door actions prohibited. UI code posts `window.webkit.messageHandlers.senseEvent.postMessage(<JSON value>)`. Only main-frame events, at most 16 KiB and one in flight, are accepted. The host checks the current enabled version before delivery. Without the receiver, an event produces an explicit visible error.
- Off uses the existing .archived status and On restores .on through registry.upsert. The lifecycle/launch owners must preserve User's archived choice. Drafts cannot be enabled here.
- Open ledger needs are labelled queued/waiting; the current contract does not publish active growth progress or per-attempt spend/failure history. No invented progress or cost.
- Home reads bounded actual owner snapshots. Just changed includes grown versions and live sense news from the past day.
- No executable behavior is stubbed inside P10; missing external owners are surfaced explicitly. Installed rendering and the sealed WebKit policy still require a direct check after integration.
- The external Agent handoff was not updated: this package explicitly restricts writes to this worktree and forbids bridge calls.

## Contract changes, verbatim

```diff
diff --git a/Modules/NativeAgentCore/Sources/Senses/SensesContract.swift b/Modules/NativeAgentCore/Sources/Senses/SensesContract.swift
index 935f6ff8f..68dc988ca 100644
--- a/Modules/NativeAgentCore/Sources/Senses/SensesContract.swift
+++ b/Modules/NativeAgentCore/Sources/Senses/SensesContract.swift
@@ -153,15 +153,19 @@ public struct SenseRecord: Codable, Sendable, Hashable {
     public var lastUsedAt: Date?
     public var uses: Int
     public var corrections: Int
+    /// Provider spend to grow this version, in USD; nil means not recorded.
+    public var growthCostUSD: Double?
 
     public init(id: String, corner: SenseCorner, version: Int = 1, status: SenseStatus = .on,
                 language: SenseLanguage, mode: SenseMode = .onCall, origin: SenseOrigin,
                 reach: SenseReach = SenseReach(), entry: String?, verbs: [String] = [],
-                createdAt: Date, enabledAt: Date? = nil, lastUsedAt: Date? = nil, uses: Int = 0, corrections: Int = 0) {
+                createdAt: Date, enabledAt: Date? = nil, lastUsedAt: Date? = nil, uses: Int = 0, corrections: Int = 0,
+                growthCostUSD: Double? = nil) {
         self.id = id; self.corner = corner; self.version = version; self.status = status
         self.language = language; self.mode = mode; self.origin = origin; self.reach = reach
         self.entry = entry; self.verbs = verbs; self.createdAt = createdAt; self.enabledAt = enabledAt
         self.lastUsedAt = lastUsedAt; self.uses = uses; self.corrections = corrections
+        self.growthCostUSD = growthCostUSD
     }
 }
 
@@ -240,6 +244,26 @@ public protocol SenseRunner: Sendable {
     func run(_ record: SenseRecord, request: SenseRequest, source: SenseSourceProvider) async -> SenseOutcome
 }
 
+/// An offline interactive view. HTML is handed over as bytes, never a file
+/// URL; its sole event channel is tied to this exact sense version.
+public struct SenseInteractiveView: Codable, Sendable, Hashable {
+    public var senseID: String
+    public var version: Int
+    public var title: String
+    public var html: String
+
+    public init(senseID: String, version: Int, title: String, html: String) {
+        self.senseID = senseID; self.version = version; self.title = title; self.html = html
+    }
+}
+
+/// Optional runner capability. View events may update the sense's view or
+/// notebook; they are not SenseRequest.act and must never execute door actions.
+public protocol SenseViewEventReceiver: Sendable {
+    func receiveViewEvent(_ event: JSONValue, for record: SenseRecord,
+                          source: SenseSourceProvider) async throws
+}
+
 /// The registry: one lookup the door consults first.
 public protocol SenseRegistry: Sendable {
     func sense(for corner: SenseCorner) async -> SenseRecord?
@@ -384,6 +408,10 @@ public actor SenseNewsBoard {
     public static let shared = SenseNewsBoard()
     public static let capacity = 200
     private var items: [SenseNews] = []
+    private var view: SenseInteractiveView?
+
+    public func present(_ view: SenseInteractiveView?) { self.view = view }
+    public func interactiveView() -> SenseInteractiveView? { view }
 
     public func post(_ news: SenseNews) {
         items.append(news)
```

## Model-visible text changes, verbatim source

The new section label is `"MY SENSES"`. All its output strings are in this
helper (external corner keys/news are neutralized and clipped by HerScreen):

```swift
    private static func sensesRows(now: Date) async -> [String] {
        guard let registry = SensesHub.shared.registry else { return ["have: senses not connected yet"] }
        async let records = registry.all()
        async let needs = SensesHub.shared.ledger?.openNeeds() ?? []
        async let news = SenseNewsBoard.shared.latest(limit: 3)
        let all = await records
        let active = all.filter { $0.status == .on }.sorted { $0.corner.key < $1.corner.key }
        let corners = active.prefix(5).map { clip($0.corner.key, 36) }.joined(separator: ", ")
        var rows = ["have: " + (active.isEmpty ? "none yet" : corners)
            + (active.count > 5 ? " +\(active.count - 5) more" : "")]
        let pending = await needs
        if pending.isEmpty { rows.append("growing: nothing waiting") }
        else {
            rows.append("growing: " + pending.sorted { $0.lastAt > $1.lastAt }.prefix(3).map {
                clip($0.corner.key, 32) + ($0.urgency == .repair ? " (repair queued)" : $0.urgency == .upgrade ? " (upgrade queued)" : " (queued)")
            }.joined(separator: ", ") + (pending.count > 3 ? " +\(pending.count - 3) more" : ""))
        }
        let grown = all.filter { $0.origin == .grown && now.timeIntervalSince($0.createdAt) < 86_400 }
            .sorted { $0.createdAt > $1.createdAt }.prefix(2)
        let changes = grown.map { clip($0.corner.key, 32) + " v\($0.version) grew" }
            + (await news).filter { now.timeIntervalSince($0.at) < 86_400 }.prefix(2).map { clip($0.summary, 60) }
        rows.append("just changed: " + (changes.isEmpty ? "nothing recent" : changes.joined(separator: " · ")))
        return rows
    }
```

No new app actions, tool descriptions, prompt injection or persona changes.

## Check after install (integrator; P10 did not install)

1. Open Capabilities → Senses, then Settings → Senses. Confirm the same records, readable rows at narrow/wide sizes, and native controls in light/dark appearances.
2. Pick one enabled sense. Switch Off; wait at most five seconds and confirm .archived and disabled routing. Switch On; confirm the same version/counters and normal routing. Draft rows must remain disabled.
3. In Settings set Daily growth budget (USD) to 1.25. Confirm UserDefaults `NativeAgent.senses.growthBudgetPerDay` is 1.25 and P6 observes it. Set 0 and confirm unlimited growth. Enter a negative number; confirm an error and that the prior budget remains unchanged.
4. Read `app {}` once. Confirm MY SENSES has have, growing and just changed, with queued needs described as queued and at most the bounded corner/news excerpts.
5. From the integrated producer publish a view for one enabled version with one inline button posting `{kind:"select", value:"one"}` to senseEvent. Open Work → Sense; click once. Confirm only that sense/version receives the event and no door action executes.
6. In that same bounded view confirm network images/fetch/WebSocket/WebRTC, file loads, child frames, popups and navigation cannot escape the host; confirm inline script/local styling still works. Switch the presenting sense Off; the view must disappear on the next refresh and reject late events. Replace its version; the old channel must be cancelled.
7. Check the app remains responsive, then close the page/pane. No growth/provider/browser workload campaign is needed.

## Validation

XcodeGen, architecture and timer inventory passed; git diff --check passed.
The exact requested default build was attempted and blocked by sandbox writes
to the default module cache. With caches redirected into this worktree and
SwiftPM's manifest sandbox disabled (the outer sandbox remains in force), the
default Swift Build engine reached CoreMLModelCompile and was blocked by its
nested sandbox-exec invocation: sandbox_apply: Operation not permitted.

The same integrated app built successfully with SwiftPM's native engine, cached
dependencies and local module cache. Final run: Build complete! (59.08s),
including compilation of the corrected WebKit callbacks and linking NativeAgentApp:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/p10-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/p10-module-cache" \
swift build --disable-keychain -j 6 --disable-sandbox --skip-update \
  --disable-automatic-resolution --build-system native
```

No separate tests were created or run. No installed verification was performed,
as explicitly prohibited for this worker. Re-run the exact default build outside
the nested sandbox during integration, then perform the installed checks above.

Git staging failed: the sandbox denied creation of the worktree's index.lock.
All package files remain in this worktree, uncommitted and unpushed; no unrelated
dirty work was present at the start.
