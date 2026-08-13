import Foundation

/// Sidebar selection: a chat session or one of the fixed utility screens.
enum NavigationItem: Hashable {
    case session(UUID)
    case newConfiguration
    case usage
    case settings
}

/// Reachability of a configured agent as reported by its latest status probe.
enum AgentConnectionState: Equatable {
    case checking
    case online
    case offline
    case invalid
}

/// How the agent was reached: a direct endpoint or the ConnectOnion relay.
enum AgentConnectionRoute: Equatable {
    case direct
    case relay
}

/// Latest status-probe result for one agent, including the metadata the
/// remote endpoint advertised about itself.
struct AgentConnectionSnapshot: Equatable {
    var state: AgentConnectionState
    var route: AgentConnectionRoute?
    var remoteName: String?
    var tools: [String]
    var detail: String?
    var model: String?
    var trust: String?
    var version: String?

    static let checking = AgentConnectionSnapshot(
        state: .checking,
        route: nil,
        remoteName: nil,
        tools: [],
        detail: nil
    )
}

/// Outcome of adding an agent from user input, letting the UI distinguish
/// duplicates from targets that could not be parsed.
enum AddAgentResult: Equatable {
    case added(GeneralAgentConfiguration)
    case duplicate
    case invalid
}

/// A well-known local endpoint probed during automatic discovery. The built-in
/// targets are DEBUG-only so release builds never poll for a local Main Agent.
nonisolated struct LocalAgentDefinition: Equatable, Sendable {
    let fallbackName: String
    let endpoint: String

#if DEBUG
    static let automaticDiscoveryTargets = [
        LocalAgentDefinition(
            fallbackName: "Main Agent",
            endpoint: "http://127.0.0.1:8000"
        )
    ]
#else
    static let automaticDiscoveryTargets: [LocalAgentDefinition] = []
#endif
}
