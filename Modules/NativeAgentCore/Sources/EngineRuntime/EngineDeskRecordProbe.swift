import Foundation
import WorkshopExecution

extension DeskFacade {
    public nonisolated static func probeExecutionRecords(_ root: URL) -> DeskRecordProbe {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return .empty }
        guard isDirectory.boolValue else {
            return .unreadable("execution root is not a directory")
        }
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        } catch {
            return .unreadable("\(error.localizedDescription)")
        }
        var count = 0
        for entry in entries {
            // Dot entries are the runner's own bookkeeping (.admission lock).
            guard !entry.lastPathComponent.hasPrefix(".") else { continue }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            if ExecutionRecordFile.exists(in: entry, fileManager: fm) {
                count += 1
            } else if (try? fm.contentsOfDirectory(atPath: entry.path)) == nil {
                // Can't tell whether it holds a record — malformed, count it.
                count += 1
            }
        }
        return .records(count)
    }}
