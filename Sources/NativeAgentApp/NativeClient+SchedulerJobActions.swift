import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry


extension NativeClient {
    func createJob(name: String, kind: String, intervalSeconds: Int) async throws -> SchedulerJob {
        // WAVE 33 W18 (2026-06-01): the POST /v1/scheduler/jobs WRITE is ported
        // into SwiftNative TriggerScheduler (create_job → normalize +
        // flock'd jobs.json append + activity event).
        // Connector-action jobs validate against the Swift action registry when
        // callers provide that kind; ordinary notify/dream/improve jobs remain
        // fully native.
        let writer = makeSchedulerJobWriter(connectorActionIDs: Self.connectorActionIDSet())
        let body: JSONValue = .object([
            "name": .string(name),
            "kind": .string(kind),
            "interval_seconds": .int(Int64(intervalSeconds)),
        ])
        let jobJSON = try await writer.createJob(body: body)
        let data = try jobJSON.serializedData(pretty: false)
        return try JSONDecoder().decode(SchedulerJob.self, from: data)
    }

    // PATCH-2026-05-06: skill-ui NativeClient — skill lifecycle endpoints (v1: filesystem fallback; v2: route through HTTP)
    // v1: reads manifest_registry.json and individual manifest.json files directly from disk.
    // v2 will replace readSkillRegistry/readSkillManifest with GET /v1/skills/list and GET /v1/skills/{name}.

    // PATCH-2026-05-07: cli-registry-clash — read manifest_registry.json (CLI dict format) not registry.json (daemon list format)
}
