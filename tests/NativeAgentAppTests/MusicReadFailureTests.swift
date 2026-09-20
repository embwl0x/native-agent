import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

struct MusicReadFailureTests {
    @Test func collectionFailuresAreNotEmptySuccessfulLibraries() async throws {
        for operation in ["search", "library", "playlists"] {
            for denied in [false, true] {
                let result = try await MacAppleScriptBridge.$scriptExecutorForTests.withValue({ source in
                    // A collection command inside a swallowing try was the bug.
                    let collection = try #require(source.range(of: operation == "search"
                        ? "set searchHitsList" : operation == "library" ? "set libraryTracksList" : "set playlistsList"))
                    #expect(!source[..<collection.lowerBound].contains("try"))
                    if denied { throw MacAppleScriptBridge.AppleScriptError.permissionDenied(app: "Music") }
                    throw NSError(domain: "NativeAgentAppleScript", code: -1741)
                }) {
                    switch operation {
                    case "search": try await MacAppleScriptBridge.musicSearchLibrary(input: ["query": .string("Song")])
                    case "library": try await MacAppleScriptBridge.musicListLibrary(input: [:])
                    default: try await MacAppleScriptBridge.musicListPlaylists(input: [:])
                    }
                }
                guard case .object(let object) = result else { Issue.record("Missing result"); return }
                #expect(object["status"] == .string(denied ? "denied" : "failed"))
            }
        }
    }
}
