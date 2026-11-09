import AppToolRuntime
import Agents
import Cognition
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ToolExecution
import Senses
// Blueprint: | `AppQuietToolHost+Mind.swift` | `AppQuietToolHost`: Separate real and inert dream calls; part management |

extension AppQuietToolHost {
    // MARK: - mind_run

    func runMind(verb: String, input: [String: JSONValue], turn: Turn) async -> QuietMindOutcome {
        if verb == "trigger_fire" {
            guard case .string(let name)? = input["name"], !name.isEmpty else {
                return (false, "Pass the trigger's name from its repair obligation.", [:])
            }
            do {
                let result = try await NativeAgentEngine.makeNativeTriggerScheduler(dataRoot: appModel.engine.dataRoot).fireInboxTrigger(name: name)
                return (result.status == "fired", result.error ?? "Trigger \(name): \(result.status).", [:])
            } catch { return (false, error.localizedDescription, [:]) }
        }
        if verb == "rem", input["repair"] == .bool(true) {
            do {
                _ = try await NativeAgentEngine.runRem(dataRoot: appModel.engine.dataRoot, repair: true)
                return (true, "REM staging checked under Trust and archival completed without generating new proposals.", [:])
            } catch { return (false, error.localizedDescription, [:]) }
        }
        if verb == "misses" { return await AppToolExecutor.quietMindMisses(dataRoot: appModel.engine.dataRoot, turn: turn) }
        if verb == "sleep" {
            // The owner confirms admission before this door says the night started; it retains the night after this call returns.
            switch await NativeAgentEngine.sleep(dataRoot: appModel.engine.dataRoot, parent: turn) {
            case .started(let began):
                return (true, "The night started. It runs the available dream and REM work, then reads your parts; "
                    + "a thought follows if that reading asks for one. mind.night shows the reading once it settles.",
                    ["admission": .string("started"), "beganAt": .double(began.timeIntervalSince1970)])
            case .alreadyRunning(let began):
                return (false, "The night that began at \(NativeTimestampFormat.plainZulu(began)) is already running; "
                    + "mind.night shows its reading once it settles.",
                    ["status": .string("already_running"), "admission": .string("already_running"), "beganAt": .double(began.timeIntervalSince1970),
                     "execution": .string("not_run"), "effects": .string("none")])
            case .failed(let cause):
                return (false, "The night did not start: " + cause,
                    ["status": .string("failed"), "admission": .string("failed"), "cause": .string(cause),
                     "execution": .string("not_run"), "effects": .string("none")])
            }
        }
        if verb == "night" {
            let through = Date()
            let since: Date
            if let given = input["since"] {
                guard case .string(let text) = given, let date = NativeTimestampFormat.parseISO8601(text) else {
                    return (false, "since must be an ISO-8601 time; nothing was read.", ["argument_path": .string("since")])
                }
                since = date
            } else { since = through.addingTimeInterval(-86_400) }
            do {
                guard case .object(let reading) = try await EngineSleep.read(dataRoot: appModel.engine.dataRoot, since: since, through: through) else {
                    return (false, "The night's reading returned no fields; nothing was read.", [:])
                }
                return (true, "The night's reading of your parts, as numbers and ids.", reading)
            } catch { return (false, error.localizedDescription, ["argument_path": .string("since")]) }
        }
        return await AppToolExecutor.runQuietMind(
            verb: verb, input: input, runtime: NativeAgentEngine.liveCognition,
            dataRoot: appModel.engine.dataRoot, remPolicy: trustPolicy, turn: turn,
            dreamEnabled: { try await dreamEnabled() },
            runDream: {
                let run = await appModel.runDreamPassForDreams(parent: turn)
                return (run.ok, appModel.statusForAgent, appModel.dreamError, run.busy)
            }, previewDream: {
                do {
                    let result = try await NativeAgentEngine.previewDream(dataRoot: appModel.engine.dataRoot)
                    return (result.ok, result.why, result.json)
                } catch {
                    let result = NativeCognitionRuntime.recordClockRun("dream", .init("unavailable", error.localizedDescription,
                        fields: ["preview": .bool(true), "effects": .string("none"), "execution": .string("preview")]))
                    return (false, result.why, result.json)
                }
            }, runREM: {
                let feedback = await appModel.runRemPass()
                return (feedback.isSuccess, feedback.message)
            })
    }

    // MARK: - ability_manage

    func managePart(verb: String, input: [String: JSONValue], steer: [String], turn: Turn,
                    invocation: Parts.Invocation) async -> QuietMindOutcome {
        let outcome = await CapabilityLifecycleCommands(dataRootOverride: appModel.engine.dataRoot)
            .managePart(verb: verb, input: input, steer: steer, turn: turn, invocation: invocation)
        // Capabilities reads the abilities again before the verb's status shows, so a dropped ability leaves without overwriting feedback.
        if outcome.refreshTools { await appModel.engine.pages.refresh(page: "capabilities") }
        if let status = outcome.toolStatus {
            let message = status.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { appModel.statusText = message }
            appModel.statusCause = nil
        }
        return (outcome.ok, outcome.detail, outcome.fields)
    }

}
