import ConnectOnionKit
import Foundation

/// Async facade over the remote client, letting callers substitute a stub
/// transport for the real actor.
nonisolated protocol ConnectOnionRemoteAgentProviding: AnyObject, Sendable {
    func probe() async throws -> ConnectOnionResolvedEndpoint
    func loadAgentProfile(
        onEvent: @escaping ConnectOnionRemoteAgentClient.EventHandler
    ) async throws
    func hasPendingExecution() async -> Bool
    func executionModeSnapshot() async -> (
        desired: AgentExecutionMode,
        confirmed: AgentExecutionMode
    )
    func setExecutionMode(_ mode: AgentExecutionMode) async throws
    func send(
        prompt: String,
        files: [ConnectOnionInputFile],
        onUpdate: @escaping ConnectOnionRemoteAgentClient.UpdateHandler,
        onEvent: @escaping ConnectOnionRemoteAgentClient.EventHandler
    ) async throws -> String
    func sendRuntimeInput(
        prompt: String,
        files: [ConnectOnionInputFile],
        localMessageID: UUID
    ) async throws
    func interrupt() async throws
    func respondToAskUser(answer: String) async throws
    func respondToApproval(_ decision: ConnectOnionApprovalDecision) async throws
    func respondToPlanReview(_ decision: ConnectOnionPlanReviewDecision) async throws
    func respondToULWCheckpoint(
        _ decision: ConnectOnionULWCheckpointDecision
    ) async throws
    func submitInviteCode(_ inviteCode: String) async throws
    func recoverIfNeeded(
        onUpdate: @escaping ConnectOnionRemoteAgentClient.UpdateHandler,
        onEvent: @escaping ConnectOnionRemoteAgentClient.EventHandler
    ) async
    func runExec(
        execID: String,
        tool: String,
        args: [String: JSONValue]
    ) async throws -> OIPExecResult
    func disconnect() async
    /// Keeps a connection open for an open Work Room between turns. Returns true when the connection ended in a
    /// way a new one may fix, false when there is nothing to retry (a turn socket is open, or the user must act).
    func holdWorkRoomConnection(
        stationSessionID: String?, inviteCode: String?, handlesOnboarding: Bool,
        onEvent: @escaping ConnectOnionRemoteAgentClient.EventHandler
    ) async -> Bool
}

extension ConnectOnionRemoteAgentProviding {
    func holdWorkRoomConnection(
        stationSessionID: String?, inviteCode: String?, handlesOnboarding: Bool,
        onEvent: @escaping ConnectOnionRemoteAgentClient.EventHandler
    ) async -> Bool {
        // Default for injected test transports that hold no Work Room connection.
        false
    }

    func loadAgentProfile(
        onEvent: @escaping ConnectOnionRemoteAgentClient.EventHandler
    ) async throws {
        // Default no-op for injected test transports that don't load profiles.
    }
}

/// The production client satisfies the facade without any adaptation.
extension ConnectOnionRemoteAgentClient: ConnectOnionRemoteAgentProviding {}

/// Transport failures, partitioned by `isRetryable` so the reconnect loop
/// retries only the failures a fresh socket could plausibly fix.
nonisolated enum ConnectOnionRemoteError: LocalizedError {
    case invalidAgentTarget
    case agentNotFound
    case agentOffline
    case invalidRelayResponse
    case directEndpointUnavailable
    case invalidAgentInfo
    case invalidProtocolMessage
    case connectionClosed
    case timedOut
    case requestInProgress
    case recoveryUnavailable
    case cancelled
    case interrupted
    case interactionRequired(String)
    case server(String)
    case incompatibleProtocol(OIPHandshake.Incompatibility)
    /// A Claude Station refused the outer INPUT (`provider_station_only`): use its Work Room.
    case stationOnly

    var isRetryable: Bool {
        switch self {
        case .connectionClosed, .timedOut, .directEndpointUnavailable:
            return true
        default:
            return false
        }
    }

    /// Set only for -32010. The view model shows the Incompatible screen when it is non-nil.
    var incompatibility: OIPHandshake.Incompatibility? {
        if case .incompatibleProtocol(let value) = self {
            return value
        }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidAgentTarget:
            return "Enter a valid ConnectOnion 0x address or HTTP(S) Direct URL"
        case .agentNotFound:
            return "The ConnectOnion relay could not find this agent"
        case .agentOffline:
            return "The ConnectOnion agent is offline"
        case .invalidRelayResponse:
            return "The ConnectOnion relay returned an invalid response"
        case .directEndpointUnavailable:
            return "The agent's direct endpoint is unavailable"
        case .invalidAgentInfo:
            return "The agent endpoint did not return a matching ConnectOnion address"
        case .invalidProtocolMessage:
            return "The hosted agent returned an invalid protocol message"
        case .connectionClosed:
            return "The hosted agent connection closed unexpectedly"
        case .timedOut:
            return "The hosted agent request timed out"
        case .requestInProgress:
            return "Wait for the current hosted agent request to finish"
        case .recoveryUnavailable:
            return "The hosted session could not be recovered safely. The original task was not resent."
        case .cancelled:
            return "The hosted agent connection was cancelled"
        case .interrupted:
            return "The hosted agent stopped the request"
        case .interactionRequired(let message), .server(let message):
            return message
        case .incompatibleProtocol(let incompatibility):
            return incompatibility.message
        case .stationOnly:
            return "This agent is a Claude Station. Use its Work Room."
        }
    }
}
