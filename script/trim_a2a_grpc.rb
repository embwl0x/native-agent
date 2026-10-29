#!/usr/bin/env ruby
# Keep only the generated server APIs used by NativeAgent. The pinned
# generator has a Client switch but no switch for its simple-service API.
path = ARGV.fetch(0)
source = File.read(path)
source = source.split("\n// MARK: lf.a2a.v1.A2AService (client)", 2).first.rstrip + "\n"
source.sub!(/\n    \/\/\/ Simple service protocol.*?\n    \}\n(?=\})/m, "\n")
source.sub!(/\n\/\/ Default implementation of methods from 'ServiceProtocol'\.\n@available[^\n]*\nextension Lf_A2a_V1_A2AService\.SimpleServiceProtocol \{.*?\n\}\n/m, "\n")
source.sub!("    /// Where possible, prefer using the stricter, less-verbose ``ServiceProtocol``\n    /// or ``SimpleServiceProtocol`` instead.",
            "    /// Where possible, prefer using the stricter, less-verbose ``ServiceProtocol``.")
source.sub!(/    \/\/\/ This protocol is higher level than ``StreamingServiceProtocol`` but lower level than\n.*?    \/\/\/ use ``StreamingServiceProtocol``\./m,
            "    /// This protocol provides request, response and trailing response metadata.\n    /// Use ``StreamingServiceProtocol`` for fine grained streaming control.")
raise "Unused gRPC API remains after trimming" if source.match?(/SimpleServiceProtocol|ClientProtocol|public struct Client</)
header = "// Blueprint: | `a2a.grpc.swift` | `GRPCCore`: `Lf_A2a_V1_A2AService`, `Method`, `SendMessage` |"
source.sub!("import SwiftProtobuf\n", "import SwiftProtobuf\n#{header}\n") unless source.include?(header)
File.write(path, source.rstrip + "\n")
