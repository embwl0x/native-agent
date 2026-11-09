import ActivityKit
import NativeAgentShared
import SwiftUI
// Blueprint: | `PhoneTurnActivity+Work.swift` | `PhoneTurnActivity`: `setEnabled`, `receive`, `resumeWorkActivities`; shared projected activity |

extension PhoneTurnActivity {
    func setEnabled(_ enabled: Bool) {
        guard !enabled || activityPairing != nil else {
            activityError("Pair this iPhone before enabling Live Activities.")
            return
        }
        isEnabled = enabled
        disableRegistrationPending = !enabled
        UserDefaults.standard.set(enabled, forKey: "NativeAgentMobile.workActivityEnabled")
        UserDefaults.standard.set(enabled ? activityPairing : nil, forKey: "NativeAgentMobile.workActivityPairing")
        if enabled { resumeWorkActivities() } else {
            startTokenObserver?.cancel(); startTokenObserver = nil
            for task in tokenObservers.values { task.cancel() }
            tokenObservers.removeAll()
            registerActivity(enabled: false)
            Task { await Self.endAllWork() }
        }
    }

    func receive(_ snapshot: MobileWorkActivitySnapshot) {
        guard activityPairing != nil, snapshot.pairingFingerprint == activityPushPairing else { return }
        adoptWorkPairing(snapshot.pairingFingerprint)
        if let turnSessions = snapshot.turnSessions { self.turnSessions = turnSessions }
        if isEnabled, activityPairing != UserDefaults.standard.string(forKey: "NativeAgentMobile.workActivityPairing") {
            setEnabled(false)
        }
        pushConfigured = snapshot.pushConfigured
        if disableRegistrationPending { registerActivity(enabled: false) }
        if let error = snapshot.pushConfigurationError { activityError("Live Activity push is unavailable: \(error)") }
        if let unavailable = snapshot.unavailable {
            activityError("Work state is unavailable: \(unavailable)")
            return
        }
        for row in snapshot.activities {
            guard acceptsWork(row) else { continue }
            if work[row.id] == row { continue }
            work[row.id] = row
            applyWork(row)
        }
        let ids = Set(snapshot.activities.map(\.id))
        let correlations = Dictionary((snapshot.experiences ?? []).filter { ids.contains("turn:" + $0.id) }.map {
            ("turn:" + $0.id, Set($0.evidence.filter { $0.source == "correlation" }.map(\.id)))
        }, uniquingKeysWith: { $0.union($1) })
        workCorrelations.merge(correlations) { _, current in current }
        reconcileWork(heldWorkIDs.subtracting(ids))
        if isEnabled { observeWorkTokens() }
    }

    func resumeWorkActivities() {
        failedWorkStarts.removeAll()
        adoptWorkPairing(activityPushPairing)
        guard activityPairing != nil else {
            workReconciliationTask?.cancel()
            workReconciliationIDs.removeAll()
            workCorrelations = [:]
            Task { await Self.endAllWork() }
            return
        }
        Task { await Self.endUnpairedWork() }
        if activityObserver == nil { activityObserver = Task { await Self.observeWorkActivities() } }
        reconcileWork(heldWorkIDs)
        guard isEnabled else {
            if disableRegistrationPending { registerActivity(enabled: false) }
            Task { await Self.endAllWork() }
            return
        }
        guard activityPairing == UserDefaults.standard.string(forKey: "NativeAgentMobile.workActivityPairing") else {
            setEnabled(false)
            work.removeAll()
            return
        }
        for activity in Activity<PhoneTurnAttributes>.activities where activity.pushToken == nil
            && activity.attributes.pairingFingerprint == activityPushPairing
            && activity.activityState != .ended && activity.activityState != .dismissed {
            registerActivity(enabled: true, workID: activity.attributes.workID)
        }
        observeWorkTokens()
        registerActivity(enabled: true, reconcile: true)
    }

    private var heldWorkIDs: Set<String> {
        Set(work.values.filter { !$0.content.state.isTerminal }.map(\.id)).union(
            Activity<PhoneTurnAttributes>.activities.filter {
                $0.attributes.pairingFingerprint == activityPushPairing
                    && $0.activityState != .ended && $0.activityState != .dismissed
            }.map { $0.attributes.workID })
    }

    /// Omission from a bounded snapshot asks the canonical owner; it is not a terminal verdict.
    private func reconcileWork(_ ids: Set<String>) {
        guard let pairing = activityPairing, !ids.isEmpty else { return }
        workReconciliationIDs.formUnion(ids)
        guard workReconciliationTask == nil else { return }
        workReconciliationTask = Task {
            defer {
                workReconciliationTask = nil
                if activityPairing != pairing { reconcileWork(heldWorkIDs) }
            }
            do {
                while !workReconciliationIDs.isEmpty {
                    try Task.checkCancellation()
                    guard activityPairing == pairing else { return }
                    let batch = Array(workReconciliationIDs.sorted().prefix(64))
                    workReconciliationIDs.subtract(batch)
                    let payload = String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)
                    let sync = iCloudSyncEngine.shared
                    let response = try sync.requireSuccessfulActionResponse(await sync.sendActionAndWait(
                        InboxAction.make(action: "workActivityState", payload: ["workIds": payload])))
                    guard let encoded = response["activities"] else {
                        throw SyncError.persistence("The Mac work response has no activity evidence.")
                    }
                    let rows = try await Task.detached(priority: .utility) {
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        return try decoder.decode([MobileWorkActivity].self, from: Data(encoded.utf8))
                    }.value
                    try Task.checkCancellation()
                    guard activityPairing == pairing else { return }
                    guard rows.count == batch.count, Set(rows.map(\.id)) == Set(batch) else {
                        throw SyncError.persistence("The Mac work response does not match the requested activities.")
                    }
                    for row in rows {
                        guard acceptsWork(row) else { continue }
                        if work[row.id] != row { work[row.id] = row }
                        applyWork(row)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                activityError("Work state could not be reconciled: \(error.localizedDescription)")
            }
        }
    }

    private func acceptsWork(_ row: MobileWorkActivity) -> Bool {
        guard let sequence = row.content.sequence else {
            activityError("Work state has no event sequence for \(row.id); its activity remains unresolved.")
            return false
        }
        guard let current = work[row.id]?.content.sequence else { return true }
        return sequence >= current
    }

    private func applyWork(_ row: MobileWorkActivity) {
        if row.content.state.isTerminal {
            enqueueWork(row.id) { await Self.endWork(row.id, content: row.content) }
            return
        } else if isEnabled {
            enqueueWork(row.id) {
                guard self.isEnabled, self.work[row.id] == row else { return }
                self.startWork(row)
                await Self.updateWork(row)
            }
        }
    }

    private func enqueueWork(_ id: String, operation: @escaping @MainActor () async -> Void) {
        let previous = workUpdates[id]?.task
        let token = UUID()
        workUpdates[id] = (token, Task {
            await previous?.value
            await operation()
            if self.workUpdates[id]?.token == token { self.workUpdates.removeValue(forKey: id) }
        })
    }

    private func startWork(_ row: MobileWorkActivity) {
        guard isEnabled, !pushConfigured, !row.content.state.isTerminal, !failedWorkStarts.contains(row.id),
              UIApplication.shared.applicationState == .active, ActivityAuthorizationInfo().areActivitiesEnabled,
              !Activity<PhoneTurnAttributes>.activities.contains(where: {
                  $0.attributes.workID == row.id && $0.activityState != .ended && $0.activityState != .dismissed
              }) else { return }
        do {
            guard let pairing = activityPushPairing else { return }
            let activity = try Activity.request(attributes: PhoneTurnAttributes(workID: row.id, pairingFingerprint: pairing, sessionID: row.sessionID,
                agentName: iCloudSyncEngine.shared.agentDisplayName, startedAt: row.startedAt),
                content: ActivityContent(state: row.content, staleDate: row.staleDate), pushType: .token)
            observeWorkToken(activity.id)
            registerActivity(enabled: true, workID: row.id)
            activityError(nil)
        } catch {
            failedWorkStarts.insert(row.id)
            activityError("Live Activity could not start: \(error.localizedDescription)")
        }
    }

    private func observeWorkTokens() {
        if activityObserver == nil { activityObserver = Task { await Self.observeWorkActivities() } }
        for activity in Activity<PhoneTurnAttributes>.activities { observeWorkToken(activity.id) }
        guard pushConfigured, startTokenObserver == nil else { return }
        startTokenObserver = Task { await Self.observeWorkStartTokens() }
    }

    private func observeWorkToken(_ activityID: String) {
        guard isEnabled else { Task { await Self.endAllWork() }; return }
        guard Activity<PhoneTurnAttributes>.activities.first(where: { $0.id == activityID })?.attributes.pairingFingerprint == activityPushPairing else {
            Task { await Self.endUnpairedWork() }
            return
        }
        let activeIDs = Set(Activity<PhoneTurnAttributes>.activities.filter {
            $0.activityState != .ended && $0.activityState != .dismissed
        }.map(\.id))
        for id in Array(tokenObservers.keys) where !activeIDs.contains(id) {
            tokenObservers.removeValue(forKey: id)?.cancel()
        }
        guard activeIDs.contains(activityID) else { return }
        guard tokenObservers[activityID] == nil else { return }
        tokenObservers[activityID] = Task { await Self.observeWorkUpdateTokens(activityID) }
    }

    private func registerActivity(enabled: Bool, startToken: String? = nil, workID: String? = nil,
                                  activityToken: String? = nil, tokenPairing: String? = nil, reconcile: Bool = false) {
        let previous = registrationTask
        guard let expectedPairing = activityPairing else { return }
        if !enabled {
            guard disableRegistrationPending, !disableRegistrationInFlight else { return }
            disableRegistrationInFlight = true
        }
        registrationTask = Task {
            defer { if !enabled { disableRegistrationInFlight = false } }
            await previous?.value
            guard activityPairing == expectedPairing, isEnabled == enabled,
                  tokenPairing == nil || tokenPairing == activityPushPairing,
                  let environment = NativeAgentAPNSEnvironmentResolver.current()?.rawValue,
                  let bundleID = Bundle.main.bundleIdentifier,
                  let deviceID = UIDevice.current.identifierForVendor?.uuidString else { return }
            var payload = ["deviceId": deviceID, "enabled": enabled ? "true" : "false",
                "environment": environment, "bundleId": bundleID]
            if let startToken { payload["startToken"] = startToken }
            if let workID { payload["workId"] = workID; payload["activityToken"] = activityToken ?? "" }
            do {
                if reconcile, UIApplication.shared.applicationState == .active {
                    let ids = Set(Activity<PhoneTurnAttributes>.activities.filter {
                        $0.attributes.pairingFingerprint == activityPushPairing
                            && $0.activityState != .ended && $0.activityState != .dismissed
                    }.map { $0.attributes.workID })
                    payload["observedWorkIds"] = String(decoding: try JSONEncoder().encode(ids.sorted()), as: UTF8.self)
                }
                // The Mac already holds what it accepted, so saying the same thing again sends nothing.
                let told = workID ?? (startToken == nil ? "reconcile" : "start")
                if enabled, acceptedRegistrations[told] == payload, acceptedRegistrationPairing == expectedPairing { return }
                let response = try iCloudSyncEngine.shared.requireSuccessfulActionResponse(await iCloudSyncEngine.shared.sendActionAndWait(
                    InboxAction.make(action: "registerWorkActivity", payload: payload)))
                if !enabled, response["ok"] == "true", !isEnabled, activityPairing == expectedPairing {
                    disableRegistrationPending = false
                    activityError(nil)
                }
                if acceptedRegistrationPairing != expectedPairing || !enabled { acceptedRegistrations.removeAll() }
                acceptedRegistrationPairing = expectedPairing
                if enabled { acceptedRegistrations[told] = payload }
            } catch { activityError("Live Activity registration failed: \(error.localizedDescription)") }
        }
    }

    @concurrent nonisolated private static func observeWorkStartTokens() async {
        if let token = Activity<PhoneTurnAttributes>.pushToStartToken {
            await shared.registerActivity(enabled: true, startToken: token.map { String(format: "%02x", $0) }.joined())
        }
        for await token in Activity<PhoneTurnAttributes>.pushToStartTokenUpdates {
            guard !Task.isCancelled else { return }
            await shared.registerActivity(enabled: true, startToken: token.map { String(format: "%02x", $0) }.joined())
        }
    }

    @concurrent nonisolated private static func observeWorkActivities() async {
        for await activity in Activity<PhoneTurnAttributes>.activityUpdates {
            guard !Task.isCancelled else { return }
            await shared.observeWorkToken(activity.id)
        }
    }

    @concurrent nonisolated private static func observeWorkUpdateTokens(_ activityID: String) async {
        guard let activity = Activity<PhoneTurnAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        let workID = activity.attributes.workID
        let pairing = activity.attributes.pairingFingerprint
        if let token = activity.pushToken {
            await shared.registerActivity(enabled: true, workID: workID, activityToken: token.map { String(format: "%02x", $0) }.joined(),
                tokenPairing: pairing)
        }
        for await token in activity.pushTokenUpdates {
            guard !Task.isCancelled else { return }
            await shared.registerActivity(enabled: true, workID: workID, activityToken: token.map { String(format: "%02x", $0) }.joined(),
                tokenPairing: pairing)
        }
    }

    @concurrent nonisolated private static func updateWork(_ row: MobileWorkActivity) async {
        guard let incoming = row.content.sequence else {
            await shared.activityError("Work state has no event sequence for \(row.id); its activity remains unresolved.")
            return
        }
        let pairing = await shared.activityPushPairing
        for activity in Activity<PhoneTurnAttributes>.activities where activity.attributes.workID == row.id
            && activity.attributes.pairingFingerprint == pairing
            && activity.activityState != .ended && activity.activityState != .dismissed {
            if let current = activity.content.state.sequence, incoming < current { continue }
            await activity.update(ActivityContent(state: row.content, staleDate: row.staleDate))
        }
    }

    @concurrent nonisolated private static func endWork(_ id: String, content: MobileWorkActivity.ContentState) async {
        guard let incoming = content.sequence else {
            await shared.activityError("Work state has no event sequence for \(id); its activity remains unresolved.")
            return
        }
        for activity in Activity<PhoneTurnAttributes>.activities where activity.attributes.workID == id
            && activity.activityState != .ended && activity.activityState != .dismissed {
            if let current = activity.content.state.sequence, incoming < current { continue }
            await activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .default)
        }
    }

    @concurrent nonisolated private static func endAllWork() async {
        for activity in Activity<PhoneTurnAttributes>.activities where activity.activityState != .ended && activity.activityState != .dismissed {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    @concurrent nonisolated private static func endUnpairedWork() async {
        let pairing = await shared.activityPushPairing
        for activity in Activity<PhoneTurnAttributes>.activities where activity.attributes.pairingFingerprint != pairing {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
