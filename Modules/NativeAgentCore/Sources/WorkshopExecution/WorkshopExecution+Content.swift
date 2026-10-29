import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `WorkshopExecution+Content.swift` | `WorkshopExecutorLoop` synthesis content validation, prior-step prompts, single-pass argument references and full/bounded output handoff |

extension WorkshopExecutorLoop {
    /// Completion is the turn owner's contract; content is not a status code.
    static func validateSynthesizeOutput(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Project the last completed step’s full result content.
    static func extractWorkshopExecutionResult(_ execution: WorkshopExecutionRecord) -> JSONValue {
        guard case .object(let last)? = execution.stepsCompleted.last else { return .null }
        let output = last["output"] ?? .null
        switch output {
        case .object, .string:
            return .string(fullStepOutputText(output))
        default:
            return .null
        }
    }

    /// Synthesis receives prior step receipts as bounded context.
    static func buildLLMPrompt(execution: WorkshopExecutionRecord, step: WorkshopExecutionStep) throws -> String {
        let basePrompt: String = {
            if case .object(let args) = step.args {
                // Prompt and text are equivalent planned synthesis instructions.
                for key in ["prompt", "text"] {
                    if case .string(let value)? = args[key],
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                }
            }
            return step.description
        }()
        let priorSteps: [[String: JSONValue]] = execution.stepsCompleted.compactMap { sr in
            guard case .object(let o) = sr else { return nil }
            if case .string(let sid)? = o["step_id"], sid == step.id { return nil }
            return o
        }
        guard !priorSteps.isEmpty else { return basePrompt }
        var planToolMap: [String: String] = [:]
        for pd in execution.plan { planToolMap[pd.id] = pd.toolOrAction }
        let contextLines = priorSteps.map { sr -> String in
            let sid: String = {
                if case .string(let s)? = sr["step_id"] { return s }
                return "?"
            }()
            let toolName = planToolMap[sid] ?? sid
            let summary = summarizeStepOutput(sr["output"] ?? .null)
            let state = fullStepOutputText(sr["status"] ?? .null)
            let coverage = fullStepOutputText(sr["read_coverage"] ?? .null)
            return "[step \(sid) via \(toolName), status=\(state), read_coverage=\(coverage)]: \(summary)"
        }
        let contextBlock = contextLines.joined(separator: "\n")
        return try completionPolicy("workshop-synthesis", section: "prompt", arguments: [execution.objective, contextBlock, basePrompt])
    }

    /// Resolve string-leaf {{step:<id>}} references with full prior output.
    /// Other value types and unknown/unterminated tokens remain unchanged.
    static func resolveStepReferences(in args: JSONValue, execution: WorkshopExecutionRecord) -> JSONValue {
        // id -> full output text for every completed step (last write wins, so a
        // re-run step resolves to its latest output).
        var outputs: [String: String] = [:]
        for sr in execution.stepsCompleted {
            guard case .object(let o) = sr, case .string(let sid)? = o["step_id"] else { continue }
            outputs[sid] = fullStepOutputText(o["output"] ?? .null)
        }
        guard !outputs.isEmpty else { return args }
        // Substitute left to right once; inserted output is never rescanned.
        func substitute(_ s: String) -> String {
            guard s.contains("{{step:") else { return s }
            var result = ""
            var rest = Substring(s)
            while let open = rest.range(of: "{{step:") {
                result += rest[..<open.lowerBound]
                let afterOpen = rest[open.upperBound...]
                guard let close = afterOpen.range(of: "}}") else {
                    result += rest[open.lowerBound...]   // unterminated → verbatim
                    return result
                }
                let sid = String(afterOpen[..<close.lowerBound])
                if let text = outputs[sid] {
                    result += text                        // NOT rescanned
                } else {
                    result += "{{step:\(sid)}}"           // unknown id → verbatim
                }
                rest = afterOpen[close.upperBound...]
            }
            result += rest
            return result
        }
        return args.mapStrings(substitute)
    }

    /// Untruncated step handoff, retaining structured receipts when no text
    /// projection exists. Textual outcome verification reads only result content.
    static func fullStepOutputText(_ output: JSONValue) -> String {
        switch output {
        case .null:
            return ""
        case .string(let s):
            return s
        case .object(let o):
            if case .string(let t)? = o["text"] { return t }
            if case .object(let inner)? = o["output"] {
                if case .string(let t)? = inner["text"] { return t }
                return (try? JSONValue.object(inner).serialize(pretty: false)) ?? ""
            }
            if case .string(let t)? = o["output"] { return t }
            return (try? JSONValue.object(o).serialize(pretty: false)) ?? ""
        default:
            return (try? output.serialize(pretty: false)) ?? ""
        }
    }

    /// Only model context is bounded; receipts and tool references stay whole.
    static func summarizeStepOutput(_ output: JSONValue, maxChars: Int = 32_768) -> String {
        let text = fullStepOutputText(output)
        if text.isEmpty { return "returned no results" }
        if text.count <= maxChars { return text }
        let head = maxChars / 4, tail = maxChars - head
        return String(text.prefix(head))
            + "\n… [\(text.count - maxChars) characters elided from middle] …\n"
            + String(text.suffix(tail))
    }

    /// Last completed-step record for a step ID.
    static func lastStepRecord(_ execution: WorkshopExecutionRecord, stepId: String) -> JSONValue? {
        for sr in execution.stepsCompleted.reversed() {
            if case .object(let o) = sr, case .string(let sid)? = o["step_id"], sid == stepId {
                return sr
            }
        }
        return nil
    }
}
