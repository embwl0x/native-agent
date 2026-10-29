import Foundation
import NativeAgentCore
import PersistenceCore
import ChatToolParsing
// Blueprint: | `WorkshopExecution+OutcomeVerification.swift` | `WorkshopExecutorLoop`: `unmetSuccessCriterion`, `verifyCompletedOutcome` |

extension WorkshopExecutorLoop {
    /// Explicit output phrases match produced content, excluding receipt metadata.
    /// Objective prose never creates a criterion.
    static func unmetSuccessCriterion(_ record: WorkshopExecutionRecord) -> String? {
        let combinedOutput = record.stepsCompleted.compactMap { step -> String? in
            guard case .object(let obj) = step else { return nil }
            return textualResultContent(obj["output"] ?? .null)
        }.joined(separator: "\n")

        for entry in record.expectedOutputs {
            guard case .string(let expected) = entry else { continue }
            let trimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !combinedOutput.contains(trimmed) {
                return "expected output missing: \(trimmed.prefix(120))"
            }
        }

        return nil
    }

    /// Text criteria describe produced content, never paths, status, or other
    /// receipt fields. An explicitly empty content field stays empty.
    private static func textualResultContent(_ output: JSONValue) -> String {
        switch output {
        case .string(let text): return text
        case .object(let fields):
            for key in ["text", "content", "stdout", "reply"] {
                if case .string(let text)? = fields[key] { return text }
            }
            return textualResultContent(fields["output"] ?? .null)
        default: return ""
        }
    }

    /// Verify resolved operations from their own evidence and declared postconditions.
    /// Unknown external outcomes stay unverified; missing proof does not create a dependency.
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
        }
        if hasTextCriterion { methods.append("exact_output") }

        var hasExactEvidence = hasTextCriterion
        var unsupportedAction = false
        var writes: [String: [WorkshopExecutionStep]] = [:]
        for step in record.plan {
            let call = Self.resolvedStepCall(step, execution: record)
            let completed = record.stepsCompleted.last { $0.objectValue?["step_id"] == .string(step.id) }?.objectValue
            let output = completed?["output"] ?? .null
            if call.tool == "write_file" {
                guard completed?["status"] == .string("succeeded"), output.objectValue?["ok"] == .bool(true),
                      let path = output.objectValue?["path"]?.stringValue else {
                    unsupportedAction = true
                    continue
                }
                let resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                writes[resolvedPath, default: []].append(step)
            } else if ["shell", "bash", "git"].contains(call.tool) {
                if output.objectValue?["exit_code"]?.numberValue(coercingStrings: false, finiteOnly: true) == 0,
                   output.objectValue?["timed_out"] == .bool(false), ChatToolOutcome.exactResultClass(output) == .succeeded {
                    hasExactEvidence = true
                    if !methods.contains("command_exit") { methods.append("command_exit") }
                } else { unsupportedAction = true }
            } else if call.readOnly {
                if let coverage = completed?["read_coverage"]?.stringValue, ["complete", "partial"].contains(coverage) {
                    hasExactEvidence = true
                    if !methods.contains("read_evidence") { methods.append("read_evidence") }
                } else { unsupportedAction = true }
            } else if !Self.llmStepKinds.contains(call.tool) { unsupportedAction = true }
        }
        for path in writes.keys.sorted() {
            guard let steps = writes[path] else { continue }
            switch verifyFileWrites(steps: steps, path: path, record: record, fileManager: fileManager) {
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
        }

        if hasExactEvidence && !unsupportedAction {
            return WorkshopVerificationRecord(
                status: .satisfied,
                checkedAt: checkedAt,
                methods: methods,
                detail: "Operations matched their retained evidence and declared outcomes."
            )
        }
        return WorkshopVerificationRecord(
            status: .unverified,
            checkedAt: checkedAt,
            methods: methods,
            detail: unsupportedAction
                ? "At least one operation has no confirmed outcome evidence."
                : "No exact outcome criterion was declared."
        )
    }

    private enum FileVerificationVerdict {
        case satisfied
        case failed(String)
        case unverifiable
    }

    private static func verifyFileWrites(
        steps: [WorkshopExecutionStep], path: String,
        record: WorkshopExecutionRecord, fileManager: FileManager
    ) -> FileVerificationVerdict {
        var expected = Data()
        var append = true
        for step in steps {
            guard case .object(let args) = Self.resolvedStepCall(step, execution: record).args,
                  case .string(let content)? = args["content"] else {
                return .failed("write_file has no exact declared content")
            }
            if args["append"] == .bool(true) {
                expected.append(Data(content.utf8))
            } else {
                expected = Data(content.utf8)
                append = false
            }
        }
        let verificationByteLimit = 1_048_576
        guard expected.count <= verificationByteLimit else { return .unverifiable }
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

}
