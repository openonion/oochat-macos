import CryptoKit
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
    private var seenEventIDs: Set<String> = []
    private var seenArtifactIDs: Set<String> = []
    private var isAwaitingOnboarding = false
    private var cancelRequested = false
    private var interruptRequested = false
    private var interruptEscalated = false
    private var interruptDeadlineTask: Task<Void, Never>?
    private var canSendControlMessages = false
    private var isSending = false
    private var liveLLMModelsByID: [String: String] = [:]

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
        self.webSocketFactory = webSocketFactory ?? {
            urlSession.webSocketTask(with: $0)
        }
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
            try await sendJSON(Self.buildModeChangeMessage(mode), over: task)
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
        guard isSending else {
            throw ConnectOnionRemoteError.requestInProgress
        }

        interruptRequested = true
        sessionState.wasInterrupted = true
        sessionStore.save(sessionState)
        if canSendControlMessages, let task = webSocketTask {
            try await sendJSON(
                Self.buildInterruptMessage(inputID: sessionState.activeInputID),
                over: task
            )
        }
        scheduleInterruptEscalation()
    }

    private func sendRuntimeInputNow(
        prompt: String,
        files: [ConnectOnionInputFile],
        localMessageID: UUID,
        task: any ConnectOnionWebSocketTasking,
        endpoint: ConnectOnionResolvedEndpoint
    ) async throws {
        let identity = try identityStore.loadOrCreateIdentity()
        pendingRuntimeMessageIDs.append(localMessageID)
        do {
            try await sendJSON(
                Self.buildInputMessage(
                    prompt: prompt,
                    files: files,
                    inputID: UUID().uuidString,
                    identity: identity,
                    endpoint: endpoint
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
        try await sendJSON(
            ["type": "ASK_USER_RESPONSE", "answer": answer],
            over: task
        )
        sessionState.executionState = .running
        sessionStore.save(sessionState)
    }

    func respondToApproval(_ decision: ConnectOnionApprovalDecision) async throws {
        guard let task = webSocketTask else {
            throw ConnectOnionRemoteError.connectionClosed
        }
        try await sendJSON(decision.message, over: task)
        sessionState.executionState = .running
        sessionStore.save(sessionState)
    }

    func respondToPlanReview(_ decision: ConnectOnionPlanReviewDecision) async throws {
        guard let task = webSocketTask else {
            throw ConnectOnionRemoteError.connectionClosed
        }
        try await sendJSON(decision.message, over: task)
        sessionState.executionState = .running
        sessionStore.save(sessionState)
    }

    func respondToULWCheckpoint(
        _ decision: ConnectOnionULWCheckpointDecision
    ) async throws {
        guard let task = webSocketTask else {
            throw ConnectOnionRemoteError.connectionClosed
        }
        try await sendJSON(decision.message, over: task)
        sessionState.executionState = .running
        sessionStore.save(sessionState)
    }

    func submitInviteCode(_ inviteCode: String) async throws {
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let task = webSocketTask else {
            throw ConnectOnionRemoteError.connectionClosed
        }

        let identity = try identityStore.loadOrCreateIdentity()
        let payload: [String: Any] = [
            "timestamp": Int(Date().timeIntervalSince1970),
            "invite_code": code
        ]
        try await sendJSON(
            [
                "type": "ONBOARD_SUBMIT",
                "payload": payload,
                "from": identity.address,
                "signature": try identity.signature(for: payload)
            ],
            over: task
        )
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
            await onEvent(.error(error.localizedDescription))
        }
    }

    func disconnect() {
        cancelRequested = true
        interruptRequested = false
        interruptDeadlineTask?.cancel()
        closeSocket()
    }
}

/// Connection lifecycle: the retry loop, the handshake, and the event pump.
extension ConnectOnionRemoteAgentClient {
    /// Up to four socket attempts with exponential backoff. When a direct
    /// endpoint exists, the final fallback polls the hosted session over HTTP
    /// instead of giving up.
    private func runWithRecovery(
        _ request: ConnectOnionConnectionRequest,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> String {
        var lastError: Error?

        for attempt in 0..<4 {
            if cancelRequested {
                throw interruptEscalated
                    ? ConnectOnionRemoteError.interrupted
                    : ConnectOnionRemoteError.cancelled
            }
            do {
                if attempt > 0 {
                    await onUpdate(
                        ConnectOnionTransportUpdate(
                            status: "Reconnecting",
                            detail: "Attempt \(attempt + 1) of 4",
                            isLive: false
                        )
                    )
                    let delay = UInt64(1 << (attempt - 1)) * 1_000_000_000
                    try await sleep(delay)
                }

                return try await runConnection(
                    request,
                    onUpdate: onUpdate,
                    onEvent: onEvent
                )
            } catch let error as ConnectOnionRemoteError where !error.isRetryable {
                throw error
            } catch {
                lastError = error
                closeSocket()
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

    private func runConnection(
        _ request: ConnectOnionConnectionRequest,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> String {
        await onUpdate(
            ConnectOnionTransportUpdate(
                status: "Authenticating",
                detail: connectionDetail(for: request.endpoint),
                isLive: false
            )
        )

        let (task, connectedStatus) = try await establishConnection(
            request,
            onUpdate: onUpdate,
            onEvent: onEvent
        )
        try await sendInitialInputIfNeeded(
            request,
            connectedStatus: connectedStatus,
            over: task
        )
        try await flushPendingActions(over: task, endpoint: request.endpoint)
        await onUpdate(
            ConnectOnionTransportUpdate(
                status: "Running",
                detail: connectedStatus == "running" ? "Resumed session" : nil,
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
    ) async throws -> (any ConnectOnionWebSocketTasking, String) {
        closeSocket()
        let task = webSocketFactory(request.endpoint.webSocketURL)
        webSocketTask = task
        task.resume()

        try await sendJSON(
            buildConnectMessage(
                identity: request.identity,
                endpoint: request.endpoint
            ),
            over: task
        )
        let connectedStatus = try await waitForConnected(
            over: task,
            onUpdate: onUpdate,
            onEvent: onEvent
        )
        return (task, connectedStatus)
    }

    /// Sends INPUT at most once per execution. On a reconnect the server must
    /// already report the session as running; anything else aborts rather
    /// than risk resubmitting the task.
    private func sendInitialInputIfNeeded(
        _ request: ConnectOnionConnectionRequest,
        connectedStatus: String,
        over task: any ConnectOnionWebSocketTasking
    ) async throws {
        if !sessionState.inputWasSent, let prompt = request.prompt {
            sessionState.inputWasSent = true
            sessionState.executionState = .running
            sessionStore.save(sessionState)
            try await sendJSON(
                Self.buildInputMessage(
                    prompt: prompt,
                    files: request.files,
                    inputID: request.inputID,
                    identity: request.identity,
                    endpoint: request.endpoint
                ),
                over: task
            )
        } else if connectedStatus != "running" {
            throw ConnectOnionRemoteError.recoveryUnavailable
        }
    }

    private func flushPendingActions(
        over task: any ConnectOnionWebSocketTasking,
        endpoint: ConnectOnionResolvedEndpoint
    ) async throws {
        canSendControlMessages = true
        if interruptRequested {
            try await sendJSON(
                Self.buildInterruptMessage(inputID: sessionState.activeInputID),
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
        guard seenEventIDs.insert(dedupeKey).inserted else {
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
            try await sendJSON(["type": "PONG"], over: task)

        case "ERROR":
            try await handleServerError(event, onEvent: onEvent)

        case "ask_user":
            markWaitingForInteraction()
            await onEvent(.askUser(makeAskUserRequest(from: event)))

        case "approval_needed":
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
        sessionState.inputWasSent = false
        interruptRequested = false
        // Reaching a normal output is terminal for any in-flight interrupt too;
        // clear the flag so it never carries into and mutes the next turn.
        sessionState.wasInterrupted = false
        sessionStore.save(sessionState)
        closeSocket()
        await onUpdate(
            ConnectOnionTransportUpdate(
                status: "Connected",
                detail: connectionDetail(for: endpoint),
                isLive: true
            )
        )
        return result
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
              let mode = AgentExecutionMode(rawValue: rawMode) else {
            return
        }
        sessionState.desiredMode = mode
        sessionState.confirmedMode = mode
        sessionStore.save(sessionState)
        await onEvent(.modeChanged(mode))
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
                status: "Running",
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

    private func waitForConnected(
        over task: any ConnectOnionWebSocketTasking,
        onUpdate: @escaping UpdateHandler,
        onEvent: @escaping EventHandler
    ) async throws -> String {
        while true {
            let event = try await receiveJSON(from: task, timeout: 30)
            switch event["type"] as? String {
            case "CONNECTED":
                guard let status = event["status"] as? String,
                      let sessionID = event["session_id"] as? String else {
                    throw ConnectOnionRemoteError.invalidProtocolMessage
                }
                sessionState.sessionID = sessionID
                sessionStore.save(sessionState)
                if event["server_newer"] as? Bool == true {
                    saveSession(from: event["session"])
                }
                return status

            case "PING":
                try await sendJSON(["type": "PONG"], over: task)

            case "ERROR":
                let message = (event["message"] as? String)
                    ?? (event["error"] as? String)
                    ?? "Authentication failed"
                if isAwaitingOnboarding {
                    await onEvent(.error(message))
                    continue
                }
                throw ConnectOnionRemoteError.server(
                    message
                )

            case "ONBOARD_REQUIRED":
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
                await onEvent(.onboardingRequired(makeOnboardingRequest(from: event)))

            case "ONBOARD_SUCCESS":
                isAwaitingOnboarding = false
                let message = (event["message"] as? String) ?? "Access granted"
                await onEvent(.onboardingSucceeded(message))

            default:
                continue
            }
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

    nonisolated static func makeUsageSummary(
        from payload: [String: Any]
    ) -> ChatUsageSummary? {
        guard let session = payload["session"] as? [String: Any],
              let trace = session["trace"] as? [[String: Any]] else {
            return nil
        }

        var latestTokenCount = 0
        var totalCost = 0.0
        var latestContextPercent: Double?

        for entry in trace where entry["type"] as? String == "llm_result" {
            if let usage = entry["usage"] as? [String: Any] {
                let inputTokens = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
                let outputTokens = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
                latestTokenCount = inputTokens + outputTokens
                totalCost += (usage["cost"] as? NSNumber)?.doubleValue ?? 0
            }

            if let contextPercent = (entry["context_percent"] as? NSNumber)?.doubleValue {
                latestContextPercent = contextPercent
            }
        }

        guard latestTokenCount > 0, let latestContextPercent else {
            return nil
        }

        return ChatUsageSummary(
            tokenCount: latestTokenCount,
            totalCost: totalCost,
            contextPercent: latestContextPercent
        )
    }

    nonisolated static func makeUsageRecords(
        from payload: [String: Any],
        agentAddress: String,
        remoteSessionID: String,
        fallbackModel: String?,
        now: Date = Date()
    ) -> [LLMUsageRecord] {
        guard let session = payload["session"] as? [String: Any],
              let trace = session["trace"] as? [[String: Any]] else {
            return []
        }

        var callModels: [String: String] = [:]
        var latestCallModel: String?
        var records: [LLMUsageRecord] = []

        for (index, entry) in trace.enumerated() {
            let type = entry["type"] as? String
            if type == "llm_call" {
                if let model = normalizedModel(entry["model"] as? String) {
                    latestCallModel = model
                    if let callID = usageCallID(from: entry) {
                        callModels[callID] = model
                    }
                }
                continue
            }

            guard type == "llm_result" else { continue }
            let callID = usageCallID(from: entry)
            let model = normalizedModel(entry["model"] as? String)
                ?? callID.flatMap { callModels[$0] }
                ?? latestCallModel
                ?? normalizedModel(fallbackModel)
                ?? "Unknown model"
            let stableCallID = callID ?? fallbackTraceCallID(
                entry: entry,
                index: index
            )
            records.append(
                makeUsageRecord(
                    from: entry,
                    context: ConnectOnionUsageCallContext(
                        agentAddress: agentAddress,
                        remoteSessionID: remoteSessionID,
                        callID: stableCallID,
                        model: model,
                        now: now
                    )
                )
            )
        }

        return records
    }

    nonisolated static func makeLiveUsageRecord(
        from event: [String: Any],
        agentAddress: String,
        remoteSessionID: String,
        fallbackModel: String?,
        now: Date = Date()
    ) -> LLMUsageRecord? {
        guard event["type"] as? String == "llm_result",
              let callID = usageCallID(from: event) else {
            return nil
        }
        return makeUsageRecord(
            from: event,
            context: ConnectOnionUsageCallContext(
                agentAddress: agentAddress,
                remoteSessionID: remoteSessionID,
                callID: callID,
                model: normalizedModel(event["model"] as? String)
                    ?? normalizedModel(fallbackModel)
                    ?? "Unknown model",
                now: now
            )
        )
    }

    nonisolated private static func makeUsageRecord(
        from entry: [String: Any],
        context: ConnectOnionUsageCallContext
    ) -> LLMUsageRecord {
        let usage = entry["usage"] as? [String: Any]
        let inputTokens = max(
            0,
            intValue(usage?["input_tokens"])
                ?? intValue(usage?["prompt_tokens"])
                ?? 0
        )
        let outputTokens = max(
            0,
            intValue(usage?["output_tokens"])
                ?? intValue(usage?["completion_tokens"])
                ?? 0
        )
        return LLMUsageRecord(
            id: stableUsageID(
                agentAddress: context.agentAddress,
                remoteSessionID: context.remoteSessionID,
                callID: context.callID
            ),
            timestamp: usageTimestamp(from: entry) ?? context.now,
            model: context.model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            agentAddress: context.agentAddress
        )
    }

    nonisolated static func stableUsageID(
        agentAddress: String,
        remoteSessionID: String,
        callID: String
    ) -> String {
        let material = [
            agentAddress.lowercased(),
            remoteSessionID,
            callID
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func usageCallID(
        from entry: [String: Any]
    ) -> String? {
        (entry["call_id"] as? String)
            ?? (entry["llm_call_id"] as? String)
            ?? (entry["id"] as? String)
    }

    nonisolated private static func fallbackTraceCallID(
        entry: [String: Any],
        index: Int
    ) -> String {
        let serialized: String
        if JSONSerialization.isValidJSONObject(entry),
           let data = try? JSONSerialization.data(
               withJSONObject: entry,
               options: [.sortedKeys]
           ) {
            serialized = data.base64EncodedString()
        } else {
            serialized = String(describing: entry)
        }
        let digest = SHA256.hash(data: Data(serialized.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "trace-\(index)-\(digest)"
    }

    nonisolated private static func normalizedModel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func usageTimestamp(
        from entry: [String: Any]
    ) -> Date? {
        for key in ["timestamp", "created_at", "created", "time"] {
            guard let value = entry[key] else { continue }
            if let number = doubleValue(value) {
                let seconds = number > 10_000_000_000 ? number / 1_000 : number
                return Date(timeIntervalSince1970: seconds)
            }
            if let string = value as? String {
                if let number = Double(string) {
                    let seconds = number > 10_000_000_000 ? number / 1_000 : number
                    return Date(timeIntervalSince1970: seconds)
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [
                    .withInternetDateTime,
                    .withFractionalSeconds
                ]
                if let date = formatter.date(from: string) {
                    return date
                }
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: string) {
                    return date
                }
            }
        }
        return nil
    }

    private func makeApprovalRequest(
        from event: [String: Any]
    ) -> ConnectOnionApprovalRequest {
        let batch = (event["batch_remaining"] as? [Any] ?? [])
            .map(ConnectOnionJSONValue.init(any:))
        return ConnectOnionApprovalRequest(
            id: (event["id"] as? String) ?? UUID().uuidString,
            tool: (event["tool"] as? String) ?? "unknown",
            arguments: ConnectOnionJSONValue(any: event["arguments"] ?? [:]),
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
        from event: [String: Any]
    ) -> ConnectOnionOnboardingRequest {
        ConnectOnionOnboardingRequest(
            id: (event["id"] as? String)
                ?? (event["identity"] as? String)
                ?? UUID().uuidString,
            methods: event["methods"] as? [String] ?? [],
            paymentAmount: (event["payment_amount"] as? NSNumber)?.doubleValue,
            paymentAddress: event["payment_address"] as? String
        )
    }

    private func buildConnectMessage(
        identity: ConnectOnionIdentity,
        endpoint: ConnectOnionResolvedEndpoint
    ) throws -> [String: Any] {
        let timestamp = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "timestamp": timestamp,
            "to": endpoint.agentAddress
        ]

        var message: [String: Any] = [
            "type": "CONNECT",
            "timestamp": timestamp,
            "payload": payload,
            "from": identity.address,
            "signature": try identity.signature(for: payload)
        ]

        if !endpoint.isDirect {
            message["to"] = endpoint.agentAddress
        }
        if let sessionID = sessionState.sessionID {
            message["session_id"] = sessionID
        }
        if let sessionData = sessionState.sessionData,
           let session = try? JSONSerialization.jsonObject(with: sessionData) {
            message["session"] = session
        }
        if let lastMessageID = sessionState.lastMessageID {
            message["last_msg_id"] = lastMessageID
        }
        return message
    }

    nonisolated static func buildInputMessage(
        prompt: String,
        files: [ConnectOnionInputFile],
        inputID: String,
        identity: ConnectOnionIdentity,
        endpoint: ConnectOnionResolvedEndpoint
    ) throws -> [String: Any] {
        let timestamp = Int(Date().timeIntervalSince1970)
        var payload: [String: Any] = [
            "prompt": prompt,
            "timestamp": timestamp
        ]

        var message: [String: Any] = [
            "type": "INPUT",
            "input_id": inputID,
            "prompt": prompt,
            "timestamp": timestamp
        ]
        if !files.isEmpty {
            message["files"] = files.map(\.protocolObject)
        }

        if !endpoint.isDirect {
            payload["to"] = endpoint.agentAddress
            message["to"] = endpoint.agentAddress
        }

        message["payload"] = payload
        message["from"] = identity.address
        message["signature"] = try identity.signature(for: payload)
        return message
    }

    nonisolated static func buildModeChangeMessage(
        _ mode: AgentExecutionMode
    ) -> [String: Any] {
        var message: [String: Any] = [
            "type": "mode_change",
            "mode": mode.rawValue
        ]
        if mode == .accept {
            message["turns"] = AgentExecutionMode.acceptTurns
        }
        return message
    }

    nonisolated static func buildInterruptMessage(
        inputID: String?
    ) -> [String: Any] {
        var message: [String: Any] = [
            "type": "INTERRUPT",
            "requested_at_ms": Int(Date().timeIntervalSince1970 * 1_000)
        ]
        // Naming the run we are interrupting lets the peer echo it back, so a
        // stale ack/complete for an abandoned run can be told apart from this
        // turn's own frames by identity rather than by timing alone.
        if let inputID {
            message["input_id"] = inputID
        }
        return message
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
        let message = try await withThrowingTaskGroup(
            of: URLSessionWebSocketTask.Message.self
        ) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
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

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        return object
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
        sessionState.inputWasSent = false
        // Escalation forces the run terminal; drop the flag with it so a later
        // turn is not left muted by a stale interrupt marker.
        sessionState.wasInterrupted = false
        sessionStore.save(sessionState)
        closeSocket()
    }
}

/// Async facade over the remote client, letting callers substitute a stub
/// transport for the real actor.
nonisolated protocol ConnectOnionRemoteAgentProviding: AnyObject, Sendable {
    func probe() async throws -> ConnectOnionResolvedEndpoint
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
    func disconnect() async
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

    var isRetryable: Bool {
        switch self {
        case .connectionClosed, .timedOut, .directEndpointUnavailable:
            return true
        default:
            return false
        }
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
        }
    }
}
