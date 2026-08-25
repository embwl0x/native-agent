import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: ios.screens / ios.chat.runtime.fileAccessPill
//
// The iPhone's runtime envelope is evaluated in the mobile target. This
// companion eval drives the real Mac iCloud-router admission seam so the four
// IDs the pill may present are exactly the IDs the router carries onward.

@Suite("iCloud chat file-access pill boundary")
struct ICloudChatFileAccessPillEvalTests {
    @Test("Mac router admits exactly the iPhone file-access IDs")
    func routerCarriesOnlyCanonicalPillIDs() {
        let acceptedIDs = ICloudChatFileAccessPolicy.acceptedIDs
        #expect(acceptedIDs == ["auto", "read_only", "workspace", "full"])

        for id in acceptedIDs {
            #expect(AppDelegate.iCloudChatFileAccess(from: ["fileAccess": id]) == id)
        }

        #expect(AppDelegate.iCloudChatFileAccess(from: [:]) == "auto")
        #expect(AppDelegate.iCloudChatFileAccess(from: ["fileAccess": "unrecognized"]) == "auto")
    }
}
