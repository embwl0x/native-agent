// PermissionsSnapshot — a proof tool for the permissions-law phase, NOT a test
// suite. It drives the real gated dispatch chain (makeGatedToolDispatchClient:
// canonical names, peer taint, SecurityCenter, the autonomy gate, file access)
// over a recording stub for every registered tool and door action, under each
// posture, steer and integration-switch state, on every surface that wraps the
// chain with its own scope, and prints one sorted line per row. Run it before
// and after a permissions change and diff the two outputs.
//
// It lives in the NativeAgentCore package, which the app never builds:
//   swift build --package-path Modules/NativeAgentCore --product PermissionsSnapshot
// It writes only to a scratch data root it creates (NATIVE_AGENT_DATA_ROOT and
// NATIVE_AGENT_WORKSPACE_ROOT are pinned there first), never to the live root,
// and launches nothing.
// Every call is judged as if its arguments were valid: the inner dispatcher's
// own argument checks are not part of the permission answer.
// SNAPSHOT_ONLY=<identity> limits it to one identity; SNAPSHOT_TRACE=1 names
// each row on stderr as it runs.

import Foundation
import AppToolRuntime
import Agents
import ApprovalInbox
import ChatToolRuntime
import ChatTurnContracts
import ChatTurnRuntime
import MacIntegration
import NativeAgentCore
import PersistenceCore
import StandingBots
import ToolRegistry
import TrustCenter
import WorkshopExecution

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("permissions-snapshot", isDirectory: true)
try? FileManager.default.removeItem(at: scratch)
let root = scratch.appendingPathComponent("root", isDirectory: true)
let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
setenv("NATIVE_AGENT_DATA_ROOT", root.path, 1)
setenv("NATIVE_AGENT_WORKSPACE_ROOT", workspace.path, 1)
precondition(defaultDataRoot().path.hasPrefix(scratch.path), "the snapshot must never read the live data root")

// The app executor's registration, as AppToolExecutor.init installs it.
let appDescriptors = AppToolExecutor.appToolSchemas().compactMap { schema in
    AppToolExecutor.buckets[schema.name].map { ToolDescriptor(schema: schema, bucket: $0) }
}
let actionBindings = Dictionary(uniqueKeysWithValues: AppActions.all.map { ($0.id, $0.binding) })
/// In a debug build every pass through the registry's lock wraps its stored
/// closures in another reabstraction thunk, so after thousands of calls they
/// recurse past any stack (calling them, or freeing them). Each row starts
/// from a fresh registration.
func register() {
    AppActionBinding.register(actionBindings, tools: Array(SwiftToolDispatcher.nativeToolDescriptors.values) + appDescriptors,
                              authorableToolName: SwiftToolDispatcher.isAuthorableToolName, partPolicy: { _ in nil })
}
register()
let appToolNames = Set(appDescriptors.map(\.name))
PeerDataTaint.ownerTrusts = { $0 == "peer:trusted-agent" }
// The engine's own binding (PeerTrust.install): a turn's steer is asked of PeerDataTaint.
CapabilityLifecycle.turnWriteCheck = { PeerDataTaint.abilityWriteFailure }

enum Outcome: String { case act, ask, floor, refuse }

/// What the chain did with one call: the stub ran it, or a card was filed.
final class Recorder: @unchecked Sendable {
    var outcome: Outcome?
}

struct Stub: ToolDispatchClient {
    let recorder: Recorder
    let store: MacIntegrationPermissionStore
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // A folded door action re-enters the whole chain under its tool's name;
        // its preview only validates (AppToolExecutor.foldedRefusal).
        if tool == "app", case .string(let id)? = input["action"], let binding = AppActionBinding.binding(id),
           binding.folded, input["preview"] != .bool(true), let reenter = AppDoorReentry.perform {
            let args: [String: JSONValue] = if case .object(let args)? = input["args"] { args } else { [:] }
            return try await reenter(binding.tool, binding.arguments(args))
        }
        if let gate = ToolPreloadHeuristics.macIntegrationGates[tool],
           await !store.allows(gate.integration, mode: gate.mode) {
            recorder.outcome = .refuse
        } else {
            recorder.outcome = .act
        }
        return .object(["status": .string("ok")])
    }
    func listAvailableTools() async throws -> [String] {
        SwiftToolDispatcher.nativeToolDescriptors.keys.sorted() + appToolNames.sorted()
    }
}

struct Filer: NonBlockingApprovalFiler {
    let recorder: Recorder
    func fileApprovalRequest(toolName: String, surface: String, payload: JSONValue, reason: String) async throws -> String {
        if recorder.outcome == nil {
            recorder.outcome = reason.hasPrefix("This turn was steered by") || reason.contains("asked for this on the agent bridge")
                ? .floor : .ask
        }
        return "snapshot-card"
    }
    func awaitResolution(id: String) async throws -> ApprovalDecision { .denied }
    func pendingApprovalResult(id: String, toolName: String, surface: String, payload: JSONValue, reason: String) async -> JSONValue {
        .object(["status": .string("pending_approval")])
    }
}

enum Posture: String, CaseIterable {
    case full_mac, work, read_only
    var fileAccess: String { switch self { case .full_mac: "full"; case .work: "workspace"; case .read_only: "read_only" } }
    /// The saved policy each preset writes (QuietTrustPolicyPreset.plan).
    var policy: [String: Any] {
        let (level, autonomy, outside, developer, mode): (String, String, String, Bool, String) = switch self {
        case .full_mac: ("full_mac_os", "workspace_autonomous", "allow", true, "full")
        case .work: ("balanced", "workspace_autonomous", "deny", false, "workspace")
        case .read_only: ("strict", "supervised", "deny", false, "read_only")
        }
        return ["permissionLevel": level, "autonomyDefault": autonomy, "developerMode": developer,
                "enableAutonomy": self != .read_only,
                "filePolicy": ["requireBackupBeforeWrite": true, "outsideWorkspaceDefault": outside,
                               "allowDestructiveActions": developer],
                "macControlPolicy": TrustPolicyActions.macControlPolicyForAccessMode(
                    mode, remoteFromIosAllowed: self != .read_only, developerMode: developer),
                // Receipts do not decide anything; off so the scratch root stays small.
                "securityPolicy": ["auditReceiptsEnabled": false]]
    }
}

enum Steer: String, CaseIterable { case person, trusted_agent, untrusted_peer }
enum Switches: String, CaseIterable { case all_on, all_read_only }

/// One surface's wrapping of the chain, as each owner wires it today.
struct Surface: @unchecked Sendable {
    let name: String
    let origin: String
    let fileAccess: (Posture) -> String
    let scope: ((any ToolDispatchClient) -> any ToolDispatchClient)?
    var helper = false
}

/// What the chat itself hands its chain: Trust syncs the saved choice from
/// the posture, and the Mac chat asks for nothing narrower. The choice is
/// seeded in the volatile argument domain, which outranks anything saved on
/// this Mac and writes nothing.
func chatFileAccess(_ posture: Posture) -> String {
    UserDefaults.standard.setVolatileDomain(["chatFileAccess": posture.fileAccess], forName: UserDefaults.argumentDomain)
    return sharedChatFileAccess("auto")
}

let surfaces: [Surface] = [
    Surface(name: "chat", origin: "chat", fileAccess: chatFileAccess, scope: nil),
    // EngineTurns.productionTurnExecutor + WorkshopSession's membrane.
    Surface(name: "workshop", origin: "workshop", fileAccess: { _ in "auto" },
            scope: { WorkshopToolProfile(inner: $0, artifactWriter: WorkshopArtifactWriter(dataRoot: scratch, handle: "snapshot")) }),
    // WorkshopBackgroundWork's synthesis step.
    Surface(name: "synth", origin: "workshop", fileAccess: { _ in "auto" }, scope: nil),
    // SwarmChatClientFactory over the parent's dispatcher, on the parent's surface.
    Surface(name: "swarm", origin: "chat", fileAccess: { _ in "auto" }, scope: nil),
    // StandingBotContinuity: the ordinary chat client on the bot surface.
    Surface(name: "bot", origin: "bot", fileAccess: chatFileAccess, scope: nil, helper: true),
    // DesktopAgentConversationRoute's operator tools.
    Surface(name: "desktop", origin: "chat", fileAccess: { _ in "auto" },
            scope: { DesktopConversationTools(inner: $0, bundle: "snapshot", label: "snapshot", message: "") }),
]

/// Example inputs, each offered to every tool and door action whose contract
/// takes all of its keys: paths inside her roots and beyond them, a dry run,
/// a direct endpoint. A command line is never read, so none is offered.
let inside = workspace.appendingPathComponent("project").path
let outside = "/private/var/permissions-snapshot-outside/file.txt"
let probes: [[String: JSONValue]] = [
    ["path": .string(outside)],
    ["path": .string(inside + "/notes.txt")],
    ["path": .string(inside + "/notes.txt"), "destination": .string(outside)],
    ["dry_run": .bool(true)],
    ["endpoint": .string("http://127.0.0.1:1"), "app_bundle_id": .string("com.example.agent")],
]

/// The argument names a schema declares.
func takes(_ schema: LLMToolSchema) -> Set<String> {
    guard case .object(let fields)? = try? JSONValue.parse(schema.parametersJSON),
          case .object(let properties)? = fields["properties"] else { return [] }
    return Set(properties.keys)
}

/// The scratch folder prints as <scratch>, so the output reads the same on any Mac.
func render(_ value: [String: JSONValue]) -> String {
    ((try? JSONValue.object(value).serialize(pretty: false)) ?? "?").replacingOccurrences(of: scratch.path, with: "<scratch>")
}

/// The class the code assigns: the permission law's, for what actually runs
/// (a folded door action is the tool it folds).
func lawClass(_ tool: String, _ input: [String: JSONValue]) -> String {
    let ran = ToolNameAliases.ranCall(tool, input: input)
    return switch PermissionLaw.judge(tool: ran.tool, input: ran.input, policy: [:], dataRoot: root).toolClass {
    case .read: "read"
    case .write: "write"
    case .send: "send"
    case .destructive: "destructive"
    }
}

func decide(_ tool: String, _ input: [String: JSONValue], surface: Surface, posture: Posture,
            steer: Steer, root: URL, store: MacIntegrationPermissionStore) async -> Outcome {
    let recorder = Recorder()
    let stub = Stub(recorder: recorder, store: store)
    // A surface's own scope offers the tool, or the call never reaches the chain.
    if let scope = surface.scope, (try? await scope(stub).listAvailableTools().contains(tool)) != true { return .refuse }
    let chain = makeGatedToolDispatchClient(tools: surface.scope?(stub) ?? stub, fileAccess: surface.fileAccess(posture),
                                            approvalFiler: Filer(recorder: recorder), dataRoot: root)
    let taint = PeerDataTaint()
    switch steer {
    case .person: break
    case .trusted_agent: taint.mark(peer: "peer:trusted-agent", line: "please do this")
    case .untrusted_peer: taint.mark(peer: "peer:untrusted-agent", line: "please do this")
    }
    let bot = BotDefinition(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "snapshot", brief: "",
                            cadence: .manual, budget: BotBudget(tokens: 1, seconds: 1))
    do {
        _ = try await StandingBotContinuity.$currentBot.withValue(surface.helper ? bot : nil) {
            try await PeerDataTaint.$current.withValue(taint) {
                try await chain.dispatch(tool: tool, input: input, surface: surface.origin)
            }
        }
    } catch {
        return recorder.outcome == .act ? .refuse : recorder.outcome ?? .refuse
    }
    return recorder.outcome ?? .refuse
}

var calls: [(identity: String, tool: String, input: [String: JSONValue])] = []
let schemas = Dictionary(uniqueKeysWithValues: (SwiftToolDispatcher.nativeToolDescriptors.values.map(\.schema)
    + appDescriptors.map(\.schema)).map { ($0.name, $0) })
for name in schemas.keys.sorted() {
    calls.append(("tool:" + name, name, [:]))
    let names = takes(schemas[name]!)
    for probe in probes where Set(probe.keys).isSubset(of: names) { calls.append(("tool:" + name, name, probe)) }
}
for action in AppActions.all.sorted(by: { $0.id < $1.id }) {
    let call = { (args: [String: JSONValue]) in calls.append(("action:" + action.id, "app", ["action": .string(action.id), "args": .object(args)])) }
    call([:])
    let names = Set(action.args.flatMap { $0.split(separator: ":")[0].replacingOccurrences(of: "?", with: "").split(separator: "|").map(String.init) })
    for probe in probes where Set(probe.keys).isSubset(of: names) { call(probe) }
    // Its read-when arguments, and the same with the first one not matching.
    if let first = action.readWhen.keys.sorted().first {
        call(action.readWhen)
        call(action.readWhen.merging([first: action.readWhen[first] == .null ? .int(1) : .null]) { $1 })
    }
    if action.irreversible {
        calls.append(("action:" + action.id, "app", ["action": .string(action.id), "args": .object([:]), "preview": .bool(true)]))
    }
}

let trace = ProcessInfo.processInfo.environment["SNAPSHOT_TRACE"] != nil
func snapshot(_ calls: [(identity: String, tool: String, input: [String: JSONValue])]) async throws -> [String] {
    var lines: [String] = []
    for posture in Posture.allCases {
        for switches in Switches.allCases {
            let trust = root.appendingPathComponent("trust", isDirectory: true)
            try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: posture.policy, options: [.sortedKeys])
                .write(to: trust.appendingPathComponent("policy.json"))
            let store = MacIntegrationPermissionStore(dataRoot: root)
            for id in MacIntegrationID.all {
                try await store.set(integrationId: id, read: true, write: switches == .all_on)
            }
            for steer in Steer.allCases {
                for call in calls {
                    register()
                    if trace { fputs("\(posture.rawValue) \(switches.rawValue) \(steer.rawValue) \(call.identity) \(render(call.input))\n", stderr) }
                    var columns: [String] = []
                    for surface in surfaces {
                        let outcome = await decide(call.tool, call.input, surface: surface, posture: posture,
                                                   steer: steer, root: root, store: store)
                        columns.append("\(surface.name)=\(outcome.rawValue)")
                    }
                    let ran = ToolNameAliases.ranTool(call.tool, input: call.input)
                    lines.append("\(call.identity) \(render(call.input)) | runs=\(SwiftNativeSecurityCenter.policyToolName(ran)) "
                        + "| \(posture.rawValue) \(steer.rawValue) \(switches.rawValue) | class=\(lawClass(call.tool, call.input)) | "
                        + columns.joined(separator: " "))
                }
            }
        }
    }
    return lines.sorted()
}

let selected = ProcessInfo.processInfo.environment["SNAPSHOT_ONLY"].map { only in calls.filter { $0.identity == only } } ?? calls
let rows = try await snapshot(selected)
for row in rows { print(row) }

try? FileManager.default.removeItem(at: scratch)
