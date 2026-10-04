import ActivityKit
import NativeAgentShared
import SwiftUI

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
            for task in workExpirations.values { task.cancel() }
            workExpirations.removeAll()
            registerActivity(enabled: false)
            Task { await Self.endAllWork() }
        }
    }

    func receive(_ snapshot: MobileWorkActivitySnapshot) {
        guard activityPairing != nil, snapshot.pairingFingerprint == activityPushPairing else { return }
        if workPairing != snapshot.pairingFingerprint { work.removeAll(); workPairing = snapshot.pairingFingerprint }
        if isEnabled, activityPairing != UserDefaults.standard.string(forKey: "NativeAgentMobile.workActivityPairing") {
            setEnabled(false)
            work.removeAll()
            return
        }
        pushConfigured = snapshot.pushConfigured
        if disableRegistrationPending { registerActivity(enabled: false) }
        if let error = snapshot.pushConfigurationError { activityError("Live Activity push is unavailable: \(error)") }
        for row in snapshot.activities {
            guard row.content.updatedAt <= Date().addingTimeInterval(60),
                  row.content.updatedAt >= (work[row.id]?.content.updatedAt ?? .distantPast) else { continue }
            if work[row.id] == row { continue }
            work[row.id] = row
            applyWork(row)
        }
        let ids = Set(snapshot.activities.map(\.id))
        for activity in Activity<PhoneTurnAttributes>.activities where !ids.contains(activity.attributes.workID) {
            let workID = activity.attributes.workID
            enqueueWork(workID) { await Self.endWork(workID, content: nil) }
        }
        for id in Array(work.keys) where !ids.contains(id) && work[id]!.staleDate.addingTimeInterval(10 * 60) <= Date() {
            work.removeValue(forKey: id)
            workExpirations.removeValue(forKey: id)?.cancel()
            enqueueWork(id) { await Self.endWork(id, content: nil) }
        }
        if isEnabled { observeWorkTokens() }
    }

    func resumeWorkActivities() {
        failedWorkStarts.removeAll()
        guard activityPairing != nil else { Task { await Self.endAllWork() }; return }
        if workPairing != activityPushPairing { work.removeAll(); workPairing = activityPushPairing }
        Task { await Self.endUnpairedWork() }
        if activityObserver == nil { activityObserver = Task { await Self.observeWorkActivities() } }
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
        for row in work.values { applyWork(row) }
        for activity in Activity<PhoneTurnAttributes>.activities where activity.pushToken == nil
            && activity.attributes.pairingFingerprint == activityPushPairing
            && activity.activityState != .ended && activity.activityState != .dismissed {
            registerActivity(enabled: true, workID: activity.attributes.workID)
        }
        observeWorkTokens()
        registerActivity(enabled: true, reconcile: true)
    }

    private func applyWork(_ row: MobileWorkActivity) {
        guard isEnabled else { return }
        workExpirations.removeValue(forKey: row.id)?.cancel()
        if row.content.state.isTerminal {
            enqueueWork(row.id) { await Self.endWork(row.id, content: row.content) }
            return
        } else if row.staleDate <= Date() {
            enqueueWork(row.id) { await Self.endWork(row.id, content: nil) }
        } else {
            enqueueWork(row.id) {
                guard self.isEnabled, self.work[row.id] == row else { return }
                self.startWork(row)
                await Self.updateWork(row)
            }
        }
        workExpirations[row.id] = Task {
            var deadline = row.staleDate.addingTimeInterval(10 * 60)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
                catch { return }
                guard !Task.isCancelled else { return }
                guard let nextDeadline = await Self.endWork(row.id, content: nil) else { break }
                // APNs may have advanced ActivityKit beyond the cached snapshot.
                deadline = nextDeadline
            }
            if !Task.isCancelled { workExpirations.removeValue(forKey: row.id) }
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
        guard isEnabled, !pushConfigured, row.staleDate > Date(), !row.content.state.isTerminal, !failedWorkStarts.contains(row.id),
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
                  let environment = NativeAgentAPNSEnvironmentResolver.current()?.environment.rawValue,
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
                let response = try iCloudSyncEngine.shared.requireSuccessfulActionResponse(await iCloudSyncEngine.shared.sendActionWithSignatureRetry(
                    InboxAction.make(action: "registerWorkActivity", payload: payload)))
                if !enabled, response["ok"] == "true", !isEnabled, activityPairing == expectedPairing {
                    disableRegistrationPending = false
                    activityError(nil)
                }
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
            await shared.registerActivity(enabled: true, workID: workID, activityToken: token.map { String(format: "%02x", $0) }.joined(), tokenPairing: pairing)
        }
        for await token in activity.pushTokenUpdates {
            guard !Task.isCancelled else { return }
            await shared.registerActivity(enabled: true, workID: workID, activityToken: token.map { String(format: "%02x", $0) }.joined(), tokenPairing: pairing)
        }
    }

    @concurrent nonisolated private static func updateWork(_ row: MobileWorkActivity) async {
        let pairing = await shared.activityPushPairing
        for activity in Activity<PhoneTurnAttributes>.activities where activity.attributes.workID == row.id
            && activity.attributes.pairingFingerprint == pairing
            && activity.activityState != .ended && activity.activityState != .dismissed
            && activity.content.state.updatedAt <= row.content.updatedAt {
            await activity.update(ActivityContent(state: row.content, staleDate: row.staleDate))
        }
    }

    @discardableResult
    @concurrent nonisolated private static func endWork(_ id: String, content: MobileWorkActivity.ContentState?) async -> Date? {
        var nextDeadline: Date?
        for activity in Activity<PhoneTurnAttributes>.activities where activity.attributes.workID == id
            && activity.activityState != .ended && activity.activityState != .dismissed {
            if let content, content.updatedAt < activity.content.state.updatedAt { continue }
            if content == nil {
                let deadline = activity.content.state.updatedAt.addingTimeInterval(15 * 60)
                if deadline > Date() {
                    nextDeadline = max(nextDeadline ?? deadline, deadline)
                    continue
                }
            }
            let final = content.map { ActivityContent(state: $0, staleDate: nil) }
            await activity.end(final, dismissalPolicy: .after(Date().addingTimeInterval(30)))
        }
        return nextDeadline
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
