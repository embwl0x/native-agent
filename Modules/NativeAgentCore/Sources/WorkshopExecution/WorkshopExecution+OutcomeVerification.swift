import Foundation
import PersistenceCore

extension WorkshopExecutorLoop {
    /// W3 success-criterion check, pure and testable. Returns a human detail
    /// string when the execution's own definition of success is unmet, nil
    /// when satisfied or when no criterion exists.
    ///
    /// Two criterion sources, both matched by CONTAINMENT against the joined
    /// step outputs (exact equality would false-fail on quoting/wrapping):
    /// 1. Every non-empty string entry in `expected_outputs`.
    /// 2. An exact-output objective: "Return exactly: <phrase>" (case-
    ///    insensitive marker; phrase runs to the first sentence end).
    static func unmetSuccessCriterion(_ record: WorkshopExecutionRecord) -> String? {
        let combinedOutput = record.stepsCompleted.compactMap { step -> String? in
            guard case .object(let obj) = step,
                  case .object(let output)? = obj["output"],
                  case .string(let text)? = output["text"] else { return nil }
            return text
        }.joined(separator: "\n")

        for entry in record.expectedOutputs {
            guard case .string(let expected) = entry else { continue }
            let trimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !combinedOutput.contains(trimmed) {
                return "expected output missing: \(trimmed.prefix(120))"
            }
        }

        let marker = "return exactly:"
        if let range = record.objective.range(of: marker, options: .caseInsensitive) {
            let remainder = record.objective[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let phrase: String = {
                // Sentence end = "." followed by ANY whitespace (space or
                // newline) — "Return exactly: X.\nUse no tools…" must extract
                // only "X." or the gate false-fails on the trailing
                // instruction (review round 3, finding 3).
                if let sentenceEnd = remainder.range(of: #"\.\s"#, options: .regularExpression) {
                    return String(remainder[..<sentenceEnd.lowerBound]) + "."
                }
                return remainder
            }()
            if !phrase.isEmpty, !combinedOutput.contains(phrase) {
                return "objective requires exact phrase not present: \(phrase.prefix(120))"
            }
        }
        return nil
    }

    /// Verify only outcomes for which Workshop owns exact local evidence.
    /// This deliberately does not ask an LLM to judge its own work and does
    /// not infer external success from a tool's absence of an error.
    ///
    /// Currently provable:
    /// - explicit textual success criteria already stored on the execution;
    /// - `write_file` bytes, read back from the exact resolved result path.
    ///
    /// Read/synthesis steps are evidence-neutral. Any other action step keeps
    /// the overall execution `unverified` even when its tool returned success.
    /// A verifiable claim whose evidence disagrees fails the execution.
    static func verifyCompletedOutcome(
        _ record: WorkshopExecutionRecord,
        checkedAt: String,
        fileManager: FileManager = .default
    ) -> WorkshopVerificationRecord {
        if let unmet = unmetSuccessCriterion(record) {
            return WorkshopVerificationRecord(
                status: .failed,
                checkedAt: checkedAt,
                methods: ["exact_output"],
                detail: unmet
            )
        }

        var methods: [String] = []
        let hasTextCriterion = record.expectedOutputs.contains {
            guard case .string(let value) = $0 else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } || record.objective.range(of: "return exactly:", options: .caseInsensitive) != nil
        if hasTextCriterion { methods.append("exact_output") }

        var hasExactEvidence = hasTextCriterion
        var unsupportedAction = false
        for step in record.plan {
            let tool = step.toolOrAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if tool == "write_file" {
                switch verifyFileWrite(step: step, record: record, fileManager: fileManager) {
                case .satisfied:
                    hasExactEvidence = true
                    if !methods.contains("file_bytes") { methods.append("file_bytes") }
                case .failed(let detail):
                    return WorkshopVerificationRecord(
                        status: .failed,
                        checkedAt: checkedAt,
                        methods: methods + ["file_bytes"],
                        detail: detail
                    )
                case .unverifiable:
                    unsupportedAction = true
                }
            } else if !isVerificationNeutral(tool: tool) {
                unsupportedAction = true
            }
        }

        if hasExactEvidence && !unsupportedAction {
            return WorkshopVerificationRecord(
                status: .satisfied,
                checkedAt: checkedAt,
                methods: methods,
                detail: "Declared outcome matched exact local evidence."
            )
        }
        return WorkshopVerificationRecord(
            status: .unverified,
            checkedAt: checkedAt,
            methods: methods,
            detail: unsupportedAction
                ? "At least one action has no exact domain verifier."
                : "No exact outcome criterion was declared."
        )
    }

    private enum FileVerificationVerdict {
        case satisfied
        case failed(String)
        case unverifiable
    }

    /// One bounded terminal read. The verifier never persists file content or
    /// the path; it records only the evidence method and verdict.
    private static func verifyFileWrite(
        step: WorkshopExecutionStep,
        record: WorkshopExecutionRecord,
        fileManager: FileManager
    ) -> FileVerificationVerdict {
        let resolvedArgs = resolveStepReferences(in: step.args, execution: record)
        guard case .object(let args) = resolvedArgs,
              case .string(let content)? = args["content"],
              let completed = record.stepsCompleted.last(where: { value in
                  guard case .object(let object) = value,
                        case .string(let stepID)? = object["step_id"] else { return false }
                  return stepID == step.id
              }),
              case .object(let completedObject) = completed,
              case .string("succeeded")? = completedObject["status"],
              case .object(let output)? = completedObject["output"],
              case .bool(true)? = output["ok"],
              case .string(let path)? = output["path"]
        else { return .failed("write_file completed without an exact success receipt") }

        let expected = Data(content.utf8)
        let verificationByteLimit = 1_048_576
        guard expected.count <= verificationByteLimit else { return .unverifiable }
        let append: Bool = {
            if case .bool(let value)? = args["append"] { return value }
            return false
        }()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber
        else { return .failed("write_file target is absent after execution") }
        let fileSize = sizeNumber.intValue
        if append {
            guard fileSize >= expected.count,
                  let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            else { return .failed("write_file append target cannot be read back") }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(fileSize - expected.count))
                let actual = try handle.read(upToCount: expected.count) ?? Data()
                return actual == expected
                    ? .satisfied
                    : .failed("write_file append bytes do not match the declared content")
            } catch {
                return .failed("write_file append target cannot be read back")
            }
        }
        guard fileSize == expected.count,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return .failed("write_file target size does not match the declared content") }
        defer { try? handle.close() }
        do {
            let actual = try handle.read(upToCount: expected.count) ?? Data()
            return actual == expected
                ? .satisfied
                : .failed("write_file bytes do not match the declared content")
        } catch {
            return .failed("write_file target cannot be read back")
        }
    }

    private static func isVerificationNeutral(tool: String) -> Bool {
        if tool.isEmpty { return false }
        let exact: Set<String> = [
            "chat.synthesize", "llm", "report", "read_file", "list_dir",
            "file_excerpt", "grep", "recall_memory", "recall_search", "search_kg",
        ]
        if exact.contains(tool) { return true }
        let leaf = tool.split(separator: ".").last.map(String.init) ?? tool
        return ["read", "list", "search", "get", "fetch", "status", "availability", "screenshot"]
            .contains { leaf == $0 || leaf.hasPrefix("\($0)_") }
    }
}
