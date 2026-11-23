import ConnectOnionKit
import Foundation

/// Drives one hosted-agent conversation over the signed WebSocket protocol:
/// the connect handshake, signed input, live event streaming, interaction
/// replies, and enough persisted state to recover an interrupted execution.
actor ConnectOnionRemoteAgentClient {
    typealias UpdateHandler = (ConnectOnionTransportUpdate) async -> Void
    typealias EventHandler = (ConnectOnionTransportEvent) async -> Void
    typealias SleepHandler = (UInt64) async throws -> Void
    typealias WebSocketFactory = (URL) -> any ConnectOnionWebSocketTasking

    private let configuredTarget: String
    private let resolver: ConnectOnionEndpointResolver
    private let identityStore: ConnectOnionIdentityStore
    private let sessionStore: ConnectOnionRemoteSessionStore
    private let urlSession: URLSession
    private let usageRecorder: (any UsageRecording)?
    private let webSocketFactory: WebSocketFactory
    private let sleep: SleepHandler
    private var endpoint: ConnectOnionResolvedEndpoint?
    private var sessionState: ConnectOnionRemoteSessionState
    private var webSocketTask: (any ConnectOnionWebSocketTasking)?
    private var pendingRuntimeInputs: [ConnectOnionPendingRuntimeInput] = []
    private var pendingRuntimeMessageIDs: [UUID] = []
    private var seenArtifactIDs: Set<String> = []
    private var isAwaitingOnboarding = false
    private var cancelRequested = false
    private var interruptRequested = false
    private var interruptEscalated = false
    private var interruptDeadlineTask: Task<Void, Never>?
    private var canSendControlMessages = false
    private var pendingAskUserRequestID: String?
    private var pendingApprovalRequestID: String?
    private var isSending = false
    private var isObserving = false
    private var liveLLMModelsByID: [String: String] = [:]
    private var eventLedger = EventLedger()
    /// chat_items from the last CONNECTED. The host sends them when its copy of the
    /// session is newer, which is how a turn that finished while we were away is found.
    private var connectedChatItems: [[String: Any]]?
    /// Ids of the Work Room requests sent on the current turn socket. The host's ERROR for one answers that
    /// request in the Work Room; it does not fail the turn.
    private var workRoomRequestIDs: Set<String> = []

    init(
        configuredTarget: String,
        conversationID: UUID?,
        initialSessionID: String? = nil,
        resolver: ConnectOnionEndpointResolver = ConnectOnionEndpointResolver(),
        identityStore: ConnectOnionIdentityStore = .shared,
        urlSession: URLSession = .shared,
        webSocketFactory: WebSocketFactory? = nil,
        sleep: @escaping SleepHandler = {
            try await Task.sleep(nanoseconds: $0)
        },
        usageRecorder: (any UsageRecording)? = nil
    ) {
        self.configuredTarget = configuredTarget
        self.resolver = resolver
        self.identityStore = identityStore
        self.urlSession = urlSession
        self.usageRecorder = usageRecorder
        self.webSocketFactory = webSocketFactory ?? Self.defaultWebSocket(urlSession: urlSession)
        self.sleep = sleep
        sessionStore = ConnectOnionRemoteSessionStore(
            conversationID: conversationID,
            initialSessionID: initialSessionID
                ?? conversationID?.uuidString.lowercased()
        )
        sessionState = sessionStore.load()
    }

    func probe() async throws -> ConnectOnionResolvedEndpoint {
        if let endpoint {
            return endpoint
        }
        let resolved = try await resolver.resolve(configuredTarget)
        endpoint = resolved
        return resolved
    }

    /// Opens a temporary authenticated connection to retrieve the agent's profile without sending an INPUT or starting an execution.
    func loadAgentProfile(
        onEvent: @escaping EventHandler
    ) async throws {
        let target = try await probe()
        let task = webSocketFactory(target.webSocketURL)
        defer { task.cancel(with: .normalClosure, reason: nil) }

        task.resume()

        try await sendFrame( try connectFrame(for: target), over: task)

        // An agent that still requires onboarding has no authenticated
        // profile to show yet. Leave the public agent information in place.
        guard try await waitForProfileHandshake(over: task, onEvent: onEvent) else {
            return
        }
        // Catch-up on open, linked or not. A running turn is left to the viewer, the only one
        // that can follow it to its end, so this never locks the chat.
        await emitCatchUp(isRunning: false, onEvent: onEvent)

        // The host sends AGENT_PROFILE and then the Control Center which O Chat's page gets on open.
        // They are read in whatever order they arrive and the wait ends once both are in.
        // Only these two frames and the keepalive PING are handled here.
        var hasProfile = false
        var hasSnapshot = false
        while !(hasProfile && hasSnapshot), let next = try? await receiveJSON(from: task, timeout: 5) {
            switch next["type"] as? String {
            case "AGENT_PROFILE":
                if case .agentProfile(let profile) = OIPServerFrame.decode(next.mapValues { JSONValue(any: $0) }) {
                    await onEvent(.agentProfile(profile))
                }
                hasProfile = true
            case "DASHBOARD_SNAPSHOT":
                await emitDashboardSnapshot(next, currentSessionID: sessionState.sessionID, onEvent: onEvent)
                hasSnapshot = true
            case "PING":
                try? await sendFrame(OIPClientFrames.pong(), over: task)
            default:
                await emitWorkRoomFrame(next, onEvent: onEvent)
            }
        }
    }

    /// Reads the handshake of a connection that sends no INPUT. True once CONNECTED arrives. Without
    /// `handlesOnboarding`, ONBOARD_REQUIRED or a refusal ends it. With it, ONBOARD_REQUIRED is answered once with
    /// `inviteCode` (the host then replays the CONNECT itself); without a code, or when the host refuses it, the
    /// user is asked (again) and the connection ends, so a new code opens a new connection.
    private func waitForProfileHandshake(
        over task: any ConnectOnionWebSocketTasking, inviteCode: String? = nil, handlesOnboarding: Bool = false,
        onEvent: @escaping EventHandler
    ) async throws -> Bool {
        var submitted: ConnectOnionOnboardingRequest?
        while true {
            let data = try await receiveFrameData(from: task, timeout: 30)
            let step: OIPHandshake.Step

            do {
                step = try OIPHandshake.interpret(data)
            } catch {
                throw ConnectOnionRemoteError.invalidProtocolMessage
            }

            switch step {
            case .established(let connected):
                await adopt(connected, onEvent: onEvent)
                return true

            case .reply(let frame):
                try await sendFrame(frame, over: task)

            case .incompatible(let incompatibility):
                throw ConnectOnionRemoteError.incompatibleProtocol(incompatibility)

            case .onboardRequired(let required):
                guard handlesOnboarding else { return false }
                let request = makeOnboardingRequest(from: required)
                guard let inviteCode, submitted == nil, required.methods.contains("invite_code") else {
                    await onEvent(.onboardingRequired(request))
                    return false
                }
                submitted = request
                try await sendFrame(try frames().onboardSubmit(inviteCode: inviteCode), over: task)

            case .rejected(let message):
                // Only a refused invite code is the user's to fix. Any other refusal (an offline agent, a relay
                // error) is a failed connection, so a held Work Room connection tries again.
                guard let submitted else { throw ConnectOnionRemoteError.server(message) }
                await onEvent(.onboardingRequired(submitted))
                await onEvent(.error(message))
                return false

            case .onboardSucceeded, .ignore:
                continue
            }
        }
    }

    func hasPendingExecution() -> Bool {
        !sessionState.wasInterrupted
            && sessionState.executionState != .idle
            && sessionState.activeInputID != nil
    }

    func executionModeSnapshot() -> (
        desired: AgentExecutionMode,
        confirmed: AgentExecutionMode
    ) {
        (sessionState.desiredMode, sessionState.confirmedMode)
    }

    func setExecutionMode(_ mode: AgentExecutionMode) async throws {
        sessionState.desiredMode = mode

        if isSending, let task = webSocketTask {
            try await sendFrame(try frames().modeChange(mode.permissionMode), over: task)
        } else {
            storeClientModeRequest(mode)
        }
        sessionStore.save(sessionState)
    }

    /// Runs one complete request and returns the agent's final output. Only
    /// one request may be in flight; overlapping calls throw immediately.
    func send(
        prompt: String,
        files: [ConnectOnionInputFile] = [],
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> String {
        guard !isSending else {
            throw ConnectOnionRemoteError.requestInProgress
        }
        isSending = true
        defer { isSending = false }
        cancelRequested = false
        interruptRequested = false
        interruptEscalated = false
        interruptDeadlineTask?.cancel()
        interruptDeadlineTask = nil

        let identity = try identityStore.loadOrCreateIdentity()
        let resolved = try await probe()
        let inputID = UUID().uuidString
        sessionState.executionState = .running
        sessionState.activeInputID = inputID
        sessionState.activePrompt = prompt
        sessionState.inputWasSent = false
        sessionState.wasInterrupted = false
        sessionStore.save(sessionState)

        let request = ConnectOnionConnectionRequest(
            prompt: prompt,
            files: files,
            inputID: inputID,
            identity: identity,
            endpoint: resolved
        )
        return try await runWithRecovery(
            request,
            onUpdate: onUpdate,
            onEvent: onEvent
        )
    }

    /// Reports the user and agent turns in CONNECTED's `chat_items`. Skipped when there are none
    /// and no turn is running.
    private func emitCatchUp(isRunning: Bool, onEvent: EventHandler) async {
        let items = MirroredTurn.items(fromChatItems: connectedChatItems?.map { JSONValue(any: $0) })
        if !items.isEmpty || isRunning {
            await onEvent(.catchUp(items, isRunning: isRunning))
        }
    }

    /// Joins this chat's host session as a viewer: connects with its session_id, reports the
    /// turns the host already has, and shows turns typed on another device until one finishes.
    /// Returns when that turn's reply has been emitted or the socket ends. A local `send` closes
    /// this socket, which ends the call quietly.
    @discardableResult
    func observe(
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async -> ViewerEnding {
        guard !isSending, !isObserving else { return .closed }
        isObserving = true
        defer { isObserving = false }
        do {
            let request = ConnectOnionConnectionRequest(
                prompt: nil,
                files: [],
                inputID: UUID().uuidString,
                identity: try identityStore.loadOrCreateIdentity(),
                endpoint: try await probe()
            )
            let (task, established) = try await establishConnection(
                request,
                onUpdate: onUpdate,
                onEvent: onEvent
            )
            canSendControlMessages = true
            await emitCatchUp(isRunning: established.isRunning, onEvent: onEvent)
            let result = try await receiveConnectionResult(
                over: task,
                endpoint: request.endpoint,
                onUpdate: onUpdate,
                onEvent: onEvent
            )
            await onEvent(.output(result))
            return .turnFinished
        } catch ConnectOnionRemoteError.interrupted {
            await onEvent(.interrupted)
            return .turnFinished
        } catch {
            // ponytail: a dropped viewer socket is not retried; the next chat open or send re-observes.
            return .closed
        }
    }

    /// Feeds an extra user message into the running execution, queueing it
    /// until the initial INPUT has actually gone out on a live socket.
    func sendRuntimeInput(
        prompt: String,
        files: [ConnectOnionInputFile] = [],
        localMessageID: UUID
    ) async throws {
        guard isSending else {
            throw ConnectOnionRemoteError.requestInProgress
        }

        guard sessionState.inputWasSent,
              let task = webSocketTask,
              let endpoint else {
            pendingRuntimeInputs.append(
                ConnectOnionPendingRuntimeInput(
                    prompt: prompt,
                    files: files,
                    localMessageID: localMessageID
                )
            )
            return
        }

        try await sendRuntimeInputNow(
            prompt: prompt,
            files: files,
            localMessageID: localMessageID,
            task: task,
            endpoint: endpoint
        )
    }

    func interrupt() async throws {
        guard isSending || isObserving else {
            throw ConnectOnionRemoteError.requestInProgress
        }

        interruptRequested = true
        // Another device's turn: its input id is not ours, and nothing local is left to recover.
        let turn = ViewerTurnState(isActive: true, isMirrored: !isSending)
        if !turn.isMirrored {
            sessionState.wasInterrupted = true
            sessionStore.save(sessionState)
        }
        if canSendControlMessages, let task = webSocketTask {
            try await sendFrame(
                try frames().interrupt(inputID: turn.interruptInputID(local: sessionState.activeInputID)),
                over: task
            )
        }
        if !turn.isMirrored {
            scheduleInterruptEscalation()
        }
    }

    private func sendRuntimeInputNow(
        prompt: String,
        files: [ConnectOnionInputFile],
        localMessageID: UUID,
        task: any ConnectOnionWebSocketTasking,
        endpoint: ConnectOnionResolvedEndpoint
    ) async throws {
        pendingRuntimeMessageIDs.append(localMessageID)
        do {
            try await sendFrame(
                try frames(for: endpoint).input(
                    inputID: UUID().uuidString,
                    prompt: prompt,
                    files: files.map { JSONValue(any: $0.protocolObject) }
                ),
                over: task
            )
        } catch {
            pendingRuntimeMessageIDs.removeAll { $0 == localMessageID }
            throw error
        }
    }

    func respondToAskUser(answer: String) async throws {
        guard let task = webSocketTask else {
            throw ConnectOnionRemoteError.connectionClosed
        }
        guard let requestID = pendingAskUserRequestID else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        try await sendFrame(
            try frames().askUserResponse(requestID: requestID, answer: answer),
            over: task
        )
        pendingAskUserRequestID = nil
        sessionState.executionState = .running
        sessionStore.save(sessionState)
    }

    func respondToApproval(_ decision: ConnectOnionApprovalDecision) async throws {
        guard let task = webSocketTask else {
            throw ConnectOnionRemoteError.connectionClosed
        }
        guard let requestID = pendingApprovalRequestID else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        try await sendFrame(
            try frames().approvalResponse(
                requestID: requestID,
                decision: decision.message.mapValues { JSONValue(any: $0) }
            ),
            over: task
        )
        pendingApprovalRequestID = nil
        sessionState.executionState = .running
        sessionStore.save(sessionState)
    }

    func respondToPlanReview(_ decision: ConnectOnionPlanReviewDecision) async throws {
        guard let task = webSocketTask else {
            throw ConnectOnionRemoteError.connectionClosed
        }
        try await sendCommand(decision.message, over: task)
        sessionState.executionState = .running
        sessionStore.save(sessionState)
    }

    func respondToULWCheckpoint(
        _ decision: ConnectOnionULWCheckpointDecision
    ) async throws {
        guard let task = webSocketTask else {
            throw ConnectOnionRemoteError.connectionClosed
        }
        try await sendCommand(
            ["type": "ULW_RESPONSE"].merging(decision.message) { $1 },
            over: task
        )
        sessionState.executionState = .running
        sessionStore.save(sessionState)
    }

    func submitInviteCode(_ inviteCode: String) async throws {
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let task = webSocketTask else {
            throw ConnectOnionRemoteError.connectionClosed
        }

        try await sendFrame(try frames().onboardSubmit(inviteCode: code), over: task)
    }

    /// Reattaches to a persisted execution after an interrupted run. Recovery
    /// never resends the original prompt; it only resumes the session.
    func recoverIfNeeded(
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async {
        guard !isSending,
              !sessionState.wasInterrupted,
              sessionState.executionState != .idle,
              let inputID = sessionState.activeInputID else {
            return
        }

        isSending = true
        cancelRequested = false
        interruptRequested = false
        interruptEscalated = false
        interruptDeadlineTask?.cancel()
        interruptDeadlineTask = nil
        sessionState.executionState = .recovering
        sessionStore.save(sessionState)
        defer { isSending = false }

        do {
            let identity = try identityStore.loadOrCreateIdentity()
            let resolved = try await probe()
            let request = ConnectOnionConnectionRequest(
                prompt: nil,
                files: [],
                inputID: inputID,
                identity: identity,
                endpoint: resolved
            )
            let result = try await runWithRecovery(
                request,
                onUpdate: onUpdate,
                onEvent: onEvent
            )
            guard !sessionState.wasInterrupted else { return }
            await onEvent(.output(result))
        } catch {
            guard !sessionState.wasInterrupted else { return }
            // Unique -32010 incompatible error
            if let incompatibility = (error as? ConnectOnionRemoteError)?.incompatibility {
                await onEvent(.incompatible(incompatibility))
            } else {
                await onEvent(.error(error.localizedDescription))
            }
        }
    }

    private static let execTimeout: TimeInterval = 30

    /// Runs tool on the host without the LLM (EXEC) and returns the host's EXEC_RESULT.
    ///
    /// It uses its own short-lived socket so a slow, failed or refused EXEC cannot disturb a running turn
    /// or what the next launch recovers.
    /// Failed tools return `isSuccess == false`. This throws only when
    /// the round trip itself cannot finish (handshake refused, socket lost, no reply in time).
    func runExec(
        execID: String,
        tool: String,
        args: [String: JSONValue]
    ) async throws -> OIPExecResult {
        let target = try await probe()
        let task = webSocketFactory(target.webSocketURL)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        task.resume()

        let builder = OIPClientFrames(keyStore: identityStore, to: target.agentAddress)
        try await sendFrame(
            try builder.connect(direct: target.isDirect, sessionID: nil, session: nil, lastMessageID: nil),
            over: task
        )
        try await waitForExecHandshake(over: task)
        try await sendFrame(try builder.exec(execID: execID, tool: tool, args: args), over: task)
        return try await waitForExecResult(execID: execID, over: task)
    }

    private func waitForExecHandshake(over task: any ConnectOnionWebSocketTasking) async throws {
        while true {
            let data = try await receiveFrameData(from: task, timeout: 30)
            let step: OIPHandshake.Step
            do {
                step = try OIPHandshake.interpret(data)
            } catch {
                throw ConnectOnionRemoteError.invalidProtocolMessage
            }
            switch step {
            case .established:
                return
            case .reply(let frame):
                try await sendFrame(frame, over: task)
            case .incompatible(let incompatibility):
                throw ConnectOnionRemoteError.incompatibleProtocol(incompatibility)
            case .rejected(let message):
                throw ConnectOnionRemoteError.server(message)
            case .onboardRequired:
                throw ConnectOnionRemoteError.server("This agent needs onboarding first. Send it a message to finish it.")
            case .onboardSucceeded, .ignore:
                continue
            }
        }
    }

    /// Reads until the EXEC_RESULT with this exec_id. Other results and unknown frames are skipped.
    private func waitForExecResult(
        execID: String,
        over task: any ConnectOnionWebSocketTasking
    ) async throws -> OIPExecResult {
        let deadline = Date().addingTimeInterval(Self.execTimeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ConnectOnionRemoteError.timedOut
            }
            let data = try await receiveFrameData(from: task, timeout: UInt64(remaining.rounded(.up)))
            guard let fields = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
                continue
            }
            switch OIPServerFrame.decode(fields) {
            case .execResult(let result) where result.execID == execID:
                return result
            case .ping:
                try await sendFrame(OIPClientFrames.pong(), over: task)
            case .error(let error):
                throw ConnectOnionRemoteError.server(error.message ?? "The agent refused the request")
            default:
                continue
            }
        }
    }

    func disconnect() {
        cancelRequested = true
        interruptRequested = false
        interruptDeadlineTask?.cancel()
        closeSocket()
    }

    /// Cuts the saved session back to before your latest message, `prompt`, so the next send redoes it.
    func rewindLatestTurn(prompt: String) -> Bool {
        guard !isSending, sessionState.rewindLatestTurn(prompt: prompt) else {
            return false
        }
        sessionStore.save(sessionState)
        return true
    }
}

/// Connection lifecycle: the retry loop, the handshake, and the event pump.
extension ConnectOnionRemoteAgentClient {
    /// Up to four socket attempts with exponential backoff. When a direct
    /// endpoint exists, the final fallback polls the hosted session over HTTP
    /// instead of giving up.
    private func runWithRecovery(
        _ firstRequest: ConnectOnionConnectionRequest,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> String {
        var request = firstRequest
        var lastError: Error?

        let policy = ReconnectPolicy()

        var state = reduce(.idle, .open, maxAttempts: policy.maxAttempts)

        while case .connecting(let attempt) = state {
            if cancelRequested {
                throw interruptEscalated
                    ? ConnectOnionRemoteError.interrupted
                    : ConnectOnionRemoteError.cancelled
            }

            do {
                if attempt > 0 {
                    await onUpdate(
                        ConnectOnionTransportUpdate(
                            status: statusLabel(.connecting(attempt: attempt)),
                            detail: "Attempt \(attempt + 1) of \(policy.maxAttempts)",
                            isLive: false
                        )
                    )
                    try await sleep(UInt64(policy.delay(for: attempt) * 1_000_000_000))
                    request = await failedOver(request)
                }

                let result = try await runConnection(request, onUpdate: onUpdate, onEvent: onEvent)
                await onEvent(.workRoomConnectionDropped)
                return result
            } catch {
                await onEvent(.workRoomConnectionDropped)
                if let remote = error as? ConnectOnionRemoteError, !remote.isRetryable { throw remote }
                lastError = error
                closeSocket()
                state = reduce(state, .socketClosed, maxAttempts: policy.maxAttempts)
            }
        }

        if request.endpoint.httpBaseURL != nil {
            await onEvent(.recoveryState("Checking the hosted session result"))
            if let result = try await pollForResult(
                endpoint: request.endpoint,
                onEvent: onEvent
            ) {
                return result
            }
        }

        throw lastError ?? ConnectOnionRemoteError.recoveryUnavailable
    }

    /// A direct endpoint that dropped is resolved again, which falls back to the relay when
    /// the agent still looks reachable there, as iOS does. The same session_id and
    /// last_msg_id go out in CONNECT, so the host resumes the run. A lookup that fails, or
    /// one that finds the same socket again, keeps the endpoint the run started on.
    private func failedOver(_ request: ConnectOnionConnectionRequest) async -> ConnectOnionConnectionRequest {
        guard request.endpoint.isDirect,
            let fresh = try? await resolver.resolve(configuredTarget),
            fresh.webSocketURL != request.endpoint.webSocketURL else {
                return request
            }
        endpoint = fresh
        return ConnectOnionConnectionRequest(
            prompt: request.prompt,
            files: request.files,
            inputID: request.inputID,
            identity: request.identity,
            endpoint: fresh
        )
    }

    /// The header's words come from the kit, so macOS and iOS say the same thing.
    private func statusLabel(
        _ state: SessionState,
        hostStatus: String? = nil
    ) -> String {
        SessionStatusLabel.text(
            state: state,
            hasBookmark: sessionState.lastMessageID != nil,
            hostStatus: hostStatus
        )
    }

    private func runConnection(
        _ request: ConnectOnionConnectionRequest,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> String {
        await onUpdate(
            ConnectOnionTransportUpdate(
                status: statusLabel(.connecting(attempt: 0)),
                detail: connectionDetail(for: request.endpoint),
                isLive: false
            )
        )

        let (task, established) = try await establishConnection(
            request,
            onUpdate: onUpdate,
            onEvent: onEvent
        )
        // The INPUT already went out and the host has finished that turn; take the reply
        // from CONNECTED instead of refusing.
        if let settled = await settleFinishedTurn(
            connectedStatus: established.status,
            endpoint: request.endpoint,
            onUpdate: onUpdate,
            onEvent: onEvent
        ) {
            return settled
        }
        try await sendInitialInputIfNeeded(
            request,
            established: established,
            over: task
        )
        try await flushPendingActions(over: task, endpoint: request.endpoint)
        await onUpdate(
            ConnectOnionTransportUpdate(
                status: statusLabel(.connected, hostStatus: "running"),
                detail: established.isRunning ? "Resumed session" : nil,
                isLive: true
            )
        )
        return try await receiveConnectionResult(
            over: task,
            endpoint: request.endpoint,
            onUpdate: onUpdate,
            onEvent: onEvent
        )
    }

    private func establishConnection(
        _ request: ConnectOnionConnectionRequest,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> (any ConnectOnionWebSocketTasking, OIPConnected) {
        closeSocket()
        connectedChatItems = nil
        let task = webSocketFactory(request.endpoint.webSocketURL)
        webSocketTask = task
        task.resume()

        try await sendFrame(try connectFrame(for: request.endpoint), over: task)
        let established = try await waitForConnected(
            over: task,
            onUpdate: onUpdate,
            onEvent: onEvent
        )
        await emitWorkRoomTransport(over: task, endpoint: request.endpoint, onEvent: onEvent)
        return (task, established)
    }

    /// Sends INPUT at most once per execution. On a reconnect the server must
    /// already report the session as running; anything else aborts rather
    /// than risk resubmitting the task.
    private func sendInitialInputIfNeeded(
        _ request: ConnectOnionConnectionRequest,
        established: OIPConnected,
        over task: any ConnectOnionWebSocketTasking
    ) async throws {
        if !sessionState.inputWasSent, let prompt = request.prompt {
            sessionState.inputWasSent = true
            sessionState.executionState = .running
            sessionStore.save(sessionState)

            try await sendFrame(
                try frames(for: request.endpoint).input(
                    inputID: request.inputID,
                    prompt: prompt,
                    files: request.files.map { JSONValue(any: $0.protocolObject) }
                ),
                over: task
            )
        } else if !established.isRunning {
            throw ConnectOnionRemoteError.recoveryUnavailable
        }
    }

    private func flushPendingActions(
        over task: any ConnectOnionWebSocketTasking,
        endpoint: ConnectOnionResolvedEndpoint
    ) async throws {
        canSendControlMessages = true
        if interruptRequested {
            try await sendFrame(
                try frames().interrupt(inputID: sessionState.activeInputID),
                over: task
            )
        }
        let queuedInputs = pendingRuntimeInputs
        pendingRuntimeInputs.removeAll()
        for input in queuedInputs {
            try await sendRuntimeInputNow(
                prompt: input.prompt,
                files: input.files,
                localMessageID: input.localMessageID,
                task: task,
                endpoint: endpoint
            )
        }
    }

    private func receiveConnectionResult(
        over task: any ConnectOnionWebSocketTasking,
        endpoint: ConnectOnionResolvedEndpoint,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> String {
        while true {
            let event = try await receiveJSON(from: task, timeout: 90)
            // Any inbound frame — including the hosted agent's 30s keepalive
            // PING, which its ping task emits even while an LLM call blocks the
            // run — proves the socket is still alive, so restart the interrupt
            // silence deadline. Escalation then fires only when the socket has
            // actually gone quiet, never merely because a slow call ran long.
            if interruptRequested {
                scheduleInterruptEscalation()
            }
            if recordEventIfNew(event) == false {
                continue
            }
            if let result = try await processIncomingEvent(
                event,
                over: task,
                endpoint: endpoint,
                onUpdate: onUpdate,
                onEvent: onEvent
            ) {
                return result
            }
        }
    }

    private func recordEventIfNew(_ event: [String: Any]) -> Bool {
        guard let eventID = event["id"] as? String else {
            return true
        }

        let dedupeKey = Self.eventDedupeKey(for: event, id: eventID)

        guard eventLedger.record(eventID: dedupeKey) else {
            return false
        }

        sessionState.lastMessageID = eventID
        sessionStore.save(sessionState)

        return true
    }

    private func processIncomingEvent(
        _ event: [String: Any],
        over task: any ConnectOnionWebSocketTasking,
        endpoint: ConnectOnionResolvedEndpoint,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> String? {
        switch event["type"] as? String {
        case "OUTPUT":
            return try await completeOutput(
                event,
                endpoint: endpoint,
                onUpdate: onUpdate,
                onEvent: onEvent
            )

        case "PING":
            try await sendFrame(OIPClientFrames.pong(), over: task)

        case "user_message":
            if let content = MirroredTurn.prompt(fromUserMessage: event.mapValues { JSONValue(any: $0) }) {
                await onEvent(.mirroredUserMessage(content))
            }

        case "DASHBOARD_SNAPSHOT":
            await emitDashboardSnapshot(event, currentSessionID: sessionState.sessionID, onEvent: onEvent)

        case "AGENT_PROFILE":
            let fields = event.mapValues { JSONValue(any: $0) }

            if case .agentProfile(let profile) = OIPServerFrame.decode(fields) {
                await onEvent(.agentProfile(profile))
            }

        case "ERROR":
            try await handleError(event, onEvent: onEvent)

        case "ask_user":
            pendingAskUserRequestID = Self.requestID(from: event)
            markWaitingForInteraction()
            await onEvent(.askUser(makeAskUserRequest(from: event)))

        case "approval_needed":
            await emitWorkRoomFrame(event, onEvent: onEvent)
            pendingApprovalRequestID = Self.requestID(from: event)
            markWaitingForInteraction()
            await onEvent(.approvalRequired(makeApprovalRequest(from: event)))

        case "mode_changed":
            await handleModeChange(event, onEvent: onEvent)

        case "plan_review":
            try await handlePlanReview(event, onEvent: onEvent)

        case "ulw_turns_reached":
            try await handleULWCheckpoint(event, onEvent: onEvent)

        case "ONBOARD_REQUIRED":
            isAwaitingOnboarding = true
            markWaitingForInteraction()
            await onEvent(.onboardingRequired(makeOnboardingRequest(from: event)))

        case "RUNTIME_INPUT_ACK":
            await handleRuntimeInputAcknowledgement(
                onUpdate: onUpdate,
                onEvent: onEvent
            )

        case "interrupt_ack":
            // A slow interrupt can be acknowledged after this client already
            // escalated and moved on. Such a late ack replays onto the next
            // request's socket; ignore it unless this request actually asked
            // to stop, or it would mislabel a healthy turn as "Stopping".
            guard interruptRequested,
                  interruptFrameMatchesActiveRun(event) else { break }
            await onUpdate(
                ConnectOnionTransportUpdate(
                    status: "Stopping",
                    detail: "Hosted agent acknowledged the interrupt",
                    isLive: true
                )
            )

        case "interrupt_complete":
            // Same race as interrupt_ack: a completion for an already-abandoned
            // run can arrive on the next request's socket. Honoring it here
            // would throw .interrupted and kill a turn the user never stopped.
            guard interruptRequested,
                  interruptFrameMatchesActiveRun(event) else { break }
            interruptRequested = false
            interruptDeadlineTask?.cancel()
            interruptDeadlineTask = nil
            sessionState.executionState = .idle
            sessionState.activeInputID = nil
            sessionState.activePrompt = nil
            sessionState.inputWasSent = false
            // The cancelled run is now cleanly terminal, so the flag has done
            // its recovery-blocking job. Clear it here or it survives to the
            // next turn and silently suppresses that turn's output.
            sessionState.wasInterrupted = false
            sessionStore.save(sessionState)
            closeSocket()
            throw ConnectOnionRemoteError.interrupted

        case "agent_image":
            await onEvent(
                .agentImage(try Self.validatedAgentImageURL(from: event))
            )

        case "agent_artifact":
            await emitArtifacts(
                from: event["artifact"] ?? event,
                onEvent: onEvent
            )

        case let type? where WorkRoomStore.frameTypes.contains(type):
            await onEvent(.workRoomFrame(OIPServerFrame.decode(event.mapValues { JSONValue(any: $0) })))

        case "intent", "thinking", "llm_call", "llm_result",
             "tool_result", "eval", "tool_call":
            await recordLiveUsageEvent(event, endpoint: endpoint)
            if let item = Self.makeExecutionItem(from: event) {
                await onEvent(.executionItem(item))
            }

        default:
            break
        }
        return nil
    }

    /// Whether an interrupt frame belongs to the run this request is driving.
    /// The peer echoes back the input_id the interrupt named, so a stale frame
    /// from an abandoned run that replays onto this socket carries the old id
    /// and is rejected — even when this turn is itself interrupting, which the
    /// interruptRequested flag alone cannot distinguish. A frame without an
    /// input_id comes from an older host, where that flag stays the only guard.
    private func interruptFrameMatchesActiveRun(_ event: [String: Any]) -> Bool {
        guard let framedInputID = event["input_id"] as? String else {
            return true
        }
        return framedInputID == sessionState.activeInputID
    }

    /// A turn that finished while this client was away (app quit, socket dropped) is not
    /// replayed: CONNECTED says "connected" and the turn sits in chat_items. Take its reply
    /// only if the turn's user message is the prompt we sent. Otherwise return nil, and
    /// sendInitialInputIfNeeded refuses as before without resending anything.
    private func settleFinishedTurn(
        connectedStatus: String,
        endpoint: ConnectOnionResolvedEndpoint,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async -> String? {
        // A run the user stopped is never recovered, here or in recoverIfNeeded.
        guard sessionState.inputWasSent,
              !sessionState.wasInterrupted,
              connectedStatus != "running",
              let prompt = sessionState.activePrompt,
              let turn = Self.finishedTurn(matching: prompt, in: connectedChatItems),
              let reply = turn.last(where: { $0["type"] as? String == "agent" })?["content"] as? String,
              !reply.isEmpty else {
            return nil
        }
        sessionState.executionState = .idle
        sessionState.activeInputID = nil
        sessionState.activePrompt = nil
        sessionState.inputWasSent = false
        sessionState.wasInterrupted = false
        sessionStore.save(sessionState)
        closeSocket()
        await onEvent(.recoveryState("Recovered completed session"))
        await onUpdate(
            ConnectOnionTransportUpdate(
                status: statusLabel(.connected, hostStatus: "connected"),
                detail: connectionDetail(for: endpoint),
                isLive: true
            )
        )
        return reply
    }

    /// The chat items after the last user message, only when that message is `prompt`.
    /// nil when there are none, or the last turn belongs to an older message (our INPUT
    /// never arrived), whose reply must not be shown as this prompt's answer.
    nonisolated static func finishedTurn(
        matching prompt: String,
        in chatItems: [[String: Any]]?
    ) -> [[String: Any]]? {
        guard let chatItems else {
            return nil
        }
        var lastUserContent: String?
        var turn: [[String: Any]] = []
        for item in chatItems {
            if item["type"] as? String == "user" {
                lastUserContent = item["content"] as? String
                turn.removeAll()
            } else {
                turn.append(item)
            }
        }
        let expected = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastUserContent,
              lastUserContent.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
            return nil
        }
        return turn
    }

    private func completeOutput(
        _ event: [String: Any],
        endpoint: ConnectOnionResolvedEndpoint,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> String {
        guard let result = event["result"] as? String else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        if let usage = Self.makeUsageSummary(from: event) {
            await onEvent(.usage(usage))
        }
        await recordUsage(from: event, endpoint: endpoint)
        await emitArtifacts(
            from: Self.generatedArtifacts(in: event["session"]),
            onEvent: onEvent
        )
        saveSession(from: event["session"])
        sessionState.executionState = .idle
        sessionState.activeInputID = nil
        sessionState.activePrompt = nil
        sessionState.inputWasSent = false
        interruptRequested = false
        // Reaching a normal output is terminal for any in-flight interrupt too;
        // clear the flag so it never carries into and mutes the next turn.
        sessionState.wasInterrupted = false
        sessionStore.save(sessionState)
        closeSocket()
        await onUpdate(
            ConnectOnionTransportUpdate(
                status: statusLabel(.connected, hostStatus: "connected"),
                detail: connectionDetail(for: endpoint),
                isLive: true
            )
        )
        return result
    }

    /// Every ERROR goes to the Work Room store first. One that answers a Work Room request (or is a stale approval
    /// answer) is the Work Room's alone. A Station refusing the outer INPUT ends the turn as `stationOnly`, which
    /// is not a chat failure. Anything else fails the turn as before.
    private func handleError(_ event: [String: Any], onEvent: @escaping EventHandler) async throws {
        await emitWorkRoomFrame(event, onEvent: onEvent)
        guard case .error(let error) = OIPServerFrame.decode(event.mapValues { JSONValue(any: $0) }) else {
            return try await handleServerError(event, onEvent: onEvent)
        }
        if let requestID = error.requestID, workRoomRequestIDs.remove(requestID) != nil {
            return
        }
        if error.code == .string(OIPErrorCode.staleAnswer) {
            return
        }
        if error.isProviderStationOnly {
            endExecutionWithoutRecovery()
            throw ConnectOnionRemoteError.stationOnly
        }
        try await handleServerError(event, onEvent: onEvent)
    }

    private func handleServerError(
        _ event: [String: Any],
        onEvent: @escaping EventHandler
    ) async throws {
        let message = (event["message"] as? String)
            ?? (event["error"] as? String)
            ?? "Unknown server error"
        if isAwaitingOnboarding {
            await onEvent(.error(message))
            return
        }
        throw ConnectOnionRemoteError.server(message)
    }

    private func markWaitingForInteraction() {
        sessionState.executionState = .waitingInteraction
        sessionStore.save(sessionState)
    }

    private func handleModeChange(
        _ event: [String: Any],
        onEvent: @escaping EventHandler
    ) async {
        guard let rawMode = event["mode"] as? String,
              let mode = AgentExecutionMode(rawValue: rawMode)
                ?? AgentExecutionMode(permissionMode: OIPPermissionMode(protocolValue: rawMode)) else {
            return
        }
        sessionState.desiredMode = mode
        sessionState.confirmedMode = mode
        sessionStore.save(sessionState)
        await onEvent(.modeChanged(mode, turnsLeft: Self.intValue(event["turns_left"])))
    }

    private func handlePlanReview(
        _ event: [String: Any],
        onEvent: @escaping EventHandler
    ) async throws {
        guard let content = event["plan_content"] as? String else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        markWaitingForInteraction()
        await onEvent(
            .planReviewRequired(
                ConnectOnionPlanReviewRequest(
                    id: (event["id"] as? String) ?? UUID().uuidString,
                    content: content
                )
            )
        )
    }

    private func handleULWCheckpoint(
        _ event: [String: Any],
        onEvent: @escaping EventHandler
    ) async throws {
        guard let turnsUsed = Self.intValue(event["turns_used"]),
              let maxTurns = Self.intValue(event["max_turns"]) else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        markWaitingForInteraction()
        await onEvent(
            .ulwCheckpointRequired(
                ConnectOnionULWCheckpointRequest(
                    id: (event["id"] as? String) ?? UUID().uuidString,
                    turnsUsed: turnsUsed,
                    maxTurns: maxTurns
                )
            )
        )
    }

    private func handleRuntimeInputAcknowledgement(
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async {
        if let localMessageID = pendingRuntimeMessageIDs.first {
            pendingRuntimeMessageIDs.removeFirst()
            await onEvent(.runtimeInputAcknowledged(localMessageID: localMessageID))
        }
        await onUpdate(
            ConnectOnionTransportUpdate(
                status: statusLabel(.connected, hostStatus: "running"),
                detail: "Input queued",
                isLive: true
            )
        )
    }

    private func connectionDetail(
        for endpoint: ConnectOnionResolvedEndpoint
    ) -> String {
        endpoint.isDirect ? "Direct endpoint" : "ConnectOnion relay"
    }
}

/// Socket plumbing, recovery polling, usage accounting, and the signed
/// message builders.
extension ConnectOnionRemoteAgentClient {
    private func emitArtifacts(
        from value: Any?,
        onEvent: @escaping EventHandler
    ) async {
        guard let value else { return }
        let candidates = value as? [Any] ?? [value]
        for candidate in candidates {
            guard let object = candidate as? [String: Any],
                  object["data_base64"] != nil else {
                continue
            }
            do {
                let payload = try Self.makeGeneratedArtifactPayload(
                    from: object
                )
                guard seenArtifactIDs.insert(
                    payload.reference.artifactID
                ).inserted else {
                    continue
                }
                await onEvent(.agentArtifact(payload))
            } catch {
                await onEvent(
                    .artifactTransferFailed(
                        "A generated file could not be verified or cached."
                    )
                )
            }
        }
    }

    /// Waits for CONNECTED. The package reads every frame (`OIPHandshake`,`OIPServerFrame`).
    /// -32010 ends the attempt for good; `incompatibleProtocol` is not retryable
    private func waitForConnected(
        over task: any ConnectOnionWebSocketTasking,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> OIPConnected {
        while true {
            let data = try await receiveFrameData(from: task, timeout: 30)
            let step: OIPHandshake.Step
            do {
                step = try OIPHandshake.interpret(data)
            } catch {
                throw ConnectOnionRemoteError.invalidProtocolMessage
            }
            switch step {
            case .established(let connected):
                await adopt(connected, onEvent: onEvent)
                if let modes = connected.sessionModes {
                    await onEvent(
                        .sessionModes(
                            available: modes.availableModes.compactMap {
                                AgentExecutionMode(permissionMode: $0.id)
                            },
                            current: modes.currentMode.flatMap(AgentExecutionMode.init(permissionMode:)),
                            turnsLeft: modes.turnsLeft
                        )
                    )
                }
                return connected

            case .reply(let frame):
                try await sendFrame(frame, over: task)

            case .incompatible(let incompatibility):
                endExecutionWithoutRecovery()
                throw ConnectOnionRemoteError.incompatibleProtocol(incompatibility)

            case .rejected(let message):
                if isAwaitingOnboarding {
                    await onEvent(.error(message))
                    continue
                }
                throw ConnectOnionRemoteError.server(message)

            case .onboardRequired(let required):
                isAwaitingOnboarding = true
                sessionState.executionState = .waitingInteraction
                sessionStore.save(sessionState)
                await onUpdate(
                    ConnectOnionTransportUpdate(
                        status: "Access required",
                        detail: "Agent onboarding required",
                        isLive: true
                    )
                )
                await onEvent(.onboardingRequired(makeOnboardingRequest(from: required)))

            case .onboardSucceeded(let message):
                isAwaitingOnboarding = false
                await onEvent(.onboardingSucceeded(message ?? "Access granted"))

            case .ignore:
                continue
            }
        }
    }

    /// The host refused the protocol, so INPUT was never sent and nothing is running.
    /// Clear the execution, or `recoverIfNeeded` would reconnect at the next launch and hit -32010 again.
    private func endExecutionWithoutRecovery() {
        closeSocket()
        sessionState.executionState = .idle
        sessionState.activeInputID = nil
        sessionState.inputWasSent = false
        sessionStore.save(sessionState)
    }

    /// Keeps the host's session id, and its copy of the conversation when it is the newer one.
    /// A different id means the old session is not ours any more; drop transcript.
    private func adopt(_ connected: OIPConnected, onEvent: EventHandler) async {
        await onEvent(.workRoomSnapshot(connected))
        let asked = sessionState.sessionID
        if let sessionID = connected.sessionID {
            sessionState.sessionID = sessionID
        }
        sessionStore.save(sessionState)
        connectedChatItems = connected.chatItems?.compactMap { $0.anyValue as? [String: Any] }
        if connected.serverNewer {
            saveSession(from: connected.session.map { JSONValue.object($0).anyValue })
        } else if connected.replacesSession(asked: asked) {
            sessionState.sessionData = nil
            sessionState.lastMessageID = nil
            sessionStore.save(sessionState)
        }
    }

    /// Last-resort recovery over HTTP: polls the hosted session until it
    /// reports `done`, surfacing intermediate status without reopening a
    /// socket or resending input.
    private func pollForResult(
        endpoint: ConnectOnionResolvedEndpoint,
        onEvent: @escaping EventHandler
    ) async throws -> String? {
        guard let baseURL = endpoint.httpBaseURL,
              let sessionID = sessionState.sessionID else {
            return nil
        }

        let url = baseURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)

        sessionState.executionState = .recovering
        sessionStore.save(sessionState)

        for attempt in 0..<15 {
            if cancelRequested {
                throw ConnectOnionRemoteError.cancelled
            }
            if attempt > 0 {
                try await sleep(2_000_000_000)
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await urlSession.data(for: request)
            } catch {
                continue
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                continue
            }
            if httpResponse.statusCode == 404 {
                continue
            }
            guard (200..<300).contains(httpResponse.statusCode),
                  let result = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let status = result["status"] as? String else {
                continue
            }

            switch status {
            case "done":
                guard let output = result["result"] as? String else {
                    throw ConnectOnionRemoteError.invalidProtocolMessage
                }
                if let usage = Self.makeUsageSummary(from: result) {
                    await onEvent(.usage(usage))
                }
                await recordUsage(from: result, endpoint: endpoint)
                await emitArtifacts(
                    from: Self.generatedArtifacts(in: result["session"]),
                    onEvent: onEvent
                )
                saveSession(from: result["session"])
                sessionState.executionState = .idle
                sessionState.activeInputID = nil
                sessionState.activePrompt = nil
                sessionState.inputWasSent = false
                sessionStore.save(sessionState)
                await onEvent(.recoveryState("Recovered completed session"))
                return output

            case "running":
                await onEvent(.recoveryState("The hosted agent is still running"))

            case "waiting_approval":
                await onEvent(.recoveryState("The hosted agent is waiting for approval"))

            default:
                await onEvent(.recoveryState("Hosted session status: \(status)"))
            }
        }

        return nil
    }

    private func recordLiveUsageEvent(
        _ event: [String: Any],
        endpoint: ConnectOnionResolvedEndpoint
    ) async {
        guard let usageRecorder else { return }

        if event["type"] as? String == "llm_call",
           let id = Self.usageCallID(from: event),
           let model = Self.normalizedModel(event["model"] as? String) {
            liveLLMModelsByID[id] = model
            return
        }

        let callID = Self.usageCallID(from: event)
        let cachedModel = callID.flatMap { liveLLMModelsByID[$0] }
        guard let record = Self.makeLiveUsageRecord(
            from: event,
            agentAddress: endpoint.agentAddress,
            remoteSessionID: sessionState.sessionID ?? "unknown-session",
            fallbackModel: cachedModel ?? endpoint.info?.model
        ) else {
            return
        }
        await usageRecorder.record(record)
    }

    private func recordUsage(
        from payload: [String: Any],
        endpoint: ConnectOnionResolvedEndpoint
    ) async {
        guard let usageRecorder else { return }
        let records = Self.makeUsageRecords(
            from: payload,
            agentAddress: endpoint.agentAddress,
            remoteSessionID: sessionState.sessionID ?? "unknown-session",
            fallbackModel: endpoint.info?.model
        )
        for record in records {
            await usageRecorder.record(record)
        }
    }

    private func makeApprovalRequest(
        from event: [String: Any]
    ) -> ConnectOnionApprovalRequest {
        let batch = (event["batch_remaining"] as? [Any] ?? [])
            .map(JSONValue.init(any:))
        return ConnectOnionApprovalRequest(
            id: (event["id"] as? String) ?? UUID().uuidString,
            tool: (event["tool"] as? String) ?? "unknown",
            arguments: JSONValue(any: event["arguments"] ?? [:]),
            description: event["description"] as? String,
            batchRemaining: batch
        )
    }

    private func makeAskUserRequest(
        from event: [String: Any]
    ) -> ConnectOnionAskUserRequest {
        let fields: [ConnectOnionAskUserField] = (
            event["fields"] as? [[String: Any]] ?? []
        ).compactMap { field -> ConnectOnionAskUserField? in
            guard let name = field["name"] as? String else { return nil }
            return ConnectOnionAskUserField(
                name: name,
                label: (field["label"] as? String) ?? name,
                type: (field["type"] as? String) ?? "text"
            )
        }
        return ConnectOnionAskUserRequest(
            id: (event["id"] as? String) ?? UUID().uuidString,
            question: (event["question"] as? String)
                ?? (event["text"] as? String)
                ?? "The agent needs more information.",
            options: event["options"] as? [String] ?? [],
            multiSelect: event["multi_select"] as? Bool ?? false,
            fields: fields
        )
    }

    private func makeOnboardingRequest(
        from required: OIPOnboardRequired,
        id: String? = nil
    ) -> ConnectOnionOnboardingRequest {
        ConnectOnionOnboardingRequest(
            id: id ?? required.identity ?? UUID().uuidString,
            methods: required.methods,
            paymentAmount: required.paymentAmount,
            paymentAddress: required.paymentAddress
        )
    }

    /// ONBOARD_REQUIRED inside a running turn. Same frame, same decoder as in the handshake.
    private func makeOnboardingRequest(
        from event: [String: Any]
    ) -> ConnectOnionOnboardingRequest {
        if let fields = JSONValue(any: event).objectValue,
           case .onboardRequired(let required) = OIPServerFrame.decode(fields) {
            return makeOnboardingRequest(from: required, id: event["id"] as? String)
        }
        return ConnectOnionOnboardingRequest(id: UUID().uuidString, methods: [], paymentAmount: nil, paymentAddress: nil)
    }

    /// Builds CONNECT frame for this endpoint, with saved session so reconnection resumes.
    /// Session decoded with JSONDecover so stored 0,1 stay as a number (not bool)
    private func connectFrame(
        for endpoint: ConnectOnionResolvedEndpoint
    ) throws -> [String: JSONValue] {
        // While settling an INPUT that already went out, send no turn history. The host then
        // counts its own copy as newer and returns chat_items, so a turn that finished while
        // we were away can be read back. Otherwise read back with JSONDecoder, not
        // JSONValue(any:), so a stored 0 or 1 stays a number.
        let session = sessionState.inputWasSent
            ? nil
            : sessionState.sessionData.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        return try frames(for: endpoint).connect(
            direct: endpoint.isDirect,
            sessionID: sessionState.sessionID,
            session: session,
            lastMessageID: sessionState.lastMessageID
        )
    }

    /// Returns the id of an agent's question/approval event; `request_id` or `id`.
    /// User reply must have identical id to the prompt, otherwise dropped by host.
    nonisolated static func requestID(from event: [String: Any]) -> String? {
        (event["request_id"] as? String) ?? (event["id"] as? String)
    }

    private func storeClientModeRequest(_ mode: AgentExecutionMode) {
        var session: [String: Any] = [:]
        if let data = sessionState.sessionData,
           let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            session = stored
        }

        var request: [String: Any] = ["mode": mode.rawValue]
        if mode == .accept {
            request["turns"] = AgentExecutionMode.acceptTurns
        }
        session["client_mode_request"] = request
        session["updated"] = Date().timeIntervalSince1970

        if JSONSerialization.isValidJSONObject(session) {
            sessionState.sessionData = try? JSONSerialization.data(
                withJSONObject: session,
                options: [.sortedKeys]
            )
        }
    }

    private func saveSession(from value: Any?) {
        guard let value,
              JSONSerialization.isValidJSONObject(value) else {
            sessionStore.save(sessionState)
            return
        }
        let sanitized = Self.sessionWithoutArtifactPayloads(value)
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized) else {
            sessionStore.save(sessionState)
            return
        }
        sessionState.sessionData = data
        sessionStore.save(sessionState)
    }

    /// A frame builder for one agent. Signing key from identity store, recipient from `target`
    /// or current connection. Throws if no connection for recipient.
    private func frames(for target: ConnectOnionResolvedEndpoint? = nil) throws -> OIPClientFrames {
        guard let target = target ?? endpoint else {
            throw ConnectOnionRemoteError.connectionClosed
        }
        return OIPClientFrames(keyStore: identityStore, to: target.agentAddress)
    }

    /// Sends the commands with no named builder in the package (plan_review, ULW_RESPONSE)
    /// The dictionary's `type` becomes the command type, then removed from fields since the signer
    /// owns it; since fields that set signer-owned values are rejected.
    private func sendCommand(
        _ object: [String: Any],
        over task: any ConnectOnionWebSocketTasking
    ) async throws {
        guard let type = object["type"] as? String else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }

        var fields = object.mapValues { JSONValue(any: $0) }
        fields["type"] = nil

        try await sendFrame(
            try frames().command(type: type, fields: fields),
            over: task
        )
    }

    /// Convert built and signed frame (by OIPClientFrames) to dictionary type for `sendJSON`.
    /// Never signs, last step before network.
    private func sendFrame(
        _ frame: [String: JSONValue],
        over task: any ConnectOnionWebSocketTasking
    ) async throws {
        try await sendJSON(frame.mapValues {$0.anyValue}, over: task)
    }

    // JSONSerialisation here is fine.
    // Writes a frame to the socket. Already signed, so serialization details do not affect signature.
    private func sendJSON(
        _ object: [String: Any],
        over task: any ConnectOnionWebSocketTasking
    ) async throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        try await task.send(.string(text))
    }

    private func receiveJSON(
        from task: any ConnectOnionWebSocketTasking,
        timeout: UInt64
    ) async throws -> [String: Any] {
        let data = try await receiveFrameData(from: task, timeout: timeout)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        return object
    }

    /// One received frame, undecoded. The handshake hands it to `OIPHandshake`.
    private func receiveFrameData(
        from task: any ConnectOnionWebSocketTasking,
        timeout: UInt64
    ) async throws -> Data {
        let message = try await withThrowingTaskGroup(
            of: URLSessionWebSocketTask.Message.self
        ) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                task.cancel(with: .goingAway, reason: nil)
                throw ConnectOnionRemoteError.timedOut
            }

            guard let message = try await group.next() else {
                throw ConnectOnionRemoteError.connectionClosed
            }
            group.cancelAll()
            return message
        }

        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        return data
    }

    private func closeSocket() {
        canSendControlMessages = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    /// The hosted agent can only observe an interrupt at a safe boundary, and
    /// its current LLM call is a blocking, non-streaming request that cannot be
    /// aborted mid-flight — so a genuine interrupt is confirmed only once that
    /// call returns (often several seconds). Escalating on a fixed delay from the
    /// request force-closed the socket while the run was still alive; the peer's
    /// late interrupt frames then replayed onto the next request's socket, and a
    /// message the user sent in that window was swallowed as a runtime input into
    /// the dying run and never answered.
    ///
    /// So this is a silence deadline, not a fixed one: `receiveConnectionResult`
    /// restarts it on every inbound frame, and the hosted agent's ping task emits
    /// a keepalive every 30s even while an LLM call blocks the run. A slow-but-
    /// alive run keeps resetting the deadline and waits however long it needs for
    /// the real interrupt_complete; only a socket that has genuinely gone quiet
    /// for the full window escalates (below the 90s receive timeout so it still
    /// surfaces as a clean interrupt).
    private func scheduleInterruptEscalation() {
        interruptDeadlineTask?.cancel()
        interruptEscalated = false
        interruptDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 75_000_000_000)
            } catch {
                return
            }
            await self?.escalateInterruptIfNeeded()
        }
    }

    private func escalateInterruptIfNeeded() {
        guard interruptRequested else { return }
        interruptEscalated = true
        cancelRequested = true
        interruptRequested = false
        sessionState.executionState = .idle
        sessionState.activeInputID = nil
        sessionState.activePrompt = nil
        sessionState.inputWasSent = false
        // Escalation forces the run terminal; drop the flag with it so a later
        // turn is not left muted by a stale interrupt marker.
        sessionState.wasInterrupted = false
        sessionStore.save(sessionState)
        closeSocket()
    }
}

/// The Work Room's side of the connection: provider frames for its store, the transport its requests go out on, and
/// a connection held open between turns. Here, not in its own file, because it uses the actor's private state.
extension ConnectOnionRemoteAgentClient {
    /// Hands a frame the Work Room store acts on to it; any other frame is ignored.
    private func emitWorkRoomFrame(_ event: [String: Any], onEvent: EventHandler) async {
        guard let type = event["type"] as? String, WorkRoomStore.frameTypes.contains(type) else { return }
        await onEvent(.workRoomFrame(OIPServerFrame.decode(event.mapValues { JSONValue(any: $0) })))
    }

    /// Hands the open socket's frame builder and signed send to the Work Room store. `endpoint` is the host this
    /// socket reached; the client's own `endpoint` is not set yet on every path. A new socket starts with no
    /// Work Room requests of its own.
    private func emitWorkRoomTransport(
        over task: any ConnectOnionWebSocketTasking,
        endpoint: ConnectOnionResolvedEndpoint,
        onEvent: EventHandler
    ) async {
        workRoomRequestIDs = []
        guard let frames = try? frames(for: endpoint) else { return }
        await onEvent(.workRoomTransport(frames: frames, send: { [weak self] frame in
            await self?.sendWorkRoomFrame(frame, over: task) ?? false
        }))
    }

    /// Sends a Work Room request and remembers its id, so the host's ERROR for it is not taken as the turn's.
    /// False when the write failed.
    private func sendWorkRoomFrame(_ frame: [String: JSONValue], over task: any ConnectOnionWebSocketTasking) async -> Bool {
        if let requestID = (frame["request_id"] ?? frame["requestId"])?.stringValue {
            workRoomRequestIDs.insert(requestID)
        }
        do {
            try await sendFrame(frame, over: task)
            return true
        } catch {
            return false
        }
    }

    /// Between turns no turn socket is open, so a Work Room has nothing to send Provider Input over.
    /// This opens the same signed connection the profile loader uses, hands the Work Room store its
    /// transport, and keeps reading provider frames into the store until the caller is cancelled or the
    /// connection drops. It never sends INPUT. It does nothing while a turn socket is open, and a turn
    /// that opens later takes over the store's transport; the caller cancels this when a turn starts.
    /// `stationSessionID` is the session a paired Claude Station returned: the connection resumes it so the
    /// host streams the Station's Work Room. A Station pane sets `handlesOnboarding`: the host's
    /// ONBOARD_REQUIRED is then answered with `inviteCode` when there is one, and otherwise shown to the user.
    /// Returns true when the connection could not be opened or ended on its own, so a new one may work; false
    /// when a turn socket is open or the user has to act first.
    func holdWorkRoomConnection(
        stationSessionID: String? = nil, inviteCode: String? = nil, handlesOnboarding: Bool = false,
        onEvent: @escaping EventHandler
    ) async -> Bool {
        guard webSocketTask == nil else { return false }
        guard let target = try? await probe() else { return true }
        if let stationSessionID {
            sessionState.sessionID = stationSessionID
        }
        let task = webSocketFactory(target.webSocketURL)
        var shouldRetry = true
        await withTaskCancellationHandler {
            task.resume()
            do {
                try await sendFrame(try connectFrame(for: target), over: task)
                guard try await waitForProfileHandshake(
                    over: task, inviteCode: inviteCode, handlesOnboarding: handlesOnboarding, onEvent: onEvent
                ) else {
                    shouldRetry = false
                    return
                }
                await emitWorkRoomTransport(over: task, endpoint: target, onEvent: onEvent)
                while true {
                    let frame = try await receiveJSON(from: task, timeout: 90)
                    if frame["type"] as? String == "PING" {
                        try? await sendFrame(OIPClientFrames.pong(), over: task)
                    } else {
                        await emitWorkRoomFrame(frame, onEvent: onEvent)
                    }
                }
            } catch {
                // The connection ended; the store is told below.
            }
        } onCancel: {
            task.cancel(with: .normalClosure, reason: nil)
        }
        task.cancel(with: .normalClosure, reason: nil)
        // A turn socket that opened meanwhile owns the store's transport now; leave it alone.
        if webSocketTask == nil {
            await onEvent(.workRoomConnectionDropped)
        }
        return shouldRetry
    }
}
