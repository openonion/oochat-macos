import ConnectOnionKit
import Foundation

/// Connection status pushed to the UI while a request runs; `isLive` separates
/// an established socket from authentication and reconnect backoff states.
nonisolated struct ConnectOnionTransportUpdate: Sendable {
    let status: String
    let detail: String?
    let isLive: Bool
}

/// Schemaless JSON tree used wherever the protocol carries free-form payloads
/// such as tool arguments and relay metadata. Bridging from Foundation
/// collapses unrecognized values to `.null` rather than throwing.
nonisolated extension JSONValue {
    var displayText: String {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return "null"
        }
        return String(data: prettyData, encoding: .utf8) ?? "null"
    }
}

/// A decoded `approval_needed` prompt: the tool call awaiting consent plus
/// any queued calls the agent batched behind the same decision.
nonisolated struct ConnectOnionApprovalRequest: Identifiable, Hashable, Sendable {
    let id: String
    let tool: String
    let arguments: JSONValue
    let description: String?
    let batchRemaining: [JSONValue]
}

/// Picks out a pending tool call's target and command.
/// The one-sentence summary lives in the Kit (`OOApprovalDisclosure.summary`).
extension ConnectOnionApprovalRequest {
    var targetSummary: String? {
        guard case .object(let values) = arguments else { return nil }
        let keys = [
            "path", "file_path", "filepath", "filename", "target", "url",
            "command", "recipient", "to", "event_id"
        ]
        for key in keys {
            if case .string(let value)? = values[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    var commandText: String? {
        guard case .object(let values) = arguments else { return nil }
        for key in ["command", "cmd", "script"] {
            if case .string(let value)? = values[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

/// One structured input requested inside an `ask_user` prompt.
nonisolated struct ConnectOnionAskUserField: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let label: String
    let type: String
}

/// An `ask_user` question, optionally constrained to preset options or a
/// small form of typed fields.
nonisolated struct ConnectOnionAskUserRequest: Identifiable, Hashable, Sendable {
    let id: String
    let question: String
    let options: [String]
    let multiSelect: Bool
    let fields: [ConnectOnionAskUserField]
}

/// Access gate from an agent that requires onboarding (an invite code or a
/// payment) before it will accept input.
nonisolated struct ConnectOnionOnboardingRequest: Identifiable, Hashable, Sendable {
    let id: String
    let methods: [String]
    let paymentAmount: Double?
    let paymentAddress: String?
}

/// How much autonomy the hosted agent gets: `safe` gates dangerous tools
/// behind approvals, `plan` is read-only, and `accept` rides the protocol's
/// "ulw" mode to skip approvals for `acceptTurns` turns at a time.
nonisolated enum AgentExecutionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case safe
    case plan
    case accept = "ulw"

    static let acceptTurns = 10

    /// The host's mode matching the execution mode. Safe maps to auto (agent asks before tool use),
    /// Plan to read-only, Accept to full-access (run without asking for set turns)
    var permissionMode: OIPPermissionMode {
        switch self {
        case .safe: return .auto
        case .plan: return .readOnly
        case .accept: return .fullAccess
        }
    }

    // Convert host mode to corresponding app mode (reverse conversion)
    init?(permissionMode: OIPPermissionMode) {
        guard let mode = Self.allCases.first(where: { $0.permissionMode == permissionMode }) else {
            return nil
        }
        self = mode
    }

    var displayName: String {
        switch self {
        case .safe: return "Auto"
        case .plan: return "Read only"
        case .accept: return "Full access"
        }
    }

    var helpText: String {
        switch self {
        case .safe: return "Review each action and approve safe work automatically."
        case .plan: return "Ask before any change."
        case .accept: return "Bypass approval for the bounded user-driven turns shown."
        }
    }

    var systemImage: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .plan: return "list.clipboard.fill"
        case .accept: return "bolt.shield.fill"
        }
    }

    var confirmationText: String {
        switch self {
        case .safe: return "Auto enabled"
        case .plan: return "Read only enabled"
        case .accept: return "Full access enabled"
        }
    }
}

/// Plan text the agent submits for review before it may implement anything.
nonisolated struct ConnectOnionPlanReviewRequest: Identifiable, Hashable, Sendable {
    let id: String
    let content: String
}

/// Raised when accept mode has spent its turn budget and the agent pauses
/// for a fresh grant.
nonisolated struct ConnectOnionULWCheckpointRequest: Identifiable, Hashable, Sendable {
    let id: String
    let turnsUsed: Int
    let maxTurns: Int
}

/// User verdict on a submitted plan. `message` spells the outcome out as
/// explicit instructions so the agent cannot misread a rejection as approval.
nonisolated enum ConnectOnionPlanReviewDecision: Hashable, Sendable {
    case approve
    case requestChanges(String)
    case cancel

    var message: [String: Any] {
        let response: String
        switch self {
        case .approve:
            response = "Plan approved. Implement it now in Safe mode. Do not re-enter Plan mode."
        case .requestChanges(let feedback):
            response = "Do not implement this plan. Re-enter Plan mode and revise it using this feedback: \(feedback)"
        case .cancel:
            response = "Plan cancelled. Do not implement it. Return to Safe mode and wait for new instructions."
        }
        return ["type": "plan_review", "message": response]
    }
}

/// Reply to a ULW checkpoint: grant another block of turns or drop the agent
/// back to safe mode.
nonisolated enum ConnectOnionULWCheckpointDecision: Hashable, Sendable {
    case continueTurns
    case returnToSafe

    var message: [String: Any] {
        switch self {
        case .continueTurns:
            return ["action": "continue", "turns": AgentExecutionMode.acceptTurns]
        case .returnToSafe:
            return ["action": "switch_mode", "mode": "safe"]
        }
    }
}

/// User verdict on a tool approval. `approveSession` widens the grant to the
/// rest of the session; both rejection flavors carry feedback back to the
/// agent.
nonisolated enum ConnectOnionApprovalDecision: Hashable, Sendable {
    case approveOnce
    case approveSession
    case rejectSoft(feedback: String)
    case rejectHard(feedback: String)

    var message: [String: Any] {
        switch self {
        case .approveOnce:
            return ["approved": true, "scope": "once"]
        case .approveSession:
            return ["approved": true, "scope": "session"]
        case .rejectSoft(let feedback):
            return [
                "approved": false,
                "mode": "reject_soft",
                "feedback": feedback
            ]
        case .rejectHard(let feedback):
            return [
                "approved": false,
                "mode": "reject_hard",
                "feedback": feedback
            ]
        }
    }
}

/// Union of every prompt that suspends execution until the user responds.
nonisolated enum ConnectOnionPendingInteraction: Hashable, Sendable {
    case askUser(ConnectOnionAskUserRequest)
    case approval(ConnectOnionApprovalRequest)
    case onboarding(ConnectOnionOnboardingRequest)
    case planReview(ConnectOnionPlanReviewRequest)
    case ulwCheckpoint(ConnectOnionULWCheckpointRequest)
}

/// Everything the transport surfaces to the chat layer mid-run: streamed
/// output, execution trace items, artifacts, and interaction prompts.
nonisolated enum ConnectOnionTransportEvent: Sendable {
    case output(String)
    case usage(ChatUsageSummary)
    case agentProfile(OIPAgentProfile)
    case executionItem(ExecutionItem)
    case agentImage(String)
    case agentArtifact(GeneratedArtifactPayload)
    case artifactTransferFailed(String)
    case runtimeInputAcknowledged(localMessageID: UUID)
    case askUser(ConnectOnionAskUserRequest)
    case approvalRequired(ConnectOnionApprovalRequest)
    case onboardingRequired(ConnectOnionOnboardingRequest)
    case onboardingSucceeded(String)
    case modeChanged(AgentExecutionMode, turnsLeft: Int? = nil)
    case sessionModes(available: [AgentExecutionMode], current: AgentExecutionMode?, turnsLeft: Int?)
    case planReviewRequired(ConnectOnionPlanReviewRequest)
    case ulwCheckpointRequired(ConnectOnionULWCheckpointRequest)
    case recoveryState(String)
    /// The hosted agent reached a cancellation boundary and stopped the run.
    case interrupted
    case error(String)
    /// The host refused the protocol version (-32010). Show the Incompatible screen, do not retry.
    case incompatible(OIPHandshake.Incompatibility)
    /// The newest DASHBOARD_SNAPSHOT
    case dashboard(OIPDashboard)
    /// A prompt typed on another device holding this Identity (the host's `user_message` frame).
    case mirroredUserMessage(String)
    /// The turns the host already has for this chat, sent in CONNECTED when this device opens it.
    case catchUp([CatchUpItem], isRunning: Bool)
    /// A decoded frame for the conversation's Work Room store (provider_invocation, provider_activity, provider_message).
    case workRoomFrame(OIPServerFrame)
    /// The handshake's CONNECTED, which rebuilds the Work Rooms from the host's chat items.
    case workRoomSnapshot(OIPConnected)
    /// The turn socket is open: the frame builder and a signed send over it, for Work Room decisions.
    /// `send` returns false when the frame could not be written.
    case workRoomTransport(frames: OIPClientFrames, send: @Sendable ([String: JSONValue]) async -> Bool)
    /// A Claude Station refused the turn's outer INPUT (`provider_station_only`). Not a chat failure.
    case stationRefusedChat
    /// The socket closed or failed; Work Rooms keep what they show.
    case workRoomConnectionDropped
}

extension ConnectOnionTransportEvent {
    /// Feeds the Work Room store rather than the transcript.
    var isWorkRoomEvent: Bool {
        switch self {
        case .workRoomFrame, .workRoomSnapshot, .workRoomTransport, .workRoomConnectionDropped: true
        default: false
        }
    }
}

extension ConnectOnionRemoteError {
    /// Transport events carry only an error's text, so match it back to the error it came from
    /// and give it the plain words both apps share.
    static func chatFailure(forDescription text: String) -> ChatFailure {
        let known: [(ConnectOnionRemoteError, ChatFailure)] = [
            (.agentOffline, .agentOffline),
            (.agentNotFound, .agentNotFound),
            (.connectionClosed, .connectionClosed),
            (.timedOut, .timedOut),
            (.requestInProgress, .busy),
            (.recoveryUnavailable, .notRecovered)
        ]
        for (error, failure) in known where error.errorDescription == text {
            return failure
        }
        // What the host itself said, such as "Agent not connected: 0x…".
        return .server(text)
    }
}
