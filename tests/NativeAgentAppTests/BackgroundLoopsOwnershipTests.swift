import Foundation
import Testing
@testable import NativeAgentApp
import BackgroundLoops

private struct OwnershipTestLoop: LoopRunner {
    let loopId: String
    let interval: TimeInterval = 86_400
    let onTick: @Sendable () async -> Void

    init(_ loopId: String, onTick: @escaping @Sendable () async -> Void = {}) {
        self.loopId = loopId
        self.onTick = onTick
    }

    // C7 flip: tickOutcome() is the required primary; tick() is defaulted.
    func tickOutcome() async -> LoopTickOutcome {
        await onTick()
        return .completed(result: nil)
    }
}

private actor OwnershipTickCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

@Suite("Background loop ownership", .serialized)
struct BackgroundLoopsOwnershipTests {
    @Test("app startup injects its manifest into the Core owner")
    func appStartIsVisibleThroughCore() async {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: { [OwnershipTestLoop("app_launch_manifest")] },
            runHeartbeatAtLaunch: { false }
        )

        await facade.start()

        #expect(await core.isRunning())
        #expect(await core.registered() == ["app_launch_manifest"])
        let status = await core.status()
        #expect(status.count == 1)
        #expect(status.first?.name == "app_launch_manifest")
        #expect(status.first?.running == true)
        await facade.stop()
    }

    @Test("opt-in Auto-Doctor launch runs exactly one immediate Core-owned tick")
    func autoDoctorLaunchOptInRunsOneTick() async throws {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let doctor = OwnershipTickCounter()
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: {
                [OwnershipTestLoop("doctor_auto_run") { await doctor.bump() }]
            },
            runAutoDoctorAtLaunch: { true },
            runHeartbeatAtLaunch: { false }
        )

        await facade.start()
        for _ in 0..<40 {
            if await doctor.value > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await doctor.value == 1)
        #expect(await core.status().first { $0.name == "doctor_auto_run" }?.runCount == 1)
        await facade.stop()
    }

    @Test("default Auto-Doctor launch posture performs no immediate tick")
    func autoDoctorLaunchOptOutStaysQuiet() async throws {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let doctor = OwnershipTickCounter()
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: {
                [OwnershipTestLoop("doctor_auto_run") { await doctor.bump() }]
            },
            runAutoDoctorAtLaunch: { false },
            runHeartbeatAtLaunch: { false }
        )

        await facade.start()
        try await Task.sleep(for: .milliseconds(50))

        #expect(await doctor.value == 0)
        #expect(await core.status().first { $0.name == "doctor_auto_run" }?.runCount == 0)
        await facade.stop()
    }

    @Test("app Telegram reload delegates a one-loop replacement")
    func telegramReloadPreservesOtherCoreStatus() async {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let oldTelegram = OwnershipTickCounter()
        let newTelegram = OwnershipTickCounter()
        let preservedIds = [
            "cognition_microcycle",
            "mission_executor",
            "slack_socket_mode",
            "self_improvement_sweep",
        ]
        let manifest: [any LoopRunner] = preservedIds.map { OwnershipTestLoop($0) }
            + [OwnershipTestLoop("telegram_poll") { await oldTelegram.bump() }]
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: { manifest },
            replacementLoop: { id in
                guard id == "telegram_poll" else { return nil }
                return OwnershipTestLoop(id) { await newTelegram.bump() }
            },
            runHeartbeatAtLaunch: { false }
        )
        await facade.start()
        for id in preservedIds {
            await core.runTickOnce(loopId: id)
        }
        let before = Dictionary(uniqueKeysWithValues: await core.status().map {
            ($0.name, $0.runCount)
        })

        #expect(await facade.restartLoop(id: "telegram_poll"))

        let after = Dictionary(uniqueKeysWithValues: await core.status().map {
            ($0.name, $0.runCount)
        })
        #expect(Set(await core.registered()) == Set(preservedIds + ["telegram_poll"]))
        for id in preservedIds {
            #expect(after[id] == before[id])
        }
        await core.runTickOnce(loopId: "telegram_poll")
        #expect(await oldTelegram.value == 0)
        #expect(await newTelegram.value == 1)
        await facade.stop()
    }

    @Test("Slack hot reload remains a targeted sibling path")
    func slackReloadStillReconfiguresOnlySlack() async {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let oldSlack = OwnershipTickCounter()
        let newSlack = OwnershipTickCounter()
        let manifest: [any LoopRunner] = [
            OwnershipTestLoop("cognition_microcycle"),
            OwnershipTestLoop("slack_socket_mode") { await oldSlack.bump() },
        ]
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: { manifest },
            replacementLoop: { id in
                guard id == "slack_socket_mode" else { return nil }
                return OwnershipTestLoop(id) { await newSlack.bump() }
            },
            runHeartbeatAtLaunch: { false }
        )
        await facade.start()
        await core.runTickOnce(loopId: "cognition_microcycle")
        let cognitionCount = await core.status()
            .first { $0.name == "cognition_microcycle" }?.runCount

        #expect(await facade.restartLoop(id: "slack_socket_mode"))

        #expect(Set(await core.registered()) == ["cognition_microcycle", "slack_socket_mode"])
        #expect(
            await core.status().first { $0.name == "cognition_microcycle" }?.runCount
                == cognitionCount
        )
        await core.runTickOnce(loopId: "slack_socket_mode")
        #expect(await oldSlack.value == 0)
        #expect(await newSlack.value == 1)
        await facade.stop()
    }

    @Test("default launch posture runs one immediate heartbeat tick")
    func launchHeartbeatDefaultRunsOneTick() async throws {
        // A4.8a: pins the prod default of the runHeartbeatAtLaunch knob —
        // the knob exists so the OTHER tests here can suppress the launch
        // tick (its unstructured Task raced their status() reads); this test
        // proves suppression didn't become the default.
        let core = BackgroundLoops.BackgroundLoopsManager()
        let heartbeat = OwnershipTickCounter()
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: {
                [OwnershipTestLoop("heartbeat") { await heartbeat.bump() }]
            },
            runAutoDoctorAtLaunch: { false }
        )

        await facade.start()
        for _ in 0..<40 {
            if await heartbeat.value > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await heartbeat.value == 1)
        await facade.stop()
    }

    @Test("Auto-Doctor settings reload replaces only its registration")
    func autoDoctorReloadPreservesSiblingStatus() async {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let oldDoctor = OwnershipTickCounter()
        let newDoctor = OwnershipTickCounter()
        let manifest: [any LoopRunner] = [
            OwnershipTestLoop("heartbeat"),
            OwnershipTestLoop("doctor_auto_run") { await oldDoctor.bump() },
        ]
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: { manifest },
            replacementLoop: { id in
                guard id == "doctor_auto_run" else { return nil }
                return OwnershipTestLoop(id) { await newDoctor.bump() }
            },
            runAutoDoctorAtLaunch: { false },
            runHeartbeatAtLaunch: { false }
        )
        await facade.start()
        await core.runTickOnce(loopId: "heartbeat")
        let heartbeatCount = await core.status()
            .first { $0.name == "heartbeat" }?.runCount

        #expect(await facade.restartLoop(id: "doctor_auto_run"))
        #expect(await core.status().first { $0.name == "heartbeat" }?.runCount == heartbeatCount)
        await core.runTickOnce(loopId: "doctor_auto_run")
        #expect(await oldDoctor.value == 0)
        #expect(await newDoctor.value == 1)
        await facade.stop()
    }
}
