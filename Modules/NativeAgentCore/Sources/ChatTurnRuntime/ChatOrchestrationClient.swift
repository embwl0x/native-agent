import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

// MARK: - ChatOrchestrationClient
//
// HIGH-LEVEL FACADE that composes the now-real Swift building blocks into a
// single chat()/chatStream() surface the Swift app shell (NativeClient.chat)
// can route to when the chatOrchestration cutover flag is on:
//
//   SessionHistoryReader   -> load persisted turns from data/chat/messages/<id>.jsonl
//   buildTurnContextWithHistory -> persona + continuity state + bounded history + user message
//   executeTurnWithStreamingToolLoop -> LLM call (+ tool loop)
//   AutonomyGate           -> trust-based gate around tool dispatch
//   PersistenceCore.appendJSONL -> persist user+assistant turns in daemon format
//
// CARVES (intentional, documented):
//   * Multimodal attachments: NATIVE per-provider vision is WIRED (2026-06-11).
//     Image attachments (type=="image", non-empty base64) are converted to
//     per-turn DYNAMIC `.image` content blocks (imageBlocksFromAttachments →
//     TurnContext.imageBlocks) and delivered on the CURRENT user message as
//     each provider's native image block: Anthropic {type:image,source:
//     {type:base64,media_type,data}} (OAuth-direct + api-key); OpenAI
//     {type:input_image,image_url:"data:..."} on the Responses API (OAuth-
//     direct) / {type:image_url,image_url:{url:"data:..."}} on Chat
//     Completions (api-key). The image blocks NEVER enter the system prompt
//     (cache invariant) and are NEVER persisted/re-sent on later turns — the
//     session record keeps `metadata.attachments` with {id,type,mime,name,
//     byteSize} ONLY (no base64), so history rebuilds don't balloon. NON-vision
//     providers (Codex/OpenRouter; the legacy stream(prompt:) lane) hit a
//     tripwire: an honest "could not see the image" note is prepended to the
//     turn AND a `vision.attachment_unsupported` trace row is written — never a
//     silent describe-or-pretend. PDF and plain-text attachments contribute
//     bounded extracted text to the current user message; PDF ingestion follows
//     Trust Center policy. Skipped or unreadable documents are named to the
//     model, and DOCX attachments are rejected with a PDF/text recovery hint.
//   * fileAccess: 'workspace' lets regular Swift tool policy decide. 'none'
//     blocks file/shell tools. 'read_only' permits read-side tools but filters
//     write/shell/app-control tools BEFORE they reach AutonomyGate. Path bounds
//     remain enforced by the Swift tool-dispatch policy gates.
//   * sessionId continuity: callers must supply an existing session identity.
//     The Swift path keeps chat/sessions.json in sync with the per-session
//     JSONL append.
//   * Persona compilation: PersonaCompiler compiles the selected persona for
//     the originating surface, including a caller-supplied persona override.
//
// There is no daemon proxy fallback. Missing behavior must be implemented in
// Swift or reported as an explicit Swift runtime error.
