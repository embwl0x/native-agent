import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Parts+Compile.swift` | `Parts.Compiling`: the night's keep moment for one nominated practice, bound around that agent's own turn; every save in that turn is this practice's (one ability and its revisions, its code making the practice's calls; any other save there is refused), staged only (never kept in the act, Full Mac included), its fixtures are the recorded tape's calls with the input they gives each example, its manifest carries `compiled` and its origin the examples' steer; `prepareKeep` keeps a compiled version only once its tape replayed |

extension Parts {
    /// One nominated practice the night hands to its agent's keep moment
    /// (docs/AGENT_IS_THE_APP.md, "Practice compiles"). What she saves under it
    /// is staged: the tape replays it before anything keeps it, and its first
    /// live runs, not the replay, accumulate execution evidence.
    public final class Compiling: @unchecked Sendable {
        public let key: String
        public let principal: String
        /// Each example's calls as a fixture replays them: `{operation, args, result}`.
        public let examples: [[JSONValue]]
        /// Whose words steered the turns the examples came from.
        public let steer: [String]
        /// The practice's calls in order (`app.<action>`, `read`, `find`).
        public let operations: [String]
        private let lock = NSLock()
        private var staged: (id: String, digest: String)?

        public init(key: String, principal: String, examples: [[JSONValue]], steer: [String], operations: [String]) {
            self.key = key; self.principal = principal; self.examples = examples; self.steer = steer
            self.operations = operations
        }

        /// The last version she saved under it, if any.
        public var saved: (id: String, digest: String)? { lock.withLock { staged } }
        func save(id: String, digest: String) { lock.withLock { staged = (id, digest) } }
        /// Every save in this moment is this practice's, by the moment itself:
        /// one ability and its revisions, whose code makes the practice's own
        /// actions. A save that is not this practice is refused here, so
        /// nothing saved in the night's turn escapes staging, the tape or the
        /// examples' provenance.
        func admit(id: String, actions: [String]) throws {
            if let first = lock.withLock({ staged?.id }), first != id {
                throw PartError.invalid("This moment keeps one ability for its practice, \(first); revise that one. Nothing was saved.")
            }
            let missing = operations.filter { $0.hasPrefix("app.") }.map { String($0.dropFirst(4)) }.filter { !Set(actions.map { $0.lowercased() }).contains($0) }
            guard missing.isEmpty else {
                throw PartError.invalid("This moment keeps only the practice it shows, whose calls are \(operations.joined(separator: ", ")); this code does not make \(missing.joined(separator: ", ")). Nothing was saved.")
            }
        }

        /// Her input for each example, in order, joined with the tape: the
        /// replay's fixtures. The calls and replies are never hers to write.
        func fixtures(_ given: JSONValue?) throws -> JSONValue {
            let shape = "fixtures lists, in example order, the input each of the \(examples.count) recorded examples would have been given: [{input: {…}}, …]; the calls and replies come from the tape."
            guard case .array(let inputs)? = given, inputs.count == examples.count else {
                throw PartError.invalid(shape + " Nothing was saved.")
            }
            var cases: [JSONValue] = []
            for (index, entry) in inputs.enumerated() {
                guard case .object(let fields) = entry, fields.count == 1, case .object? = fields["input"], let input = fields["input"] else {
                    throw PartError.invalid("Fixture \(index + 1) is {input: {…}} and nothing else. " + shape + " Nothing was saved.")
                }
                cases.append(.object(["input": input, "calls": .array(examples[index]), "tape": .bool(true)]))
            }
            return .array(cases)
        }

        var record: JSONValue {
            .object(["key": .string(key), "principal": .string(principal), "examples": .int(Int64(examples.count))])
        }
    }

    /// Bound by the night around one agent's keep moment, nowhere else.
    @TaskLocal public static var compiling: Compiling?
}
