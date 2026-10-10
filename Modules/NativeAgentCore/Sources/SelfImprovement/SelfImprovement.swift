import Foundation
import NativeAgentCore
import PersistenceCore

public actor SwiftNativeSelfImprovement {
    let persistence: any PersistenceCoreProtocol
    let dataRoot: URL

    public init(
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        dataRoot: URL = defaultDataRoot()
    ) {
        self.persistence = persistence
        self.dataRoot = dataRoot
    }
}
