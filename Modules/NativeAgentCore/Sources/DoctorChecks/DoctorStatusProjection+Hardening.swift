import Foundation

extension DoctorStatusProjection {
    public static func getProductionHardening(dataRoot: URL) async throws -> ProductionHardeningSummary {
        // The hardening report is an operator-produced authority. A missing
        // report means no report has been recorded; an existing unreadable or
        // malformed report is unavailable and must never be presented as the
        // same neutral state. Keep the report on the client's injected root so
        // the mounted panel, export action, and reload all agree on one store.
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
