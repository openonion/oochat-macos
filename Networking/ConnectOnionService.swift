import Combine
import Foundation

/// Facade over the hosted-agent connection: validates 0x address and Direct URL
/// targets, delegates the protocol lifecycle to the remote-agent client, and
/// publishes connection state and failures for the UI.
@MainActor
final class ConnectOnionService: ObservableObject {
    /// Builds the client for a normalized target, conversation, and prior remote
    /// session ID; injectable through the initializer for testing.
    typealias RemoteAgentFactory = (
        String,
        UUID?,
        String?
    ) -> any ConnectOnionRemoteAgentProviding

    private let conversationID: UUID?
    private let initialRemoteSessionID: String?
    private let remoteAgentFactory: RemoteAgentFactory
    private var remoteAgentClient: (any ConnectOnionRemoteAgentProviding)?
    private var currentConfiguration: GeneralAgentConfiguration?

    /// Set optimistically once a target is accepted, before the probe completes.
    @Published var isConnected = false
    @Published var connectionError: String?
    @Published var hostedAgentStatus = "Disconnected"
    @Published var hostedAgentStatusDetail: String?
    @Published var isHostedAgentStatusLive = false
    @Published var hostedFilesystemEnabled = false
    @Published var hostedWorkspacePath: String?
    @Published var hostedFileInputCapabilities:
        ConnectOnionAgentInfo.FileInputCapabilities?
    @Published var hostedExecutionModesEnabled = false
    /// Mode the user selected; may run ahead of what the agent has confirmed.
    @Published var desiredExecutionMode: AgentExecutionMode = .safe
    /// Mode the agent last acknowledged, via snapshot or a modeChanged event.
    @Published var confirmedExecutionMode: AgentExecutionMode = .safe
    /// True while a send or recovery is in flight; messages arriving meanwhile
    /// are fed into the running request as runtime input.
    @Published var isAgentRequestActive = false
    /// Blocks duplicate stop requests until the current step finishes or fails.
    @Published var isInterruptRequested = false
    /// True when the hosted agent has not confirmed cancellation promptly and
    /// the client is closing the request as a fallback.
    @Published private(set) var isInterruptEscalating = false
    private var interruptEscalationTask: Task<Void, Never>?

    /// Single outbound stream of transport events (output, errors, approvals).
    let incomingEvents = PassthroughSubject<ConnectOnionTransportEvent, Never>()

    init(
        conversationID: UUID? = nil,
        initialRemoteSessionID: String? = nil,
        usageRecorder: (any UsageRecording)? = nil,
        remoteAgentFactory: RemoteAgentFactory? = nil
    ) {
        self.conversationID = conversationID
        self.initialRemoteSessionID = initialRemoteSessionID
        self.remoteAgentFactory = remoteAgentFactory ?? {
            ConnectOnionRemoteAgentClient(
                configuredTarget: $0,
                conversationID: $1,
                initialSessionID: $2,
                usageRecorder: usageRecorder
            )
        }
    }

    /// Routes the configuration to the address flow and fails fast on retired
    /// legacy API setups; remembers it so resends can detect configuration changes.
    func connect(with configuration: GeneralAgentConfiguration) {
        switch configuration.connectionType {
        case .byAddress:
            guard let addressConfiguration = configuration.addressConfiguration else {
                setConnectionFailure("Missing agent target configuration")
                return
            }
            connectWithAddressConfig(addressConfiguration, agentName: configuration.name)

        case .legacyByApi:
            setConnectionFailure(
                "Direct API configurations are no longer supported. Connect to a hosted ConnectOnion agent instead."
            )
        }

        if isConnected {
            currentConfiguration = configuration
        }
    }

    /// Normalizes the raw target into a 0x address or Direct URL, swaps in a
    /// fresh client, and probes it in the background; probe results from a
    /// client that has since been replaced are dropped.
    func connectWithAddressConfig(_ configuration: AgentAddressConfiguration, agentName _: String) {
        let target = configuration.agentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedTarget = ConnectOnionAgentTarget.normalized(target) else {
            setConnectionFailure(
                "Enter a valid ConnectOnion 0x address or HTTP(S) Direct URL"
            )
            return
        }

        stopRemoteAgent()

        let client = remoteAgentFactory(
            normalizedTarget,
            conversationID,
            initialRemoteSessionID
        )
        remoteAgentClient = client
        hostedAgentStatus = "Resolving"
        hostedAgentStatusDetail = nil
        isHostedAgentStatusLive = false
        hostedFilesystemEnabled = false
        hostedWorkspacePath = nil
        hostedFileInputCapabilities = nil
        hostedExecutionModesEnabled = true
        desiredExecutionMode = .safe
        confirmedExecutionMode = .safe
        connectionError = nil
        isConnected = true

        Task { [weak self, client] in
            do {
                let endpoint = try await client.probe()
                guard let self, self.remoteAgentClient === client else { return }
                self.hostedAgentStatus = "Connected"
                self.hostedAgentStatusDetail = endpoint.isDirect
                    ? "Direct endpoint"
                    : "ConnectOnion relay"
                self.isHostedAgentStatusLive = true
                self.hostedFilesystemEnabled = endpoint.info?.tools?.contains(where: {
                    ["read_file", "glob", "grep", "write", "edit", "multi_edit"].contains($0)
                }) ?? false
                self.hostedFileInputCapabilities = endpoint.info?
                    .acceptedInputs?
                    .files
                self.hostedExecutionModesEnabled = true
                let modes = await client.executionModeSnapshot()
                self.desiredExecutionMode = modes.desired
                self.confirmedExecutionMode = modes.confirmed
                // Resume an execution left over from a previous session.
                if await client.hasPendingExecution() {
                    self.isAgentRequestActive = true
                    self.isInterruptRequested = false
                    await client.recoverIfNeeded(
                        onUpdate: { [weak self] update in
                            self?.apply(update)
                        },
                        onEvent: { [weak self] event in
                            self?.emit(event)
                        }
                    )
                    self.isAgentRequestActive = false
                    self.isInterruptRequested = false
                }
            } catch {
                guard let self, self.remoteAgentClient === client else { return }
                self.hostedAgentStatus = "Offline"
                self.hostedAgentStatusDetail = error.localizedDescription
                self.isHostedAgentStatusLive = false
            }
        }
    }

    func disconnect() {
        stopRemoteAgent()
        hostedAgentStatus = "Disconnected"
        hostedAgentStatusDetail = nil
        isHostedAgentStatusLive = false
        hostedFilesystemEnabled = false
        hostedWorkspacePath = nil
        hostedFileInputCapabilities = nil
        hostedExecutionModesEnabled = false
        desiredExecutionMode = .safe
        confirmedExecutionMode = .safe
        isAgentRequestActive = false
        isInterruptRequested = false
        currentConfiguration = nil
        connectionError = nil
        isConnected = false
    }

    static func validatedHTTPURL(from value: String) -> URL? {
        ConnectOnionAgentTarget.directURL(from: value)
    }

    /// Sends a prompt with optional files, reconnecting first when the client is
    /// missing or the configuration changed since the last successful connect.
    func sendMessage(
        _ message: String,
        files: [ConnectOnionInputFile] = [],
        localMessageID: UUID,
        using configuration: GeneralAgentConfiguration
    ) async {
        guard configuration.connectionType == .byAddress else {
            let message =
                "Direct API configurations are no longer supported. Connect to a hosted ConnectOnion agent instead."
            setConnectionFailure(message)
            incomingEvents.send(.error(message))
            return
        }

        if remoteAgentClient == nil || currentConfiguration != configuration {
            connect(with: configuration)
        }

        guard isConnected else {
            incomingEvents.send(.error(connectionError ?? "Not connected"))
            return
        }

        do {
            guard let remoteAgentClient else {
                throw ConnectOnionServiceError.notConnected
            }
            if isAgentRequestActive {
                try await remoteAgentClient.sendRuntimeInput(
                    prompt: message,
                    files: files,
                    localMessageID: localMessageID
                )
                return
            }
            isAgentRequestActive = true
            isInterruptRequested = false
            defer {
                isAgentRequestActive = false
                isInterruptRequested = false
                isInterruptEscalating = false
                interruptEscalationTask?.cancel()
                interruptEscalationTask = nil
            }
            let response = try await remoteAgentClient.send(
                prompt: message,
                files: files,
                onUpdate: { [weak self] update in
                    self?.apply(update)
                },
                onEvent: { [weak self] event in
                    guard let self, !self.isInterruptRequested else { return }
                    self.emit(event)
                }
            )
            // A peer may finish just after it receives INTERRUPT. Never let
            // that stale final result escape into a later chat turn.
            guard !isInterruptRequested else { return }
            incomingEvents.send(.output(response))

            connectionError = nil
        } catch ConnectOnionRemoteError.interrupted {
            hostedAgentStatus = "Connected"
            hostedAgentStatusDetail = "Stopped by user"
            isHostedAgentStatusLive = true
            connectionError = nil
            incomingEvents.send(.interrupted)
        } catch {
            connectionError = error.localizedDescription
            if configuration.connectionType == .byAddress {
                hostedAgentStatus = "Connection error"
                hostedAgentStatusDetail = error.localizedDescription
                isHostedAgentStatusLive = false
            }
            incomingEvents.send(.error(error.localizedDescription))
        }
    }

    /// Asks the agent to stop after it finishes the current step; returns false
    /// when nothing is running or the stop request itself failed.
    func interruptCurrentRequest() async -> Bool {
        guard isAgentRequestActive, !isInterruptRequested else { return false }

        do {
            guard let remoteAgentClient else {
                throw ConnectOnionServiceError.notConnected
            }
            isInterruptRequested = true
            isInterruptEscalating = false
            scheduleInterruptEscalationFeedback()
            hostedAgentStatus = "Stopping"
            hostedAgentStatusDetail = "Finishing the current step"
            try await remoteAgentClient.interrupt()
            return true
        } catch {
            isInterruptRequested = false
            isInterruptEscalating = false
            interruptEscalationTask?.cancel()
            interruptEscalationTask = nil
            hostedAgentStatus = "Running"
            hostedAgentStatusDetail = error.localizedDescription
            return false
        }
    }

    func respondToAskUser(_ answer: String) async {
        do {
            guard let remoteAgentClient else {
                throw ConnectOnionServiceError.notConnected
            }
            try await remoteAgentClient.respondToAskUser(answer: answer)
        } catch {
            incomingEvents.send(.error(error.localizedDescription))
        }
    }

    func respondToApproval(_ decision: ConnectOnionApprovalDecision) async {
        do {
            guard let remoteAgentClient else {
                throw ConnectOnionServiceError.notConnected
            }
            try await remoteAgentClient.respondToApproval(decision)
        } catch {
            incomingEvents.send(.error(error.localizedDescription))
        }
    }

    /// Applies the mode optimistically and reverts when the agent rejects the
    /// switch; a no-op until execution modes are enabled.
    func setExecutionMode(_ mode: AgentExecutionMode) async {
        guard hostedExecutionModesEnabled else { return }
        let previous = desiredExecutionMode
        desiredExecutionMode = mode
        do {
            guard let remoteAgentClient else {
                throw ConnectOnionServiceError.notConnected
            }
            try await remoteAgentClient.setExecutionMode(mode)
        } catch {
            desiredExecutionMode = previous
            incomingEvents.send(.error(error.localizedDescription))
        }
    }

    func respondToPlanReview(_ decision: ConnectOnionPlanReviewDecision) async {
        do {
            guard let remoteAgentClient else {
                throw ConnectOnionServiceError.notConnected
            }
            try await remoteAgentClient.respondToPlanReview(decision)
        } catch {
            incomingEvents.send(.error(error.localizedDescription))
        }
    }

    func respondToULWCheckpoint(
        _ decision: ConnectOnionULWCheckpointDecision
    ) async {
        do {
            guard let remoteAgentClient else {
                throw ConnectOnionServiceError.notConnected
            }
            try await remoteAgentClient.respondToULWCheckpoint(decision)
        } catch {
            incomingEvents.send(.error(error.localizedDescription))
        }
    }

    func submitInviteCode(_ code: String) async {
        do {
            guard let remoteAgentClient else {
                throw ConnectOnionServiceError.notConnected
            }
            try await remoteAgentClient.submitInviteCode(code)
        } catch {
            incomingEvents.send(.error(error.localizedDescription))
        }
    }

    /// Re-attaches to a hosted session that still has work pending; refuses when
    /// a request is already active or nothing is waiting to be recovered.
    func retryRecovery() async {
        guard !isAgentRequestActive else { return }
        do {
            guard let remoteAgentClient,
                  await remoteAgentClient.hasPendingExecution() else {
                throw ConnectOnionServiceError.noPendingRecovery
            }
            isAgentRequestActive = true
            isInterruptRequested = false
            defer {
                isAgentRequestActive = false
                isInterruptRequested = false
            }
            await remoteAgentClient.recoverIfNeeded(
                onUpdate: { [weak self] update in
                    self?.apply(update)
                },
                onEvent: { [weak self] event in
                    self?.emit(event)
                }
            )
        } catch {
            incomingEvents.send(.error(error.localizedDescription))
        }
    }

    private func apply(_ update: ConnectOnionTransportUpdate) {
        hostedAgentStatus = update.status
        hostedAgentStatusDetail = update.detail
        isHostedAgentStatusLive = update.isLive
    }

    /// Forwards transport events to the UI, mirroring mode changes and, while in
    /// accept mode, answering approval requests without surfacing them.
    private func emit(_ event: ConnectOnionTransportEvent) {
        if case .modeChanged(let mode) = event {
            desiredExecutionMode = mode
            confirmedExecutionMode = mode
        }
        if case .approvalRequired = event,
           desiredExecutionMode == .accept {
            Task { [weak self] in
                await self?.respondToApproval(.approveOnce)
            }
            return
        }
        incomingEvents.send(event)
    }

    private func scheduleInterruptEscalationFeedback() {
        interruptEscalationTask?.cancel()
        interruptEscalationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard let self, self.isInterruptRequested else { return }
            self.isInterruptEscalating = true
            self.hostedAgentStatus = "Force stopping"
            self.hostedAgentStatusDetail = "Closing an unresponsive request"
        }
    }

    private func stopRemoteAgent() {
        let client = remoteAgentClient
        remoteAgentClient = nil
        if let client {
            Task {
                await client.disconnect()
            }
        }
    }

    private func setConnectionFailure(_ message: String) {
        stopRemoteAgent()
        hostedAgentStatus = "Disconnected"
        hostedAgentStatusDetail = nil
        isHostedAgentStatusLive = false
        hostedFilesystemEnabled = false
        hostedWorkspacePath = nil
        hostedFileInputCapabilities = nil
        hostedExecutionModesEnabled = false
        desiredExecutionMode = .safe
        confirmedExecutionMode = .safe
        isAgentRequestActive = false
        isInterruptRequested = false
        currentConfiguration = nil
        connectionError = message
        isConnected = false
    }

    private enum ConnectOnionServiceError: LocalizedError {
        case notConnected
        case noPendingRecovery

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected"
            case .noPendingRecovery:
                return "There is no hosted session waiting to be recovered"
            }
        }
    }
}
