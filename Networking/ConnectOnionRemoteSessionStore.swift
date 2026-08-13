import Foundation

/// Where the active request stands; persisted so a relaunch knows whether
/// session recovery is worth attempting.
nonisolated enum ConnectOnionRemoteExecutionState: String, Codable {
    case idle
    case running
    case waitingInteraction
    case recovering
}

/// Everything required to resume a hosted session later: the server session
/// ID, the mirrored session blob, and how far the active input got.
nonisolated struct ConnectOnionRemoteSessionState: Codable {
    var sessionID: String?
    var sessionData: Data?
    var lastMessageID: String?
    var executionState: ConnectOnionRemoteExecutionState = .idle
    var activeInputID: String?
    var inputWasSent = false
    /// Survives view/service recreation so a cancelled run is never recovered.
    var wasInterrupted = false
    var desiredMode: AgentExecutionMode = .safe
    var confirmedMode: AgentExecutionMode = .safe

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case sessionData
        case lastMessageID
        case executionState
        case activeInputID
        case inputWasSent
        case wasInterrupted
        case desiredMode
        case confirmedMode
    }

    init() {}

    /// Decodes field-by-field with defaults so state persisted by older
    /// builds that lack the newer fields still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        sessionData = try container.decodeIfPresent(Data.self, forKey: .sessionData)
        lastMessageID = try container.decodeIfPresent(String.self, forKey: .lastMessageID)
        executionState = try container.decodeIfPresent(
            ConnectOnionRemoteExecutionState.self,
            forKey: .executionState
        ) ?? .idle
        activeInputID = try container.decodeIfPresent(String.self, forKey: .activeInputID)
        inputWasSent = try container.decodeIfPresent(Bool.self, forKey: .inputWasSent) ?? false
        wasInterrupted = try container.decodeIfPresent(Bool.self, forKey: .wasInterrupted) ?? false
        desiredMode = try container.decodeIfPresent(
            AgentExecutionMode.self,
            forKey: .desiredMode
        ) ?? .safe
        confirmedMode = try container.decodeIfPresent(
            AgentExecutionMode.self,
            forKey: .confirmedMode
        ) ?? .safe
    }
}

/// Persists per-conversation session state in `UserDefaults`. Without a
/// conversation ID the store is deliberately ephemeral: loads start fresh
/// and saves are dropped.
nonisolated final class ConnectOnionRemoteSessionStore {
    private let key: String?
    private let initialSessionID: String?

    init(conversationID: UUID?, initialSessionID: String?) {
        key = conversationID.map { "connectonion.remote-session.\($0.uuidString)" }
        self.initialSessionID = initialSessionID
    }

    func load() -> ConnectOnionRemoteSessionState {
        var state: ConnectOnionRemoteSessionState
        if let key,
           let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(
               ConnectOnionRemoteSessionState.self,
               from: data
           ) {
            state = decoded
        } else {
            state = ConnectOnionRemoteSessionState()
        }

        if state.sessionID?.isEmpty != false,
           let initialSessionID,
           !initialSessionID.isEmpty {
            state.sessionID = initialSessionID
            save(state)
        }
        return state
    }

    func save(_ state: ConnectOnionRemoteSessionState) {
        guard let key, let data = try? JSONEncoder().encode(state) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Recovers the remote identifier used by native builds that predate the
/// `ChatSession.remoteSessionID` field.
nonisolated func connectOnionPersistedRemoteSessionID(
    for conversationID: UUID,
    storage: UserDefaults = .standard
) -> String? {
    let key = "connectonion.remote-session.\(conversationID.uuidString)"
    guard let data = storage.data(forKey: key),
          let state = try? JSONDecoder().decode(
              ConnectOnionRemoteSessionState.self,
              from: data
          ),
          let sessionID = state.sessionID,
          !sessionID.isEmpty else {
        return nil
    }
    return sessionID
}

/// Identifier bundle threaded through construction of one usage record.
nonisolated struct ConnectOnionUsageCallContext {
    let agentAddress: String
    let remoteSessionID: String
    let callID: String
    let model: String
    let now: Date
}

/// The narrow slice of `URLSessionWebSocketTask` the client actually uses,
/// kept as a protocol so a scripted socket can be injected.
nonisolated protocol ConnectOnionWebSocketTasking: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(
        with closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    )
}

/// The production socket type satisfies the protocol as-is.
extension URLSessionWebSocketTask: ConnectOnionWebSocketTasking {}

/// A mid-run user message held back until the socket is ready to accept
/// runtime input.
nonisolated struct ConnectOnionPendingRuntimeInput {
    let prompt: String
    let files: [ConnectOnionInputFile]
    let localMessageID: UUID
}

/// Inputs for one connection attempt. `prompt` is nil when the attempt only
/// recovers an execution whose input was already delivered.
nonisolated struct ConnectOnionConnectionRequest {
    let prompt: String?
    let files: [ConnectOnionInputFile]
    let inputID: String
    let identity: ConnectOnionIdentity
    let endpoint: ConnectOnionResolvedEndpoint
}
