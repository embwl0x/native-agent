import Foundation
// Blueprint: | `DoctorStatusProjection+Hardening.swift` | `DoctorReadout`: `getProductionHardening` |

extension DoctorReadout {
    public static func getProductionHardening(dataRoot: URL) async throws -> ProductionHardeningSummary {
        // Missing reports are neutral; unreadable reports stay unavailable, never synthetic health. Use the injected root so the panel, export and reload read
        // the same owner.
        let path = dataRoot
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("hardening.json")
        let now = ISO8601DateFormatter().string(from: Date())
        guard FileManager.default.fileExists(atPath: path.path) else {
            return ProductionHardeningSummary(
                status: "unknown",
                release: nil,
                doctorStatus: nil,
                createdAt: now,
                detail: "No production hardening report has been recorded for this data root."
            )
        }
        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ProductionHardeningSummary.self, from: data)
        } catch {
            return ProductionHardeningSummary(
                status: "unavailable",
                release: nil,
                doctorStatus: nil,
                createdAt: now,
                detail: "Could not read production hardening report: \(error.localizedDescription)"
            )
        }
    }
}
