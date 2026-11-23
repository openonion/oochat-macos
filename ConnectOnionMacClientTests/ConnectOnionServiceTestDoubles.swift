import Combine
import CryptoKit
import XCTest
import ConnectOnionKit
@testable import ConnectOnionMacClient

enum StubRemoteOperation: Hashable {
    case probe
    case send
    case runtimeInput
    case interrupt
    case askUser
    case approval
    case mode
    case planReview
    case ulwCheckpoint
    case inviteCode
    case exec
}

private enum StubRemoteError: LocalizedError {
    case failed(StubRemoteOperation)

    var errorDescription: String? {
        "Stub remote operation failed"
    }
}

struct StubSentRequest: Sendable {
    let prompt: String
    let files: [ConnectOnionInputFile]
}

actor StubRemoteAgentClient: ConnectOnionRemoteAgentProviding {
    let endpoint: ConnectOnionResolvedEndpoint
    var pendingExecution: Bool
    var failures: Set<StubRemoteOperation>
    var calls: [String] = []
    var sentRequests: [StubSentRequest] = []
    private var desiredMode: AgentExecutionMode = .safe
    private var confirmedMode: AgentExecutionMode = .safe
    let emitsApprovalOnSend: Bool
    /// Sent after the stub's own events on each send.
    let eventsOnSend: [ConnectOnionTransportEvent]

    init(
        endpoint: ConnectOnionResolvedEndpoint,
        pendingExecution: Bool = false,
        failures: Set<StubRemoteOperation> = [],
        emitsApprovalOnSend: Bool = false,
        eventsOnSend: [ConnectOnionTransportEvent] = []
    ) async {
        self.endpoint = endpoint
        self.pendingExecution = pendingExecution
        self.failures = failures
        self.emitsApprovalOnSend = emitsApprovalOnSend
        self.eventsOnSend = eventsOnSend
    }

    func probe() async throws -> ConnectOnionResolvedEndpoint {
        calls.append("probe")
        try failIfNeeded(.probe)
        return endpoint
    }

    func hasPendingExecution() async -> Bool {
        calls.append("hasPendingExecution")
        return pendingExecution
    }

    func executionModeSnapshot() async -> (
        desired: AgentExecutionMode,
        confirmed: AgentExecutionMode
    ) {
        calls.append("executionModeSnapshot")
        return (desiredMode, confirmedMode)
    }

    func setExecutionMode(_ mode: AgentExecutionMode) async throws {
        calls.append("setExecutionMode:\(mode.rawValue)")
        try failIfNeeded(.mode)
        desiredMode = mode
        confirmedMode = mode
    }

    func send(
        prompt: String,
        files: [ConnectOnionInputFile],
        onUpdate: @escaping ConnectOnionRemoteAgentClient.UpdateHandler,
        onEvent: @escaping ConnectOnionRemoteAgentClient.EventHandler
    ) async throws -> String {
        calls.append("send:\(prompt):\(files.count)")
        sentRequests.append(
            StubSentRequest(prompt: prompt, files: files)
        )
        try failIfNeeded(.send)
        await onUpdate(
            ConnectOnionTransportUpdate(
                status: "Running",
                detail: "Stub execution",
                isLive: true
            )
        )
        if emitsApprovalOnSend {
            await onEvent(
                .approvalRequired(
                    ConnectOnionApprovalRequest(
                        id: "stale-safe-approval",
                        tool: "bash",
                        arguments: .object([
                            "command": .string("touch accepted.txt")
                        ]),
                        description: nil,
                        batchRemaining: []
                    )
                )
            )
        }
        await onEvent(.modeChanged(.accept))
        for event in eventsOnSend {
            await onEvent(event)
        }
        return "stub response"
    }

    func sendRuntimeInput(
        prompt: String,
        files: [ConnectOnionInputFile],
        localMessageID _: UUID
    ) async throws {
        calls.append("runtimeInput:\(prompt):\(files.count)")
        try failIfNeeded(.runtimeInput)
    }

    func interrupt() async throws {
        calls.append("interrupt")
        try failIfNeeded(.interrupt)
    }

    func respondToAskUser(answer: String) async throws {
        calls.append("askUser:\(answer)")
        try failIfNeeded(.askUser)
    }

    func respondToApproval(_ decision: ConnectOnionApprovalDecision) async throws {
        calls.append("approval:\(decision)")
        try failIfNeeded(.approval)
    }

    func respondToPlanReview(_ decision: ConnectOnionPlanReviewDecision) async throws {
        calls.append("planReview:\(decision)")
        try failIfNeeded(.planReview)
    }

    func respondToULWCheckpoint(
        _ decision: ConnectOnionULWCheckpointDecision
    ) async throws {
        calls.append("ulwCheckpoint:\(decision)")
        try failIfNeeded(.ulwCheckpoint)
    }

    func submitInviteCode(_ inviteCode: String) async throws {
        calls.append("inviteCode:\(inviteCode)")
        try failIfNeeded(.inviteCode)
    }

    func recoverIfNeeded(
        onUpdate: @escaping ConnectOnionRemoteAgentClient.UpdateHandler,
        onEvent: @escaping ConnectOnionRemoteAgentClient.EventHandler
    ) async {
        calls.append("recoverIfNeeded")
        pendingExecution = false
        await onUpdate(
            ConnectOnionTransportUpdate(
                status: "Recovered",
                detail: "Stub recovery",
                isLive: true
            )
        )
        await onEvent(.modeChanged(.plan))
        for event in eventsOnRecover {
            await onEvent(event)
        }
    }

    func disconnect() async {
        calls.append("disconnect")
    }

    var execReply: [String: JSONValue] = ["status": .string("success"), "result": .string("stub output")]

    func runExec(
        execID: String,
        tool: String,
        args _: [String: JSONValue]
    ) async throws -> OIPExecResult {
        calls.append("runExec:\(tool)")
        try failIfNeeded(.exec)
        var frame = execReply
        frame["type"] = .string("EXEC_RESULT")
        frame["exec_id"] = .string(execID)
        frame["tool"] = .string(tool)
        guard case .execResult(let result) = OIPServerFrame.decode(frame) else {
            throw StubRemoteError.failed(.exec)
        }
        return result
    }

    // What the host sends on the profile visit after the probe (loadAgentProfile); empty = nothing.
    var profileVisitEvents: [ConnectOnionTransportEvent] = []

    func setProfileVisitEvents(_ events: [ConnectOnionTransportEvent]) {
        profileVisitEvents = events
    }

    func loadAgentProfile(onEvent: @escaping ConnectOnionRemoteAgentClient.EventHandler) async throws {
        for event in profileVisitEvents {
            await onEvent(event)
        }
    }

    func setPendingExecution(_ value: Bool) {
        pendingExecution = value
    }

    /// Sent after the stub's own events on each recovery.
    var eventsOnRecover: [ConnectOnionTransportEvent] = []

    func setEventsOnRecover(_ events: [ConnectOnionTransportEvent]) {
        eventsOnRecover = events
    }

    func setFailures(_ value: Set<StubRemoteOperation>) {
        failures = value
    }

    func callSnapshot() -> [String] {
        calls
    }

    func sentRequestSnapshot() -> [StubSentRequest] {
        sentRequests
    }

    private func failIfNeeded(_ operation: StubRemoteOperation) throws {
        if failures.contains(operation) {
            throw StubRemoteError.failed(operation)
        }
    }
}
