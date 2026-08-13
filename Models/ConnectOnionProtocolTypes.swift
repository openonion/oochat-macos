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
nonisolated enum ConnectOnionJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ConnectOnionJSONValue])
    case array([ConnectOnionJSONValue])
    case null

    init(any value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as [String: Any]:
            self = .object(value.mapValues(Self.init(any:)))
        case let value as [Any]:
            self = .array(value.map(Self.init(any:)))
        default:
            self = .null
        }
    }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// A decoded `approval_needed` prompt: the tool call awaiting consent plus
/// any queued calls the agent batched behind the same decision.
nonisolated struct ConnectOnionApprovalRequest: Identifiable, Hashable, Sendable {
    let id: String
    let tool: String
    let arguments: ConnectOnionJSONValue
    let description: String?
    let batchRemaining: [ConnectOnionJSONValue]
}

/// Keyword heuristics that rank and explain a pending tool call so the
/// approval sheet stays useful even for tools the client has never seen.
extension ConnectOnionApprovalRequest {
    var riskLevel: ApprovalRiskLevel {
        let normalized = tool.lowercased()
        let highRiskTerms = [
            "delete", "remove", "unlink", "shell", "command", "execute",
            "send", "reply", "upload", "close"
        ]
        if highRiskTerms.contains(where: normalized.contains) {
            return .high
        }

        let mediumRiskTerms = [
            "write", "edit", "update", "patch", "create", "move", "rename",
            "click", "type", "select", "save"
        ]
        return mediumRiskTerms.contains(where: normalized.contains) ? .medium : .low
    }

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

    var plainEnglishExplanation: String {
        let normalized = tool.lowercased()
        let target = targetSummary.map(Self.shortTarget)

        if ["delete", "remove", "unlink"].contains(where: normalized.contains) {
            return target.map { "Delete \($0)." }
                ?? "Delete the selected item."
        }
        if normalized.contains("write") {
            return target.map {
                "Create or replace \($0) with the content supplied by the agent."
            } ?? "Write content to a file."
        }
        if ["edit", "update", "patch"].contains(where: normalized.contains) {
            return target.map { "Modify \($0) using the agent’s proposed changes." }
                ?? "Modify an existing file or resource."
        }
        if normalized.contains("create") {
            return target.map { "Create \($0)." }
                ?? "Create a new file or resource."
        }
        if ["move", "rename"].contains(where: normalized.contains) {
            return target.map { "Move or rename \($0)." }
                ?? "Move or rename a file or resource."
        }
        if ["shell", "command", "execute", "bash"].contains(where: normalized.contains),
           let command = commandText {
            return Self.explain(command: command)
        }
        if ["send", "reply"].contains(where: normalized.contains) {
            return target.map { "Send information to \($0)." }
                ?? "Send information to an external recipient."
        }
        if normalized.contains("upload") {
            return target.map { "Upload a file to \($0)." }
                ?? "Upload a file to an external service."
        }
        if normalized.contains("click") {
            return "Interact with the currently open webpage."
        }
        return "Allow the agent to run \(tool)."
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

    private static func shortTarget(_ value: String) -> String {
        let lastComponent = URL(fileURLWithPath: value).lastPathComponent
        return lastComponent.isEmpty ? value : lastComponent
    }

    private static func explain(command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = words.first else {
            return "Run a shell command."
        }

        switch executable {
        case "rm":
            return "Delete the files or folders named by this command."
        case "mkdir":
            return "Create one or more folders."
        case "touch":
            return "Create an empty file or update its modified time."
        case "cp":
            return "Copy files or folders to another location."
        case "mv":
            return "Move or rename files or folders."
        case "git":
            let action = words.dropFirst().first ?? "operation"
            return "Run a Git \(action) operation in the repository."
        case "npm", "pnpm", "yarn":
            let action = words.dropFirst().first ?? "command"
            return "Run the \(action) task with \(executable)."
        case "python", "python3":
            return "Run a Python program or script."
        case "swift":
            return "Run a Swift command or program."
        default:
            return "Run a shell command using \(executable)."
        }
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

    var displayName: String {
        switch self {
        case .safe: return "safe"
        case .plan: return "plan"
        case .accept: return "accept"
        }
    }

    var helpText: String {
        switch self {
        case .safe: return "Dangerous tools require approval"
        case .plan: return "Read-only exploration followed by a plan review"
        case .accept: return "Skip all tool approvals for up to 10 turns"
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
        case .safe: return "Safe mode enabled"
        case .plan: return "Plan mode enabled"
        case .accept: return "Accept enabled for up to 10 turns"
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
    case continueTenTurns
    case returnToSafe

    var message: [String: Any] {
        switch self {
        case .continueTenTurns:
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
    case executionItem(ExecutionItem)
    case agentImage(String)
    case agentArtifact(GeneratedArtifactPayload)
    case artifactTransferFailed(String)
    case runtimeInputAcknowledged(localMessageID: UUID)
    case askUser(ConnectOnionAskUserRequest)
    case approvalRequired(ConnectOnionApprovalRequest)
    case onboardingRequired(ConnectOnionOnboardingRequest)
    case onboardingSucceeded(String)
    case modeChanged(AgentExecutionMode)
    case planReviewRequired(ConnectOnionPlanReviewRequest)
    case ulwCheckpointRequired(ConnectOnionULWCheckpointRequest)
    case recoveryState(String)
    /// The hosted agent reached a cancellation boundary and stopped the run.
    case interrupted
    case error(String)
}
