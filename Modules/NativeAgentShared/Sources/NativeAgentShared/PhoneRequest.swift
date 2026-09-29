import Foundation

/// Signed BridgeMessage bodies in the existing NAChatMessage device-sync lane.
public struct PhoneRequest: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case currentLocation = "location.current", pickPhoto = "photo.pick", capturePhoto = "photo.capture"
    }
    public static let messageKind = "phone_request"
    public let id: String
    public let kind: Kind
    public let params: [String: String]
    public let expiresAt: Date

    public init(kind: Kind, params: [String: String] = [:], waitSeconds: Int) {
        id = UUID().uuidString
        self.kind = kind
        self.params = params
        expiresAt = Date().addingTimeInterval(TimeInterval(waitSeconds))
    }
}

public struct PhoneRequestResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case completed, denied, cancelled, expired, failed }
    public static let messageKind = "phone_request_result"
    public let requestID: String
    public let status: Status
    public let values: [String: String]
    public let message: String?

    public init(requestID: String, status: Status, values: [String: String] = [:], message: String? = nil) {
        self.requestID = requestID
        self.status = status
        self.values = values
        self.message = message
    }
}
