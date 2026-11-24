import Synchronization
import MacNerves
import AppKit
import SenseCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import os

// Blueprint: | `BodyField.swift` | Gated body joints, turn-free room readings, structural wakes and daily front-app and place happenings |

private struct BodyJointSnapshot: Sendable {
    var status: JSONValue = TurnBodyAccess.withheld
    var joints: [String: JSONValue] = [:]
    var digests: [String: JSONValue] = [:]
    var pid: pid_t?
    var document: URL?
    var entry: String?
    /// Read under admitted Full Mac: her own body, felt whether or not the person is here.
    var fullMac = false
    static let names = ["front", "browser", "files", "threads", "somatic"]
}

public actor BodyField {
    struct WindowsChanged: BodySignal {}
    private let latest = LatestRead()
    private var snapshot = BodyJointSnapshot()
    var room: MacRoom?
    var windows: Windows?
    private(set) var root: URL?
    private var bound: URL?
    private struct Edges {
        var binding = UUID()
        var activation = UUID()
        var motor = false
        var roomChanged = true
    }
    private let edges = Mutex(Edges())
    private var binding: UUID { edges.withLock { $0.binding } }
    private(set) var stopped = false
    private var nerve: MacBodyNerve?
    private var nerveToken: NSObjectProtocol?
    private var chrome: ChromeControlRuntime?
    private var network: Bool?
    private var microphoneInUse: Bool?
    private var nowOn: [String: String] = [:]
    private var lastDeliveredJointDigest: [String: [String: JSONValue]] = [:]
    private var openedObserver: NSObjectProtocol?
    private var notifications: [NotificationCenter.ObservationToken] = []
    private var streams: [UUID: Task<Void, Never>] = [:]
    private let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let frontEvents = AsyncStream<(MacBodyNerve.Edge, UUID, UUID)>.makeStream()
    private var authorityEvents: FileChangeEvents?
    private var fileEvents: FileChangeEvents?
    private var document: URL?
    private var fileState: JSONValue = .null
    private var entryDay: Date?
    private var entries: Set<String> = []
    private var posts: [UUID: Task<Void, Never>] = [:]
    private var drain: Task<Void, Never>?

    private nonisolated func receive(_ edge: MacBodyNerve.Edge) {
        edges.withLock { pending in
            switch edge {
            case .activated(_, _, _, let motor):
                pending.roomChanged = true
                pending.activation = UUID()
                pending.motor = pending.motor || motor
                if !motor { frontEvents.continuation.yield((edge, pending.binding, pending.activation)) }
            case .changed(let motor):
                pending.motor = pending.motor || motor
            case .terminated(_, _, let motor), .launched(_, _, _, let motor), .workspace(let motor):
                pending.motor = pending.motor || motor
                pending.roomChanged = true
            case .sleep, .wake, .sessionActive, .sessionInactive, .locked, .unlocked:
                pending.roomChanged = true
            case .focus, .raised, .personInterrupted: return
            case .sheet:
                frontEvents.continuation.yield((edge, pending.binding, pending.activation))
                return
            }
            changes.continuation.yield(())
        }
    }

    private func listen(_ work: @escaping @Sendable () async -> Void) {
        let id = UUID()
        streams[id] = Task {
            await work()
            streams[id] = nil
        }
    }

    nonisolated func closeFrontEvents() {
        edges.withLock { pending in
            pending.binding = UUID()
            frontEvents.continuation.finish()
        }
    }

    func start(_ root: URL, chrome: ChromeControlRuntime) {
        guard !stopped, nerve == nil else { return }
        self.root = root
        self.chrome = chrome
        windows = Windows(root)
        NotificationCenter.default.post(WindowsChanged())
        let changed = changes.continuation
        nerve = .shared
        nerveToken = MacBodyNerve.shared.listen { [weak self] edge in self?.receive(edge) }
        let center = NotificationCenter.default
        openedObserver = center.observeSynchronously(for: AgentOpened.Changed.self) { [weak self] in
            self?.edges.withLock { $0.roomChanged = true }
            self?.receive(.changed(agentDriven: false))
        }
        let bodyChanged: @Sendable () -> Void = { [weak self] in self?.receive(.changed(agentDriven: false)) }
        notifications = [
            center.addObserver(for: MacPersonInput.PresenceChanged.self) { _ in bodyChanged() },
            center.addObserver(for: ChromeControlRuntime.BodyTabsChanged.self) { _ in bodyChanged() },
            center.addObserver(for: ChromeControlRuntime.ConnectionDidChange.self) { _ in bodyChanged() },
        ]
        let authority = FileChangeEvents(paths: [ActivityPolicyStore(dataRoot: root).fileURL, SwiftNativeTrustCenter.policyURL(dataRoot: root)])
        authorityEvents = authority
        listen { for await _ in authority.stream { changed.yield(()) } }
        listen { [self] in
            for await _ in changes.stream {
                let motor = edges.withLock { pending in
                    defer { pending.motor = false }
                    return pending.motor
                }
                await refresh(agentDriven: motor)
            }
        }
        listen { [self] in
            for await (edge, epoch, activation) in frontEvents.stream {
                await frontEvent(edge, epoch: epoch, activation: activation)
            }
        }
        listen { [self] in for await up in NetworkSense.changes { await setNetwork(up) } }
        listen { [self] in
            for await inUse in MacBodyNerve.shared.microphone.changes { await setMicrophone(inUse) }
        }
        listen { [self] in for await _ in await chrome.activeTabUpdates() { receive(.changed(agentDriven: false)) } }
        refreshRoom(front: MacBodyNerve.shared.frontmostApplication?.localizedName, opened: AgentOpened.shared.recordedLaunches())
        changed.yield(())
    }

    func bind(_ root: URL) {
        guard !stopped else { return }
        bound = root
        edges.withLock { $0.binding = UUID() }
        latest.write { snapshot = BodyJointSnapshot() }
        changes.continuation.yield(())
    }

    func detach(_ root: URL) async {
        guard bound == root else { return }
        bound = nil
        edges.withLock { $0.binding = UUID() }
        latest.write { snapshot = BodyJointSnapshot() }
        let pending = Array(posts.values)
        await settle { for post in pending { await post.value } }
    }

    private func setNetwork(_ up: Bool) {
        network = up
        changes.continuation.yield(())
    }

    private func setMicrophone(_ inUse: Bool?) {
        guard microphoneInUse != inUse else { return }
        microphoneInUse = inUse
        changes.continuation.yield(())
    }

    func places(_ places: [String: String], dataRoot: URL) {
        guard root == dataRoot, places != nowOn else { return }
        nowOn = places
        changes.continuation.yield(())
    }

    private static func clean(_ text: String) -> String {
        String(NativeContextProjectionText.clean(ContextSecretContentPolicy.redactedFragment(text)).prefix(512))
    }

    private struct Front {
        let pid: pid_t
        let bundle: String
        let name: String
        var isBrowser: Bool { ActivityPolicy.browserBundleIDs.contains(bundle) || MacChromiumAccessibility.isChromiumBrowser(bundleId: bundle) }
        init?(_ running: NSRunningApplication? = MacBodyNerve.shared.frontmostApplication) {
            guard let app = running, let bundle = app.bundleIdentifier,
                  let name = app.localizedName, !name.isEmpty else { return nil }
            self.pid = app.processIdentifier
            self.bundle = bundle
            self.name = name
        }
    }

    private struct Console {
        let session: MacSessionState
        let here: Bool
        let fullMac: Bool
    }

    private func admitted(_ app: Front, root: URL, turn: Turn?, agentDriven: Bool = false,
                          heldSheet: Bool = false, activation: Bool = false) async throws -> Console? {
        guard !ActivityPolicy.defaultExcludedBundleIDs.contains(app.bundle),
              !ActivityPolicy.alwaysExcludedBundleIDs.contains(app.bundle) else { return nil }
        let origin = turn.map { SecurityOriginContext.currentTurn(turn: $0, surface: "chat", source: "mac:front") }
            ?? SecurityOriginContext(surface: "native_actions", source: "mac:front")
        let fullMac = await SwiftNativeSecurityCenter(dataRoot: root).fullMacYoloAuthority(origin: origin, turn: turn)
        let policy = try await Task.detached { try ActivityPolicyStore(dataRoot: root).loadChecked() }.value
        guard !policy.isExcluded(bundleID: app.bundle), policy.allowModelAccess || fullMac.admitted else { return nil }
        // Her body is hers: under admitted Full Mac she feels where things sit whether or not the person is at the Mac, and her own hands
        // moving it hide nothing (User 11-22: she works as him while he is away). Without Full Mac, the picture is the person's activity shared
        // with the model, so it reads only while the person is here and the move was theirs.
        let here = MacPersonInput.presence()?.here == true
        if !fullMac.admitted {
            guard here, heldSheet || !(agentDriven || MacBodyNerve.shared.isActing(pid: app.pid, foregroundOnly: activation)) else { return nil }
        }
        let session = defaultMacSessionStateSource().currentState()
        guard session.sessionReadable, session.onConsole, !session.obstructed, try !MacScreenLock.isCovered(),
              !stopped, !Task.isCancelled, MacBodyNerve.shared.frontmostApplication?.processIdentifier == app.pid else { return nil }
        return Console(session: session, here: here, fullMac: fullMac.admitted)
    }

    private static func stillPresent(_ pid: pid_t, fullMac: Bool, agentDriven: Bool = false) -> Bool {
        (fullMac || (!agentDriven && !MacBodyNerve.shared.isActing(pid: pid, foregroundOnly: true) && MacPersonInput.presence()?.here == true))
            && MacBodyNerve.shared.frontmostApplication?.processIdentifier == pid
    }

    private func sample(_ root: URL, turn: Turn?, app: Front?, opened: [pid_t: String], agentDriven: Bool = false) async -> BodyJointSnapshot {
        var next = BodyJointSnapshot()
        guard let app else { return next }
        let pid = app.pid, bundle = app.bundle, name = app.name
        do {
            guard let console = try await admitted(app, root: root, turn: turn, agentDriven: agentDriven) else { return next }
            let tabs = await chrome?.bodyTabs(for: pid)
            guard !stopped, !Task.isCancelled, Self.stillPresent(pid, fullMac: console.fullMac, agentDriven: agentDriven), let nerve else { return next }
            var front = nerve.observe(pid, agentDriven: agentDriven)
            let visibleTab = tabs?.active
            let browserWindow = app.isBrowser || tabs != nil
            let axDocument = front.removeValue(forKey: "document")?.stringValue
            let title = browserWindow ? visibleTab?.title : front["title"]?.stringValue
            front["title"] = title.map { .string(Self.clean($0)) }
            if let rawDocument = browserWindow ? visibleTab?.url : axDocument {
                if rawDocument.hasPrefix("/") { next.document = URL(fileURLWithPath: rawDocument, isDirectory: false) }
                else if let url = URL(string: rawDocument), url.isFileURL { next.document = url }
            }
            front["bundle_id"] = .string(bundle)
            front["app_name"] = .string(Self.clean(name))
            front["pid"] = .int(Int64(pid))
            front["document_path"] = next.document.map { .string(Self.clean($0.path)) }
            front["untrusted_data"] = .bool(true)
            next.joints["front"] = .object(front)
            let browser: JSONValue = visibleTab.map { tab in
                .object(["window_id": .int(Int64(tab.windowId)), "tab_id": .int(Int64(tab.tabId)),
                         "title": tab.title.map { .string(Self.clean($0)) } ?? .null,
                         "url": tab.url.map { .string(Self.clean($0)) } ?? .null, "audible": .bool(tab.audible)])
            } ?? .null
            next.joints["browser"] = .object(["active_tab": browser, "own_tabs": tabs.map { .array($0.owned.map(JSONValue.int)) } ?? .null,
                                              "untrusted_data": .bool(true)])
            next.joints["files"] = next.document.map { path in
                .object(["document_path": .string(Self.clean(path.path)), "change": path == document ? fileState : .null,
                         "untrusted_data": .bool(true)])
            } ?? .null
            let launches = opened.keys.sorted()
            next.joints["threads"] = .object(["opened_pids": .array(launches.map { .int(Int64($0)) }),
                                              "places": .object(nowOn.mapValues { .string(Self.clean($0)) }), "untrusted_data": .bool(true)])
            next.joints["somatic"] = .object(["locked": .bool(console.session.screenIsLocked), "on_console": .bool(console.session.onConsole),
                                               "person_here": .bool(console.here), "network_up": network.map(JSONValue.bool) ?? .null,
                                               "microphone_in_use": microphoneInUse.map(JSONValue.bool) ?? .null])
            for (joint, value) in next.joints {
                next.digests[joint] = value == snapshot.joints[joint] ? snapshot.digests[joint] : .string(try value.serializedSHA256())
            }
            next.pid = pid
            next.fullMac = console.fullMac
            next.entry = next.document?.path ?? visibleTab?.url.flatMap { URL(string: $0)?.host?.lowercased() }
            next.status = .object(["status": .string("available")])
            return next
        } catch { return BodyJointSnapshot(status: TurnBodyAccess.unavailable(error.localizedDescription)) }
    }

    private func refresh(agentDriven: Bool) async {
        guard let root, !stopped else { return }
        let front = MacBodyNerve.shared.frontmostApplication
        let opened = AgentOpened.shared.recordedLaunches()
        if edges.withLock({ pending in
            defer { pending.roomChanged = false }
            return pending.roomChanged
        }) { refreshRoom(front: front?.localizedName, opened: opened) }
        let epoch = binding
        _ = await latest.read {
            await sample(root, turn: nil, app: Front(front), opened: opened, agentDriven: agentDriven)
        } publish: { next in
            guard !stopped, binding == epoch else { return }
            let previous = snapshot
            if next.pid == nil, !agentDriven { nerve?.observe(nil) }
            guard previous.status != next.status || previous.joints != next.joints || previous.document != next.document else { return }
            snapshot = next
            watch(next.document)
            guard bound == root, let pid = next.pid, Self.stillPresent(pid, fullMac: next.fullMac, agentDriven: agentDriven), let front = next.joints["front"]?.objectValue,
                  let bundle = front["bundle_id"]?.stringValue else { return }
            let changed = BodyJointSnapshot.names.filter { previous.digests[$0] != next.digests[$0] }
            for joint in changed {
                var payload: [String: JSONValue] = ["kind": .string(joint), "bundle_id": .string(bundle), "pid": .int(Int64(pid))]
                payload["window_id"] = front["window_id"]
                payload["has_sheet"] = front["has_sheet"]
                AbilityStore(dataRoot: root).signal("body.changed", payload)
            }
            // Her own hands moving the Mac are not the person entering a place.
            if !agentDriven, !edges.withLock({ $0.motor }), !MacBodyNerve.shared.isActing(pid: pid),
               let entry = next.entry, previous.pid != pid || previous.entry != entry {
                let day = Calendar.current.startOfDay(for: Date())
                if entryDay != day {
                    entryDay = day
                    entries.removeAll()
                }
                let key = SHA256Hex.of(utf8: bundle + "\u{0}" + entry)
                guard entries.insert(key).inserted else { return }
                let happening = Happening(.world, subject: "body:front", door: "mac:front",
                    words: "The front window entered a document or site in " + Self.clean(bundle) + ".",
                    once: "body:entry:\(day.timeIntervalSince1970):" + key)
                post(happening, root: root)
            }
        }
    }

    private func post(_ happening: Happening, root: URL) {
        let id = UUID()
        let posting = Attention.post(happening, dataRoot: root)
        posts[id] = Task {
            await posting.value
            posts[id] = nil
        }
    }

    private func watch(_ url: URL?) {
        guard document != url else { return }
        fileEvents?.cancel()
        fileEvents = nil
        document = url
        fileState = .null
        guard let url else { return }
        let events = FileChangeEvents(paths: [url], emitInitial: false, observingGenerationAt: url)
        fileEvents = events
        listen { [self] in
            var iterator = events.stream.makeAsyncIterator()
            while let edge = await iterator.nextChange() {
                if await edge.isSelfWrite { continue }
                await fileObserved(.string(UUID().uuidString), events: events)
            }
            await fileObserved(TurnBodyAccess.unavailable("The document change observation closed."), events: events)
        }
    }

    private func fileObserved(_ state: JSONValue, events: FileChangeEvents) {
        guard fileEvents === events, fileState != state else { return }
        fileState = state
        changes.continuation.yield(())
    }

    func read(_ root: URL, turn: Turn, session: String, joint: String?) async -> JSONValue {
        guard !stopped, self.root != nil else { return TurnBodyAccess.unavailable("The Mac body field is closed.") }
        guard self.root == root, bound == root else { return TurnBodyAccess.withheld }
        guard let app = Front(), let nerve else { return TurnBodyAccess.withheld }
        let epoch = binding
        let picture: BodyJointSnapshot
        do {
            guard try await admitted(app, root: root, turn: turn) != nil else { return TurnBodyAccess.withheld }
            guard bound == root, binding == epoch else { return TurnBodyAccess.withheld }
            let ax = snapshot.joints["front"]?.objectValue?["status"]
            if joint == "front", snapshot.pid != app.pid || ax != .string("available") {
                await nerve.explicit(app.pid)
                picture = await sample(root, turn: turn, app: app, opened: AgentOpened.shared.recordedLaunches())
            } else if snapshot.pid != app.pid || app.isBrowser {
                picture = await sample(root, turn: turn, app: app, opened: AgentOpened.shared.recordedLaunches())
            } else {
                picture = snapshot
            }
        } catch { return TurnBodyAccess.unavailable(error.localizedDescription) }
        guard binding == epoch, bound == root, !Task.isCancelled else { return TurnBodyAccess.withheld }
        guard picture.pid == app.pid else { return picture.pid == nil ? picture.status : TurnBodyAccess.withheld }
        guard Self.stillPresent(app.pid, fullMac: picture.fullMac) else { return TurnBodyAccess.withheld }
        if let joint {
            guard let value = picture.joints[joint] else { return TurnBodyAccess.unavailable("Unknown body joint.") }
            var reply: [String: JSONValue] = ["status": .string("ok"), "atom_id": .string("body:" + joint), "joint": value, "untrusted_data": .bool(true)]
            if let cause = value.objectValue?["cause"] {
                reply["status"] = .string("unavailable")
                reply["cause"] = cause
            }
            return .object(reply)
        }
        var out = picture.joints
        out["digests"] = .object(picture.digests)
        if lastDeliveredJointDigest[session] == nil {
            lastDeliveredJointDigest[session] = picture.digests.filter { $0.key != "front" }
        }
        if let moved = BodyJointSnapshot.names.first(where: { lastDeliveredJointDigest[session]?[$0] != picture.digests[$0] }) {
            out["changed"] = .string(moved)
        }
        return .object(out)
    }

    func accepted(_ reading: JSONValue, root: URL, session: String) {
        guard self.root == root, !stopped, let joint = reading.objectValue?["joint"]?.stringValue,
              let digest = reading.objectValue?["digest"] else { return }
        lastDeliveredJointDigest[session, default: [:]][joint] = digest
    }

    private func frontEvent(_ edge: MacBodyNerve.Edge, epoch: UUID, activation: UUID) async {
        guard let root, bound == root, binding == epoch, !stopped, let app = Front() else { return }
        let happening: Happening
        let heldSheet: Bool
        switch edge {
        case .activated(let pid?, _, _, _):
            heldSheet = false
            guard app.pid == pid, edges.withLock({ $0.activation == activation }), Self.stillPresent(pid, fullMac: false) else { return }
            let person = await Task.detached { AgentScreen.names(root).person }.value
            let subject = "mac:front:" + app.bundle
            let day = await EngineDaySense.dayKey(Date())
            happening = Happening(.world, subject: subject, door: "mac:front",
                words: person + " is working in " + Self.clean(app.name) + ".", once: subject + ":" + day)
        case .sheet(let pid, let act):
            heldSheet = true
            guard app.pid == pid else { return }
            happening = Happening(.world, subject: "body:front", door: "mac:front",
                words: "A sheet opened in the app your hand was using.", once: "body:sheet:" + act)
        default: return
        }
        do {
            guard try await admitted(app, root: root, turn: nil, heldSheet: heldSheet, activation: !heldSheet) != nil,
                  bound == root, binding == epoch, edges.withLock({ $0.activation == activation }) else { return }
            if case .activated = edge, !Self.stillPresent(app.pid, fullMac: false) { return }
            post(happening, root: root)
        } catch { nativeLog("Front perception unavailable: %@", error.localizedDescription) }
    }

    func stop() async {
        if let drain { await drain.value; return }
        stopped = true
        NotificationCenter.default.post(AgentWorkspaceScreenPreview.DidChange())
        bound = nil
        if let nerveToken { nerve?.remove(nerveToken) }
        nerveToken = nil
        if let openedObserver { NotificationCenter.default.removeObserver(openedObserver) }
        openedObserver = nil
        for token in notifications { NotificationCenter.default.removeObserver(token) }
        notifications.removeAll()
        authorityEvents?.cancel()
        watch(nil)
        changes.continuation.finish()
        closeFrontEvents()
        let pending = Array(streams.values), posting = Array(posts.values), nerve = nerve
        for task in pending { task.cancel() }
        let closing = Task {
            await settle {
                await nerve?.stop()
                for task in pending + posting { await task.value }
            }
        }
        drain = closing
        await closing.value
    }
}
