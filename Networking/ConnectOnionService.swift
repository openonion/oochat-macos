import Combine
import Foundation
import ConnectOnionKit

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
    /// The viewer gate: only a device that shares its Identity has another device's turns to watch.
    private let isLinked: () -> Bool
    private var remoteAgentClient: (any ConnectOnionRemoteAgentProviding)?
    private var currentConfiguration: GeneralAgentConfiguration?

    /// Set optimistically once a target is accepted, before the probe completes.
    @Published var isConnected = false
    @Published var connectionError: String?
    @Published var hostedAgentStatus = ConnectOnionService.notConnected
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
    /// Modes that the host listed in CONNECTED. Empty until one arrives, so accept stays hidden.
    @Published var availableExecutionModes: [AgentExecutionMode] = []
    /// Turns left in accept mode, from mode_changed or CONNECTED; nil in other modes
    @Published var acceptTurnsLeft: Int?
    /// True while a send or recovery is in flight; messages arriving meanwhile
    /// are fed into the running request as runtime input.
    @Published var isAgentRequestActive = false
    /// The active turn was typed on another device; this one may only watch, stop or approve.
    @Published private(set) var isMirroredTurn = false
    private var isObserving = false
    /// Changes whenever the hosted agent client is replaced or dropped, so a held Work Room connection
    /// follows the client it was opened for.
    @Published private(set) var connectionGeneration = 0
    /// Blocks duplicate stop requests until the current step finishes or fails.
    @Published var isInterruptRequested = false
    /// True when the hosted agent has not confirmed cancellation promptly and
    /// the client is closing the request as a fallback.
    @Published private(set) var isInterruptEscalating = false
    private var interruptEscalationTask: Task<Void, Never>?
    private var linkEvents: Set<AnyCancellable> = []

    /// Session words come from the CO package so both apps say the same thing
    static let notConnected = SessionStatusLabel.text(
        state: .idle,
        hasBookmark: false,
        hostStatus: nil
    )
    /// Single outbound stream of transport events (output, errors, approvals).
    /// Set by the chat: whether the Work Room owns this `approval_needed` body.
    var ownsProviderApproval: (([String: JSONValue]) -> Bool)?
    /// Set by the chat: takes Work Room events (frames, snapshot, transport, drop) the moment they arrive, in
    /// order, instead of through `incomingEvents`. The store is then current when the next `approval_needed` is
    /// checked against it.
    var onWorkRoomEvent: ((ConnectOnionTransportEvent) -> Void)?
    private var isProviderApprovalOwned = false
    let incomingEvents = PassthroughSubject<ConnectOnionTransportEvent, Never>()

    init(
        conversationID: UUID? = nil,
        initialRemoteSessionID: String? = nil,
        usageRecorder: (any UsageRecording)? = nil,
        isLinked: @escaping () -> Bool = { ConnectOnionIdentityStore.shared.isLinked },
        linkNotifications: NotificationCenter = .default,
        remoteAgentFactory: RemoteAgentFactory? = nil
    ) {
        self.conversationID = conversationID
        self.initialRemoteSessionID = initialRemoteSessionID
        self.isLinked = isLinked
        self.remoteAgentFactory = remoteAgentFactory ?? {
            ConnectOnionRemoteAgentClient(
                configuredTarget: $0,
                conversationID: $1,
                initialSessionID: $2,
                usageRecorder: usageRecorder
            )
        }
        linkNotifications.publisher(for: Self.identityDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.disconnect() }
            }
            .store(in: &linkEvents)
        linkNotifications.publisher(for: Self.didLinkNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.startViewer() }
            }
            .store(in: &linkEvents)
    }

    private static let identityDidChangeNotification = Notification.Name("ConnectOnionService.identityDidChange")
    private static let didLinkNotification = Notification.Name("ConnectOnionService.didLink")

    /// Call after a Device Link replaced the private key. Every existing chat now belongs to the old
    /// Address and is read-only, so each live service closes its connection; new chats connect as the new one.
    static func identityDidChange(in notifications: NotificationCenter = .default) {
        notifications.post(name: identityDidChangeNotification, object: nil)
    }

    /// Call after this device gave its Identity away. Its Address is unchanged, so connections stay;
    /// each open chat starts the viewer the linked flag now allows.
    static func didLink(in notifications: NotificationCenter = .default) {
        notifications.post(name: didLinkNotification, object: nil)
    }

    private func startViewer() {
        guard isConnected, remoteAgentClient != nil else { return }
        Task { await observe() }
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
                "Direct API configurations are no longer supported. Connect to a hosted agent instead."
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
                "Enter a valid 0x address or HTTP(S) Direct URL"
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
        connectionGeneration += 1
        hostedAgentStatus = SessionStatusLabel.text(
            state:
                .connecting(attempt: 0),
                hasBookmark: false,
                hostStatus: nil
        )
        hostedAgentStatusDetail = nil
        isHostedAgentStatusLive = false
        hostedFilesystemEnabled = false
        hostedWorkspacePath = nil
        hostedFileInputCapabilities = nil
        hostedExecutionModesEnabled = true
        desiredExecutionMode = .safe
        confirmedExecutionMode = .safe
        availableExecutionModes = []
        acceptTurnsLeft = nil
        connectionError = nil
        isConnected = true

        Task { [weak self, client] in
            do {
                let endpoint = try await client.probe()
                guard let self, self.remoteAgentClient === client else { return }
                self.hostedAgentStatus = "Connected"
                self.hostedAgentStatusDetail = endpoint.isDirect
                    ? "Direct endpoint"
                    : "Relay"
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
                        onUpdate: { @MainActor [weak self] update in
                            self?.apply(update)
                        },
                        onEvent: { @MainActor [weak self] event in
                            self?.emit(event)
                        }
                    )
                    self.isAgentRequestActive = false
                    self.isInterruptRequested = false
                } else {
                    // Fetch the authenticated profile without sending INPUT.
                    // This is best-effort: failure must not mark the agent offline.
                    do {
                        try await client.loadAgentProfile(
                            onEvent: { @MainActor [weak self] event in
                                guard let self,
                                      self.remoteAgentClient === client else {
                                    return
                                }
                                // Carries the catch-up on open, so it applies as the viewer's would.
                                self.handleViewerEvent(event)
                            }
                        )
                    } catch {
                        // Keep using the public agent information if this fails.
                    }
                }
                if self.remoteAgentClient === client {
                    await self.observe()
                }
            } catch {
                guard let self, self.remoteAgentClient === client else { return }
                self.hostedAgentStatus = "Offline"
                self.hostedAgentStatusDetail = error.localizedDescription
                self.isHostedAgentStatusLive = false
            }
        }
    }

    /// Keeps a connection open for an open Work Room while no turn is running, so Provider Input can be
    /// sent between turns. A connection that fails or drops is opened again, waiting 1 s and doubling up to
    /// 30 s. Returns when a turn starts, the client is replaced, the user has to act (onboarding), or the
    /// calling task is cancelled.
    func holdWorkRoomConnection(
        stationSessionID: String? = nil, inviteCode: String? = nil, handlesOnboarding: Bool = false
    ) async {
        var delay: Duration = .seconds(1)
        while !Task.isCancelled, !isAgentRequestActive, let client = remoteAgentClient {
            let shouldRetry = await client.holdWorkRoomConnection(
                stationSessionID: stationSessionID, inviteCode: inviteCode, handlesOnboarding: handlesOnboarding
            ) { [weak self] event in
                guard let self, self.remoteAgentClient === client else { return }
                self.emit(event)
            }
            guard shouldRetry, remoteAgentClient === client else { return }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
    }

    func disconnect() {
        stopRemoteAgent()
        hostedAgentStatus = Self.notConnected
        hostedAgentStatusDetail = nil
        isHostedAgentStatusLive = false
        hostedFilesystemEnabled = false
        hostedWorkspacePath = nil
        hostedFileInputCapabilities = nil
        hostedExecutionModesEnabled = false
        desiredExecutionMode = .safe
        confirmedExecutionMode = .safe
        availableExecutionModes = []
        acceptTurnsLeft = nil
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
                "Direct API configurations are no longer supported. Connect to a hosted agent instead."
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

        // Another device owns this turn: never inject input into it.
        guard !isMirroredTurn else { return }

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
                Task { [weak self] in await self?.observe() }
            }
            let response = try await remoteAgentClient.send(
                prompt: message,
                files: files,
                onUpdate: { @MainActor [weak self] update in
                    self?.apply(update)
                },
                onEvent: { @MainActor [weak self] event in
                    guard let self, !self.isInterruptRequested else { return }
                    self.emit(event)
                }
            )
            // A peer may finish just after it receives INTERRUPT. Never let
            // that stale final result escape into a later chat turn.
            guard !isInterruptRequested else { return }
            incomingEvents.send(.output(response))

            connectionError = nil
        } catch ConnectOnionRemoteError.stationOnly {
            connectionError = nil
            incomingEvents.send(.stationRefusedChat)
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
            // -32010 gets its own screen. Every other failure keeps the old error event.
            if let incompatibility = (error as? ConnectOnionRemoteError)?.incompatibility {
                incomingEvents.send(.incompatible(incompatibility))
            } else {
                incomingEvents.send(.error(error.localizedDescription))
            }
        }
    }

    /// Watches this chat's host session so a turn typed on another device shows here: while it
    /// streams the request is active (Replying, Send off, Stop on), and the next one is awaited.
    /// Only on a linked device: an unlinked one has no other device to watch, so it holds no viewer.
    func observe() async {
        guard !isObserving, isLinked() else { return }
        isObserving = true
        defer { isObserving = false }
        while let client = remoteAgentClient, !isAgentRequestActive {
            let ending = await client.observe(
                onUpdate: { [weak self] in self?.apply($0) },
                onEvent: { [weak self] in self?.handleViewerEvent($0) }
            )
            // A local send closes the viewer socket and owns the flags from then on.
            applyViewer(.viewerEnded)
            guard ending == .turnFinished else { return }
            // A host that ends a viewer straight away (a replayed result, an instant interrupt) would
            // otherwise spin reconnects; a turn started meanwhile still arrives as the next catch-up.
            guard (try? await Task.sleep(nanoseconds: 1_000_000_000)) != nil else { return }
        }
    }

    private func handleViewerEvent(_ event: ConnectOnionTransportEvent) {
        switch event {
        case .mirroredUserMessage:
            applyViewer(.userMessage)
            // The state refused it: a local send owns the transcript.
            if isAgentRequestActive, !isMirroredTurn { return }
        case .catchUp(_, let isRunning):
            applyViewer(.catchUp(isRunning: isRunning))
            if isAgentRequestActive, !isMirroredTurn { return }
        case .output, .interrupted, .error:
            applyViewer(.finished)
            isInterruptRequested = false
        default:
            break
        }
        emit(event)
    }

    /// Runs one viewer event through the Kit's turn state, so macOS and iOS lock the same way.
    private func applyViewer(_ event: ViewerTurnState.Event) {
        var state = ViewerTurnState(isActive: isAgentRequestActive, isMirrored: isMirroredTurn)
        state.apply(event)
        isAgentRequestActive = state.isActive
        isMirroredTurn = state.isMirrored
    }

    /// Cuts the agent's saved session back to before your latest message, so the next send
    /// redoes that turn. False while a run is going or when there is nothing to rewind.
    func rewindLatestTurn(prompt: String) async -> Bool {
        guard !isAgentRequestActive, let remoteAgentClient else {
            return false
        }
        return await remoteAgentClient.rewindLatestTurn(prompt: prompt)
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
                onUpdate: { @MainActor [weak self] update in
                    self?.apply(update)
                },
                onEvent: { @MainActor [weak self] event in
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
        // The Work Room answers a Provider approval; its hosted prompt (and accept mode's auto-answer) is skipped.
        if case .workRoomFrame(.event(type: "approval_needed", _, let body)) = event {
            isProviderApprovalOwned = ownsProviderApproval?(body) ?? false
        }
        if case .approvalRequired = event, isProviderApprovalOwned {
            isProviderApprovalOwned = false
            return
        }
        if event.isWorkRoomEvent, let onWorkRoomEvent {
            onWorkRoomEvent(event)
            return
        }
        if case .modeChanged(let mode, let turnsLeft) = event {
            desiredExecutionMode = mode
            confirmedExecutionMode = mode
            acceptTurnsLeft = mode == .accept ? turnsLeft : nil
        }
        if case .sessionModes(let available, let current, let turnsLeft) = event {
            availableExecutionModes = available
            if let current {
                confirmedExecutionMode = current
            }
            acceptTurnsLeft = current == .accept ? turnsLeft : nil
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
        connectionGeneration += 1
        // The old client's events are ignored from here on, so the store is told directly.
        emit(.workRoomConnectionDropped)
        if let client {
            Task {
                await client.disconnect()
            }
        }
    }

    private func setConnectionFailure(_ message: String) {
        stopRemoteAgent()
        hostedAgentStatus = Self.notConnected
        hostedAgentStatusDetail = nil
        isHostedAgentStatusLive = false
        hostedFilesystemEnabled = false
        hostedWorkspacePath = nil
        hostedFileInputCapabilities = nil
        hostedExecutionModesEnabled = false
        desiredExecutionMode = .safe
        confirmedExecutionMode = .safe
        availableExecutionModes = []
        acceptTurnsLeft = nil
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
