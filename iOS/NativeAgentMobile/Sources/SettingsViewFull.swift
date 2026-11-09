import SwiftUI
import Foundation
import UIKit
import NativeAgentShared
// Blueprint: | `SettingsViewFull.swift` | Device settings, appearance and release version; shared refresh/availability; push diagnostics in Status |

enum SettingsMacHealthPresentation {
    static func versionText(_ version: String) -> String {
        version.components(separatedBy: "-dev.").first ?? version
    }

    static func uptimeText(_ launchedAt: Date, now: Date = Date()) -> String {
        let formatted = UserDisplayFormatters.humanizeDuration(max(0, now.timeIntervalSince(launchedAt)))
        return formatted.isEmpty ? "Unknown" : formatted
    }
}

enum SettingsLegalLinksPresentation {
    static func destination(for rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    static func unavailableText(for label: String) -> String {
        "\(label) link is unavailable in this build."
    }
}

struct SettingsViewFull: View {
    var opensConnection = false
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @StateObject private var store = SettingsStore()
    @ObservedObject private var turnActivity = PhoneTurnActivity.shared
    @State private var showRePairSheet = false
    @State private var pushedFace: FaceDestination?
    // The wrappers invalidate the projection when either device preference changes.
    @AppStorage(NativeAgentAppearance.storageKey) private var appearanceRawValue = NativeAgentAppearance.system.rawValue
    @AppStorage(HazeColor.key) private var hazeRawValue = HazeColor.defaultValue.rawValue
    private var session: FacePageSession { store.sync.pageSessions.page("phone-settings") }
    private var localControls: [PhoneLocalSetting] {
        [NativeAgentAppearance.settingControl, HazeSwatches.settingControl, turnActivity.settingControl]
    }

    var body: some View {
        ScrollViewReader { proxy in
            AlivePage(title: "Settings", line: "This iPhone, its link to the Mac, and the Mac's own settings.") {
                FaceView(face: appearanceFace, door: localDoor, session: session)
                FaceView(face: connectionFace, door: localDoor, session: session).id("connection")
                MobileFaceRows(page: "settings") { pushedFace = $0 }
                PhonePlacesSettings()
                PhoneSensesSettings()
                FaceView(face: aboutFace, door: localDoor, session: session)
            }
            .navigationDestination(item: $pushedFace) { $0.view }
            .onAppear { if opensConnection { proxy.scrollTo("connection", anchor: .top) } }
        }
        .macSyncErrorBanner()
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
        .fullScreenCover(isPresented: $showRePairSheet) {
            PairingView(onSkip: { showRePairSheet = false }, onPaired: {
                showRePairSheet = false
                UserDefaults.standard.set(false, forKey: "NativeAgentMobile.pairingSkipped")
                iCloudSyncEngine.shared.pairingStore = pairingStore
                iCloudBridge.shared.pairingStore = pairingStore
                if pairingStore.usesICloudTransport { bridgeClient.configureICloud() }
                else { bridgeClient.disconnect() }
            })
            .environmentObject(pairingStore)
            .safeAreaInset(edge: .bottom) { iOSSystemToastBar(center: SystemToastCenter.shared) }
        }
    }

    private var appearanceFace: PartFace {
        let rows = localControls.map { control -> PartFace.Row in
            let row = control.row()
            let drawn: PartFace.Control?
            if let value = row.value {
                if control.type == "boolean" { drawn = .init(on: value == "true", call: .init("phone.setting", ["id": .string(control.id)])) }
                else {
                    drawn = .init(options: control.choices.map { .init(id: $0, label: $0.capitalized) }, selected: value,
                        call: .init("phone.setting", ["id": .string(control.id)]))
                }
            } else { drawn = nil }
            return .init(id: control.id, title: control.label, detail: row.unavailableReason, control: drawn)
        }
        return .init(sections: [
            .init(id: "appearance", title: "Appearance", footer: "System follows this iPhone's appearance. Haze is the light behind every screen.",
                rows: Array(rows.prefix(2))),
            .init(id: "live-activities", title: "Live Activities", footer: """
                Task names include work from Mac, Telegram, helpers and bridges and may be visible while this iPhone is locked. \
                Without a Mac APNs key, activities start when this app opens or wakes; updates can be delayed while it is asleep.
                """, rows: Array(rows.dropFirst(2)) + (turnActivity.errorMessage.map { [.init(id: "activity-error", title: $0, tone: .failed)] } ?? []))
        ])
    }

    private var connectionFace: PartFace {
        var healthRows: [PartFace.Row] = []
        if let health = store.sync.health {
            healthRows = [.init(id: "state", title: "Health", value: health.ok ? "Reported healthy" : "Reported issue"),
                .init(id: "app", title: "App", value: health.app),
                .init(id: "version", title: "Version", value: SettingsMacHealthPresentation.versionText(health.version)),
                .init(id: "uptime", title: "Uptime", value: SettingsMacHealthPresentation.uptimeText(health.launchedAt))]
            if !store.availableFields.contains(.health) {
                healthRows.append(.init(id: "health-read", title: "The latest health snapshot could not be read.", detail: "Showing the last known report."))
            }
        } else { healthRows = [.init(id: "waiting", title: store.isLoading ? "Loading health snapshot…" : "No health report has reached this iPhone.")] }
        var rows = bridgeClient.connection.facts.map { item in
            PartFace.Row(id: item.label, title: item.label, detail: item.fact.lever, value: item.fact.line)
        }
        let presence = StatusConnectionPresentation.syncState(lastSyncedAt: bridgeClient.lastSeenAt, staleAfter: NAMacPresence.phoneWindow)
        rows.append(.init(id: "last-seen", title: "Mac last seen", value: StatusConnectionPresentation.cardValue(for: presence),
            tone: StatusConnectionPresentation.needsAttention(presence) ? .attention : .plain))
        if pairingStore.isICloudSigned, let detail = StatusConnectionPresentation.presenceDetail(for: presence) {
            rows.append(.init(id: "presence", title: detail, tone: .quiet))
        }
        rows += [.init(id: "refresh", title: "Mac updates", actions: [.init(id: "check", label: "Check for Mac updates",
            call: .init("phone.connection.refresh"))]),
            .init(id: "pair", title: pairingStore.isICloudSigned ? "Pair with Mac" : "Set up Mac connection", actions: [
                .init(id: "pair", label: "Pair with Mac", call: .init("phone.connection.pair"))]),
            .init(id: "repair", title: "Connection repair", actions: [.init(id: "repair", label: "Repair connection",
                call: .init("phone.connection.repair"), unavailable: pairingStore.isRepairingConnection ? "Repair is already running." : nil)]),
            .init(id: "pairing-version", title: "Pairing version", value: String(pairingStore.knownSecretVersion))]
        return .init(sections: [.init(id: "mac", title: "Mac", rows: healthRows),
            .init(id: "connection", title: "Connection", footer: "Keep NativeAgent open on the Mac so a current report can reach this iPhone.", rows: rows),
            .init(id: "on-mac", title: "On your Mac", rows: [
                .init(id: "connectors", title: "Connectors", detail: "Telegram and the other services I can reach", open: "page:connectors"),
                .init(id: "providers", title: "Providers", detail: "The models I think with", open: "page:providers")
            ])])
    }

    private var aboutFace: PartFace {
        var rows = [("Privacy Policy", "NativeAgentPrivacyPolicyURL"), ("Support", "NativeAgentSupportURL")].map { title, key in
            if let url = SettingsLegalLinksPresentation.destination(for: Bundle.main.object(forInfoDictionaryKey: key) as? String) {
                return PartFace.Row(id: key, title: title, open: "url:" + url.absoluteString)
            }
            return PartFace.Row(id: key, title: title, detail: SettingsLegalLinksPresentation.unavailableText(for: title))
        }
        rows.append(.init(id: "phone-version", title: "Version", value: SettingsMacHealthPresentation.versionText(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")))
        return .init(sections: [.init(id: "about", title: "About", rows: rows)])
    }

    private var localDoor: ClosureFaceDoor {
        ClosureFaceDoor(open: { link in
            if let destination = FaceDestination(link) { pushedFace = destination }
            else if link.hasPrefix("url:"), let url = URL(string: String(link.dropFirst(4))) { UIApplication.shared.open(url) }
        }, waitingOn: "this iPhone's settings or the Mac connection") { submission in
            do {
                if submission.expectedCall.action == "phone.setting" {
                    guard let id = submission.expectedCall.args["id"]?.stringValue,
                          let control = localControls.first(where: { $0.id == id }), let write = control.write else {
                        throw PhoneLocalSetting.failure("Read this iPhone setting before changing it.")
                    }
                    if !submission.checking {
                        guard let value = submission.value else { throw PhoneLocalSetting.failure("The setting needs its new value.") }
                        if control.type == "boolean" {
                            guard ["on", "off"].contains(value) else { throw PhoneLocalSetting.failure("The switch takes on or off.") }
                            let wanted = value == "on" ? "true" : "false"
                            if try control.read() != wanted { try await write(wanted, .person) }
                        } else if try control.read() != value { try await write(value, .person) }
                    }
                    let saved = try control.read()
                    let readback = control.type == "boolean" ? (saved == "true" ? "on" : "off") : saved
                    return .init(effects: .known, accepted: true, committed: [.init(id: "value", value: .string(readback))])
                }
                if submission.checking { return .init(words: "Read Connection for the current evidence.", effects: .unknown) }
                switch submission.expectedCall.action {
                case "phone.connection.pair": showRePairSheet = true
                case "phone.connection.repair":
                    try await bridgeClient.repairConnection()
                    showRePairSheet = true
                case "phone.connection.refresh":
                    let changed = await pairingStore.refreshFromCloudKit()
                    let result = await store.refresh()
                    let words = SettingsICloudRefreshPresentation.statusText(pairingMaterialChanged: changed, snapshotError: result.feedbackMessage)
                    if let error = result.feedbackMessage { throw SyncError.unsupported(error) }
                    return .init(words: words, effects: .known, accepted: true)
                default: throw PhoneLocalSetting.failure("This Settings action is unavailable.")
                }
                return .init(effects: .none, accepted: true)
            } catch { return .phoneFailure(error) }
        }
    }
}

enum SettingsICloudRefreshPresentation {
    static func statusText(pairingMaterialChanged: Bool, snapshotError: String?) -> String {
        let pairingStatus = pairingMaterialChanged
            ? "New pairing material installed."
            : "No new pairing material was installed."

        guard let snapshotError,
              !snapshotError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(pairingStatus) Settings snapshot reload completed."
        }

        return "\(pairingStatus) \(snapshotError)"
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    let sync: iCloudSyncEngine
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var availableFields: Set<SettingsSnapshotRefreshOutcome.Field> = []
    @Published private(set) var hasCompletedRefresh = false
    private var refreshTask: Task<SettingsSnapshotRefreshOutcome, Never>?
    init(sync: iCloudSyncEngine = .shared) {
        self.sync = sync
    }

    @discardableResult
    func refresh() async -> SettingsSnapshotRefreshOutcome {
        if let refreshTask { return await refreshTask.value }
        isLoading = true
        let task = Task { @MainActor in
            let outcome = await sync.refreshSettingsSnapshot()
            error = outcome.feedbackMessage
            hasCompletedRefresh = true
            guard outcome.state != .superseded else { return outcome }
            availableFields = outcome.availableFields
            return outcome
        }
        refreshTask = task
        defer {
            refreshTask = nil
            isLoading = false
        }
        return await task.value
    }
}
