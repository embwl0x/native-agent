import Foundation

public struct ImprovementGauntletRun: Identifiable, Codable, Hashable {
    public var id: String
    public var objective: String?
    public var promotionClass: String?
    public var status: String
    public var dryRun: Bool?
    public var checks: [GauntletCheck]?
    public var createdAt: String?
    public init(id: String, objective: String? = nil, promotionClass: String? = nil, status: String, dryRun: Bool? = nil, checks: [GauntletCheck]? = nil, createdAt: String? = nil) {
        self.id = id
        self.objective = objective
        self.promotionClass = promotionClass
        self.status = status
        self.dryRun = dryRun
        self.checks = checks
        self.createdAt = createdAt
    }
}

public struct GauntletCheck: Identifiable, Codable, Hashable {
    public var id: String
    public var title: String
    public var passed: Bool
    public var detail: String?
    public init(id: String, title: String, passed: Bool, detail: String? = nil) {
        self.id = id
        self.title = title
        self.passed = passed
        self.detail = detail
    }
}

extension ImprovementGauntletStatus {
    public var latestDisplayRun: ImprovementGauntletRun? {
        get throws {
            guard let latestRun else { return nil }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(
                    ImprovementGauntletRun.self, from: latestRun.serializedData(pretty: false)
                )
            } catch {
                throw NSError(domain: "ImprovementGauntlet", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Malformed latest gauntlet run: \(error)"
                ])
            }
        }
    }
}
