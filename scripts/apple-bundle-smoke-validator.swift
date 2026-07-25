import Foundation

private struct RuntimeReady: Decodable {
    let type: String
    let protocolVersion: Int
    let origin: URL
    let basePath: String

    enum CodingKeys: String, CodingKey {
        case type, origin
        case protocolVersion = "protocol_version"
        case basePath = "base_path"
    }
}

private struct RuntimeDiscovery: Decodable {
    let protocolVersion: Int
    let apiBase: String
    let authentication: String
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case authentication, capabilities
        case protocolVersion = "protocol_version"
        case apiBase = "api_base"
    }
}

private struct Agent: Decodable {
    let id: String
}

private enum SmokeValidationError: LocalizedError {
    case invalidArguments
    case invalidReadyDocument
    case invalidDiscoveryDocument
    case invalidProjectsDocument
    case invalidAgentsDocument([String])
    case discoveryExposesToken

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "usage: apple-bundle-smoke-validator <ready.json> <discovery.json> <projects.json> <agents.json>"
        case .invalidReadyDocument:
            "Bundled Runtime readiness metadata is incompatible or not loopback-only."
        case .invalidDiscoveryDocument:
            "Bundled Runtime discovery metadata is incompatible."
        case .invalidProjectsDocument:
            "Fresh bundled Runtime did not return an empty Projects array."
        case let .invalidAgentsDocument(ids):
            "Bundled Runtime Agent catalog is incomplete: \(ids.joined(separator: ", "))"
        case .discoveryExposesToken:
            "Bundled Runtime discovery unexpectedly exposes a token."
        }
    }
}

private func data(at path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

do {
    guard CommandLine.arguments.count == 5 else {
        throw SmokeValidationError.invalidArguments
    }
    let ready = try JSONDecoder().decode(
        RuntimeReady.self,
        from: data(at: CommandLine.arguments[1])
    )
    guard ready.type == "ready",
          ready.protocolVersion == 1,
          ready.origin.scheme == "http",
          ready.origin.host == "127.0.0.1",
          ready.origin.port != nil,
          ready.basePath.hasPrefix("/")
    else {
        throw SmokeValidationError.invalidReadyDocument
    }

    let discoveryData = try data(at: CommandLine.arguments[2])
    let discovery = try JSONDecoder().decode(RuntimeDiscovery.self, from: discoveryData)
    let requiredCapabilities: Set<String> = [
        "projects", "sessions", "teams", "files", "git", "terminals", "workspace_events",
    ]
    guard discovery.protocolVersion == 1,
          discovery.apiBase == "/api/v1",
          discovery.authentication == "bearer",
          requiredCapabilities.isSubset(of: Set(discovery.capabilities))
    else {
        throw SmokeValidationError.invalidDiscoveryDocument
    }
    if let object = try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any],
       object["token"] != nil {
        throw SmokeValidationError.discoveryExposesToken
    }

    let projects = try JSONSerialization.jsonObject(
        with: data(at: CommandLine.arguments[3])
    )
    guard let projects = projects as? [Any], projects.isEmpty else {
        throw SmokeValidationError.invalidProjectsDocument
    }

    let agents = try JSONDecoder().decode(
        [Agent].self,
        from: data(at: CommandLine.arguments[4])
    )
    let expectedAgentIDs: Set<String> = ["claude_code", "codex", "opencode"]
    let agentIDs = Set(agents.map(\.id))
    guard expectedAgentIDs.isSubset(of: agentIDs) else {
        throw SmokeValidationError.invalidAgentsDocument(agentIDs.sorted())
    }

    print(
        "Standalone Runtime valid: protocol 1, bearer auth, "
            + "\(agents.count) Agents, isolated empty workspace."
    )
} catch {
    fputs("Standalone bundle validation failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
