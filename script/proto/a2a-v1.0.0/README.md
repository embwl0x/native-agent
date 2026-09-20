# Pinned A2A schema

`a2a.proto` is unmodified from A2A **v1.0.0**, commit
`173695755607e884aa9acf8ce4feed90e32727a1`, `specification/a2a.proto`.
The release uses that path rather than `specification/grpc/a2a.proto`.

The five `google/api` annotation imports are unmodified from googleapis commit
`9f99764bb7841a50f0e46c41fd958a296b108e60`. Both projects use Apache-2.0;
the included LICENSE and source copyright notices apply.

Run `script/regenerate_a2a_grpc.sh` with protoc 33.4, SwiftProtobuf's
`protoc-gen-swift` 1.38.1 and grpc-swift-protobuf's `protoc-gen-grpc-swift-2`
2.4.1. Generated public messages and service/client interfaces live in
ChatOrchestration so the app server and outbound client share one schema.
Annotations are compiler inputs only and do not add generated runtime targets.
