import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import ChatTurnContracts
import AgentWorkspace
import MemoryV2
import ToolRegistry
import NativeAgentShared
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Dispatcher
import MacControl
import Senses
import StandingBots
// Blueprint: | `BuiltInToolSchemaFactory+BridgeSchemas.swift` | `BuiltInToolSchemaFactory`: `bridgeSchemas`: Claude, OMP and Codex |

extension BuiltInToolSchemaFactory {
    func bridgeSchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "claude_message",
                toolClass: .send, capabilities: ["external_send", "notification", "tool_call"],
                description: "Send the contact a message through its live inbox door. New work: conversation_mode=new, topic, no conversation_id. Follow-up: resume + its returned conversationId, no topic.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("agent", ToolSchema.strSchema("Saved contact handle or peer reference selecting its live inbox door; runtime routing supplies this. Omit to address claude.")),
                        ("session_id", ToolSchema.strSchema("Originating NativeAgent conversation for reply routing, not the recipient's conversation_id.")),
                        ("message_id", ToolSchema.strSchema("Optional stable message identity retained across admission and inbox deduplication.")),
                        ("text", ToolSchema.strSchema("The message to the agent — full prose, no markdown headers needed. Be specific about the requested work or review.")),
                        ("priority", ToolSchema.enumStringSchema(["info", "important", "urgent"], "Prominence: info=digest; important=highlighted; urgent=🚨 tag.")),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", ToolSchema.strSchema("Short topic for new work, e.g. bug-music-tcc. On resume, omit or use the topic after claude: in conversation_id.")),
                        ("conversation_id", conversationReferenceSchema("claude", "claude_message")),
                        ("expects_reply", ToolSchema.boolSchema("false for an FYI that needs no answer. Omit for questions and work.")),
                        ("pair_reviewer", ToolSchema.boolSchema("true for implementation needing one paired reviewer: builder pairs at start, commits, supplies exact SHA for review, receives findings and owns fixes. Omit for notes/questions/review-only work.")),
                        ("desk_item", nonEmptyStringSchema("Omit unless copied exactly from a live desk.read number/handle in this conversation. Never invent/guess/reuse remembered IDs or placeholders ('none'). A live ID binds terminal execution/delivery evidence to that Desk item; nonlive IDs are ignored and delivery proceeds unbound.")),
                        ("working_directory", ToolSchema.strSchema("Optional existing absolute project directory the work is about, noted in her inbox. Canonical workspace/source paths work normally; others require active Full Mac + allowed outside-workspace access.")),
                    ],
                    required: ["text", "conversation_mode"]
                )
            ),
            requestedSchema(name: "omp_message",
                toolClass: .send, capabilities: ["external_send", "notification", "tool_call"],
                description: "Send an asynchronous task to the local OMP CLI harness (Kimi K3). Set conversation_mode=new and omit conversation_id for unrelated work; set conversation_mode=resume and pass this tool's exact returned conversationId only for a contextual follow-up. A new coding conversation receives its own Git worktree and a resume reuses it. The final reply or honest failure/timeout receipt returns as an '[omp-wake] Automated completion event'.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("session_id", ToolSchema.strSchema("Originating NativeAgent conversation for reply routing, not the recipient's conversation_id.")),
                        ("message_id", ToolSchema.strSchema("Optional stable message identity retained across admission and inbox deduplication.")),
                        ("text", ToolSchema.strSchema("The complete task or question for OMP.")),
                        ("priority", ToolSchema.enumStringSchema(["info", "important", "urgent"], "Receipt prominence.")),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", ToolSchema.strSchema("Optional short stable topic for new work. Omit on resume; the conversationId already owns the topic.")),
                        ("conversation_id", conversationReferenceSchema("omp", "omp_message")),
                        ("desk_item", nonEmptyStringSchema("Omit unless copied exactly from a live desk.read number/handle in this conversation. Never invent/guess/reuse remembered IDs or placeholders ('none'). A live ID binds terminal execution/delivery evidence to that Desk item; nonlive IDs are ignored and delivery proceeds unbound.")),
                        ("working_directory", ToolSchema.strSchema("Optional existing absolute project directory for a new OMP conversation. External paths require Full Mac with outside-workspace access allowed. Follow-ups always reuse their assigned private worktree; omit working_directory on a follow-up (a different value is ignored and noted on the receipt).")),
                        ("timeout_seconds", ToolSchema.intSchema("OMP wall-clock guard, clamped 60-3600 seconds. Default 900.")),
                    ],
                    required: ["text", "conversation_mode"]
                )
            ),
            requestedSchema(name: "invoke_codex",
                toolClass: .send, capabilities: ["agent_delegate", "process_spawn", "tool_call"],
                description: "Invoke Codex for a focused question or short inspection. Waits for a bounded observation; expiry leaves the admitted execution running and returns runId. Inspect it with run_id; abort:true explicitly stops that exact execution. Writes its terminal audit under data/from_codex/.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("text", ToolSchema.strSchema("Required for new work; omit when inspecting run_id. Codex only knows the context you provide.")),
                        ("run_id", ToolSchema.strSchema("Exact returned runId to inspect existing execution and its audit without launching work.")),
                        ("abort", ToolSchema.boolSchema("With run_id, explicitly stop that exact retained execution. Its actual exit settles its captured output; a missing owner remains unknown.")),
                        ("context", ToolSchema.strSchema("Optional preface: what you were doing, what failed, file paths, errors, and desired outcome.")),
                        ("cwd", ToolSchema.strSchema("Working directory for Codex. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                        ("skip_git_repo_check", ToolSchema.boolSchema("Allow a focused file repair in a folder outside a Git repository. Sandbox and Trust still apply.")),
                        ("timeout_seconds", ToolSchema.intSchema("Maximum observation wait, 0-3600 seconds, default 600. Expiry or caller Stop ends only this wait; it never kills Codex.")),
                        ("execution_timeout_seconds", ToolSchema.intSchema("Execution wall-clock ceiling, 30-86400 seconds, default 3600. This limit or explicit abort stops Codex; actual exit owns terminal settlement.")),
                        ("commit_hash", ToolSchema.strSchema("Optional git commit hash to anchor the context.")),
                        ("model", ToolSchema.enumStringSchema(OpenAIExecutionControls.codexBridgeModelIDs, "Optional per-call Codex model. Omit to inherit the active Codex CLI default.")),
                        ("reasoning_effort", ToolSchema.enumStringSchema(["low", "medium", "high", "xhigh", "max", "ultra"], "Optional per-call Codex thinking level. Available levels depend on the selected model. Omit to inherit the Codex default.")),
                        ("fast", ToolSchema.boolSchema("Optional per-call Fast mode. true selects Codex priority service; false explicitly selects default service; omit to inherit the Codex default.")),
                        ("sandbox", ToolSchema.enumStringSchema(["read-only", "workspace-write", "danger-full-access"], "Codex sandbox. Omit to follow Trust: Full Mac runs danger-full-access, lower Trust workspace-write. danger-full-access requires Full Mac.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "codex_message",
                toolClass: .send, capabilities: ["external_send", "notification", "tool_call"],
                description: "Send an asynchronous note/task to Codex. Set conversation_mode=new and omit conversation_id for unrelated work; set conversation_mode=resume and pass this tool's exact returned conversationId only for a contextual follow-up. A new coding conversation receives its own Git worktree and a resume reuses it. NativeAgent durably queues the task, starts or queues a Codex app-server turn, and returns Codex's final answer through the local bridge.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("session_id", ToolSchema.strSchema("Originating NativeAgent conversation for reply routing, not the recipient's conversation_id.")),
                        ("message_id", ToolSchema.strSchema("Optional stable message identity retained across admission and inbox deduplication.")),
                        ("text", ToolSchema.strSchema("The message to Codex. Include enough context to be useful in a later Codex session.")),
                        ("priority", ToolSchema.enumStringSchema(["info", "important", "urgent"], "How prominently to surface this in the Codex bridge inbox.")),
                        ("conversation_mode", conversationModeSchema()),
                        ("topic", ToolSchema.strSchema("Optional short topic tag for new work. Omit on resume; the conversationId already owns the thread.")),
                        ("conversation_id", conversationReferenceSchema("codex", "codex_message")),
                        ("completion_mode", ToolSchema.enumStringSchema(["report", "receipt_only"], "How Codex's terminal result returns. Use report for delegated work or a question whose answer the agent must assess. Use receipt_only for a one-way acknowledgment, status note, approval, or handoff that should settle durably without creating another chat turn. Defaults to report.")),
                        ("pair_reviewer", ToolSchema.boolSchema("true for implementation needing one paired reviewer: builder pairs at start, commits, supplies exact SHA for review, receives findings and owns fixes. Omit for notes/questions/review-only work.")),
                        ("desk_item", nonEmptyStringSchema("Omit unless copied exactly from a live desk.read number/handle in this conversation. Never invent/guess/reuse remembered IDs or placeholders ('none'). A live ID binds terminal execution/delivery evidence to that Desk item; nonlive IDs are ignored and delivery proceeds unbound.")),
                        ("model", ToolSchema.enumStringSchema(OpenAIExecutionControls.codexBridgeModelIDs, "Optional model for this asynchronous Codex task. Omit to inherit the active Codex default.")),
                        ("reasoning_effort", ToolSchema.enumStringSchema(["low", "medium", "high", "xhigh", "max", "ultra"], "Optional thinking level for this task. Available levels depend on the selected model.")),
                        ("fast", ToolSchema.boolSchema("Optional Fast mode for this task. true selects Codex priority service; false selects default service.")),
                        ("working_directory", ToolSchema.strSchema("Optional existing absolute project directory for a new Codex conversation. Canonical NativeAgent workspace/source paths work normally; any other directory requires active Full Mac with outside-workspace access allowed. Follow-ups always reuse their assigned private worktree; omit working_directory on a follow-up (a different value is ignored and noted on the receipt).")),
                        ("repository", ToolSchema.strSchema("New work only: optional GitHub repository as 'owner/name' (never a filesystem path). NativeAgent requires exactly one matching local clone verified by its remote; multiple clones require an explicit working_directory. Message prose never selects a checkout. Omit on resume because the saved conversation owns its checkout. An unknown, invalid or unreadable requested repository refuses before sending.")),
                    ],
                    required: ["text", "conversation_mode"]
                )
            ),
        ]
    }
}
