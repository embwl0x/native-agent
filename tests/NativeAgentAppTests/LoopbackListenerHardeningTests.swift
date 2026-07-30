import Network
import Foundation
import Testing
@testable import NativeAgentApp

@Test func nativeBridgeListenerParametersRequireLoopbackInterface() {
    let parameters = NativeLoopbackListenerParameters.tcp()
    #expect(parameters.requiredInterfaceType == .loopback)
    #expect(parameters.includePeerToPeer == false)
}

@Test func nativeBridgePortPlanAdvancesThenUsesSystemAssignedFallback() {
    let plan = NativeLoopbackPortPlan(preferredPort: 8771, consecutiveFallbacks: 2)

    #expect(plan.candidates == [
        .fixed(8771),
        .fixed(8772),
        .fixed(8773),
        .automatic,
    ])
    #expect(plan[4] == nil)
}

@Test func nativeBridgePortPlanCannotOverflowTheTCPPortRange() {
    let plan = NativeLoopbackPortPlan(preferredPort: UInt16.max, consecutiveFallbacks: 15)
    #expect(plan.candidates == [.fixed(UInt16.max), .automatic])
}

@Test func nativeBridgeRetriesOnlyAddressInUseFailures() {
    #expect(NativeLoopbackListenerParameters.isAddressInUse(NWError.posix(.EADDRINUSE)))
    #expect(!NativeLoopbackListenerParameters.isAddressInUse(NWError.posix(.ECONNREFUSED)))
}

@Test func nativeBridgeDiscoveryFilesArePrivateAtCreation() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-private-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("bridge.json")

    #expect(NativePrivateFile.write(Data("private".utf8), to: file))
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try Data(contentsOf: file) == Data("private".utf8))
}
