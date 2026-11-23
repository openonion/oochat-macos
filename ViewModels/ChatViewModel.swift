import Foundation
import Combine
import UniformTypeIdentifiers
import ConnectOnionKit

/// Drives a single conversation: transcript, composer, attachments, voice
/// input, and runtime interactions, all mirrored into the shared AppViewModel
/// store so the state outlives this view model.
@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var executionItems: [ExecutionItem] = []
    @Published var executionRuns: [ExecutionRun] = []
    @Published var inputText: String = "" {
        didSet { appViewModel.setDraft(inputText, for: session.id) }
    }
    @Published var pendingAttachments: [ConnectOnionInputFile] = []
    @Published var attachmentError: String?
    /// Runtime question or approval awaiting the user's answer; sending and
    /// attaching stay disabled until it resolves.
    @Published var pendingInteraction: ConnectOnionPendingInteraction? {
        didSet { reportActivity() }
    }
    @Published var interactionError: String?
    /// Why each failed message didn't go through. Kept for this run of the app only.
    @Published var failureByMessageID: [UUID: ChatFailure] = [:]
    @Published var recoveryStatus: String?
    @Published var incompatibility: OIPHandshake.Incompatibility?
    /// The newest DASHBOARD_SNAPSHOT for this chat - adds the session checks.
    @Published var dashboard: OIPDashboard?
    @Published var isSubmittingInteraction = false
    /// True from a Retry or Edit click until its send has started, so a second click can't rewind twice.
    @Published private(set) var isRedoing = false
    @Published private(set) var latestUsage: ChatUsageSummary?
    @Published private(set) var agentProfile: OIPAgentProfile?
    /// Set after an interrupt so every trailing event from that cancelled run
    /// is discarded instead of reaching the transcript.
    @Published private(set) var isDiscardingInterruptedEvents = false
    /// This conversation's Work Rooms, fed every decoded provider frame.
    let workRooms: WorkRoomStore
    /// The pairing code a Station pane sends as the invite code when the host asks for onboarding. The attempt
    /// count changes on every entry, so the pane's connection restarts even for the same code.
    /// Set in `ChatViewModel+WorkRoom.swift`.
    @Published var stationInviteCode: String?
    @Published var stationOnboardingAttempt = 0

    let session: ChatSession
    private let initialConfiguration: GeneralAgentConfiguration
    /// Re-resolved from the app store on every read so agent edits made
    /// elsewhere take effect mid-session.
    var configuration: GeneralAgentConfiguration {
        appViewModel.configurations.first { $0.id == initialConfiguration.id }
            ?? initialConfiguration
    }
    let service: ConnectOnionService
    let appViewModel: AppViewModel
    let voiceInputService: VoiceInputService
    /// The Work Room whose composer started the current dictation. The one voice service serves
    /// the main composer and the Work Room composer, so only one of them can use it at a time.
    @Published var dictatingRoomID: String?
    /// The microphone guidance for the last failed dictation, shown in that Work Room's composer.
    @Published var dictationGuidance: String?

    private var messageTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingUsage: ChatUsageSummary?
    private var pendingArtifacts: [GeneratedArtifactReference] = []
    private var pendingArtifactWarnings: [String] = []
    private var textBeforeVoiceInput = ""
    private var activeExecutionRunID: UUID? {
        didSet { reportActivity() }
    }

    init(session: ChatSession, configuration: GeneralAgentConfiguration, service: ConnectOnionService, appViewModel: AppViewModel,
         voiceInputService: VoiceInputService? = nil) {
        self.voiceInputService = voiceInputService ?? VoiceInputService()
        self.session = session
        self.initialConfiguration = configuration
        self.service = service
        self.appViewModel = appViewModel
        workRooms = appViewModel.workRoomStore(for: session.id)
        service.ownsProviderApproval = { [workRooms] in workRooms.ownsApproval($0) }
        service.onWorkRoomEvent = { [weak self] in self?.handleIncomingEvent($0) }

        messages = appViewModel.findMessages(for: session.id)
        executionItems = appViewModel.findExecutionItems(for: session.id)
        executionRuns = appViewModel.findExecutionRuns(for: session.id)
        latestUsage = messages.reversed().compactMap(\.usage).first
        // Reopen the chat with whatever was left unsent.
        inputText = appViewModel.draft(for: session.id)

        setupBindings()
    }

    deinit {
        messageTask?.cancel()
        statusTask?.cancel()
    }

    /// Tells the sidebar whether this chat is waiting on you or working.
    /// `isRequestActive`: the service's new value, when it's what changed (a @Published sink
    /// runs before the property updates).
    private func reportActivity(isRequestActive: Bool? = nil) {
        let status: SidebarChatStatus?
        switch pendingInteraction {
        case .approval:
            status = .approval
        // A question, an invite code, a plan or a checkpoint: yours to answer, not to approve.
        case .askUser, .onboarding, .planReview, .ulwCheckpoint:
            status = .reply
        case nil:
            // Working only while a request is in flight. A late trace event after the reply opens
            // a run that nothing closes, and must not leave the row saying Working.
            let isActive = isRequestActive ?? service.isAgentRequestActive
            status = activeExecutionRunID != nil && isActive ? .working : nil
        }
        appViewModel.setLiveActivity(status, for: session.id)
    }

    private func setupBindings() {
        // dropFirst: the view model is made while the window draws; nothing has changed yet.
        service.$isAgentRequestActive
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isActive in
                self?.reportActivity(isRequestActive: isActive)
            }
            .store(in: &cancellables)

        service.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // A chat that reaches its agent counts it as online (sidebar dot, count, skill cards).
        // Only ever "online": going offline stays with the background check.
        service.$isHostedAgentStatusLive
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, self.configuration.connectionType == .byAddress else { return }
                self.appViewModel.setAgentConnected(self.configuration, isConnected: true)
            }
            .store(in: &cancellables)

        appViewModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        appViewModel.$messages
            .sink { [weak self] allMessages in
                guard let self else { return }
                let sessionMessages = allMessages.filter {
                    $0.sessionId == self.session.id
                }
                guard sessionMessages != self.messages else { return }
                self.messages = sessionMessages
                self.latestUsage = sessionMessages.reversed()
                    .compactMap(\.usage)
                    .first
            }
            .store(in: &cancellables)

        voiceInputService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        voiceInputService.$transcript
            .sink { [weak self] transcript in
                guard let self, !transcript.isEmpty else { return }
                if let roomID = self.dictatingRoomID {
                    self.workRooms.appendDictation(transcript, in: roomID)
                    return
                }
                let prefix = self.textBeforeVoiceInput
                self.inputText = prefix.isEmpty ? transcript : "\(prefix) \(transcript)"
            }
            .store(in: &cancellables)

        // A failed Work Room dictation shows its guidance there; a finished one frees the mic.
        voiceInputService.$errorMessage
            .sink { [weak self] message in
                guard let self, let message, self.dictatingRoomID != nil else { return }
                self.dictationGuidance = message
                self.dictatingRoomID = nil
            }
            .store(in: &cancellables)

        voiceInputService.$isTranscribing
            .removeDuplicates()
            .sink { [weak self] isTranscribing in
                if !isTranscribing { self?.dictatingRoomID = nil }
            }
            .store(in: &cancellables)

        // `.values` on a PassthroughSubject keeps no buffer, so an event sent while the previous one is still being
        // handled would be lost. The stream keeps every event, in order, until it is handled.
        let (events, continuation) = AsyncStream.makeStream(of: ConnectOnionTransportEvent.self)
        service.incomingEvents
            .sink { continuation.yield($0) }
            .store(in: &cancellables)
        messageTask = Task { [weak self] in
            for await event in events {
                if Task.isCancelled { break }
                guard let self else { break }
                self.handleIncomingEvent(event)
            }
        }
    }

    func handleIncomingEvent(_ event: ConnectOnionTransportEvent) {
        // Revision-gated Work Room state, not transcript output: a Provider's
        // terminal update must still land while an interrupted run is discarded.
        if event.isWorkRoomEvent {
            handleWorkRoomEvent(event)
            return
        }
        if isDiscardingInterruptedEvents {
            return
        }

        switch event {
        case .output(let text):
            if let pendingUsage {
                latestUsage = pendingUsage
                self.pendingUsage = nil
            }
            let replyToMessageID = activeRequestMessageID
            finishActiveExecutionRun(with: .done)
            pendingInteraction = nil
            interactionError = nil
            recoveryStatus = nil
            markOutstandingMessages(as: .sent)
            if configuration.connectionType == .byAddress {
                appViewModel.setAgentConnected(configuration, isConnected: true)
            }
            appendAgentMessage(
                text,
                usage: latestUsage,
                replyToMessageID: replyToMessageID,
                artifacts: consumePendingArtifacts(),
                artifactWarnings: consumePendingArtifactWarnings()
            )

        case .usage(let usage):
            pendingUsage = usage

        case .agentProfile(let profile):
            agentProfile = profile
            if profile.isClaudeStation {
                appViewModel.markClaudeStation(initialConfiguration.id)
            }

        case .executionItem(let item):
            upsertExecutionItem(item)

        case .agentImage(let url):
            appendAgentImage(url, replyToMessageID: activeRequestMessageID)

        case .agentArtifact(let payload):
            let artifactID = payload.reference.artifactID
            let isKnown = pendingArtifacts.contains { $0.artifactID == artifactID }
                || messages.contains {
                    $0.artifacts?.contains {
                        $0.artifactID == artifactID
                    } == true
                }
            guard !isKnown else { return }
            guard pendingArtifacts.count < 10,
                  pendingArtifacts.reduce(0, {
                      $0 + $1.sizeBytes
                  }) + payload.reference.sizeBytes
                    <= GeneratedArtifactStore.maximumPayloadBytes else {
                pendingArtifactWarnings.append(
                    "Generated files exceeded the 10-file or 8 MB response limit."
                )
                return
            }
            do {
                let reference = try appViewModel.generatedArtifactStore.record(
                    payload
                )
                pendingArtifacts.append(reference)
            } catch {
                pendingArtifactWarnings.append(
                    "\(payload.reference.name): \(error.localizedDescription)"
                )
            }

        case .artifactTransferFailed(let message):
            pendingArtifactWarnings.append(message)

        case .runtimeInputAcknowledged(let localMessageID):
            updateMessageStatus(localMessageID, to: .queued)

        case .askUser(let request):
            pendingInteraction = .askUser(request)
            interactionError = nil

        case .approvalRequired(let request):
            pendingInteraction = .approval(request)
            interactionError = nil

        case .onboardingRequired(let request):
            pendingInteraction = .onboarding(request)
            interactionError = nil

        case .onboardingSucceeded:
            pendingInteraction = nil
            interactionError = nil

        case .modeChanged:
            interactionError = nil

        case .sessionModes:
            break

        case .planReviewRequired(let request):
            pendingInteraction = .planReview(request)
            interactionError = nil

        case .ulwCheckpointRequired(let request):
            pendingInteraction = .ulwCheckpoint(request)
            interactionError = nil

        case .recoveryState(let status):
            recoveryStatus = status

        case .interrupted:
            pendingUsage = nil
            pendingArtifacts = []
            pendingArtifactWarnings = []
            pendingInteraction = nil
            interactionError = nil
            recoveryStatus = nil
            finishActiveExecutionRun(with: .done)
            markOutstandingMessages(as: .sent)

        case .mirroredUserMessage(let text):
            appendMirroredUserMessage(text)

        case .catchUp(let items, let isRunning):
            catchUp(with: items, isRunning: isRunning)

        case .dashboard(let dashboard):
            // The host resends the page on every connect and reattach; an equal one changes nothing.
            if self.dashboard != dashboard {
                self.dashboard = dashboard
            }

        case .workRoomFrame, .workRoomSnapshot, .workRoomTransport, .workRoomConnectionDropped:
            break  // Fed to the Work Room store above.

        case .stationRefusedChat:
            // The host is a Station: the message was never a chat turn, so no failure reason is shown.
            pendingUsage = nil
            isSubmittingInteraction = false
            finishActiveExecutionRun(with: .error)
            markOutstandingMessages(as: .error)

        case .incompatible(let incompatibility):
            pendingUsage = nil
            isSubmittingInteraction = false
            pendingInteraction = nil
            let replyToMessageID = activeRequestMessageID
            finishActiveExecutionRun(with: .error)
            markOutstandingMessages(as: .error)
            if configuration.connectionType == .byAddress {
                appViewModel.setAgentConnected(configuration, isConnected: false)
            }
            self.incompatibility = incompatibility
            appendAgentMessage(
                incompatibility.message,
                replyToMessageID: replyToMessageID,
                artifacts: consumePendingArtifacts(),
                artifactWarnings: consumePendingArtifactWarnings()
            )

        case .error(let message):
            pendingUsage = nil
            isSubmittingInteraction = false
            interactionError = message
            let replyToMessageID = activeRequestMessageID
            finishActiveExecutionRun(with: .error)
            let failedIDs = outstandingMessageIDs
            // The host is asking for onboarding; the error belongs to that prompt, not to a failed chat.
            if case .onboarding? = pendingInteraction { return }
            markOutstandingMessages(as: .error)
            if configuration.connectionType == .byAddress {
                appViewModel.setAgentConnected(configuration, isConnected: false)
            }
            // The reason goes on the message that failed, not in an agent reply.
            let failure = ConnectOnionRemoteError.chatFailure(forDescription: message)
            if failedIDs.isEmpty {
                appendSystemNotice(failure.sentence(agentName: configuration.name))
            } else {
                for id in failedIDs {
                    failureByMessageID[id] = failure
                }
            }
            // Files the agent made before failing still belong in the chat.
            let artifacts = consumePendingArtifacts()
            let warnings = consumePendingArtifactWarnings()
            if !artifacts.isEmpty || !warnings.isEmpty {
                appendAgentMessage(
                    "",
                    replyToMessageID: replyToMessageID,
                    artifacts: artifacts,
                    artifactWarnings: warnings
                )
            }
        }
    }

    var isConfigurationConnected: Bool {
        switch configuration.connectionType {
        case .byAddress:
            return appViewModel.isAgentConnected(configuration)
        case .legacyByApi:
            return false
        }
    }

    var connectionSnapshot: AgentConnectionSnapshot? {
        appViewModel.agentConnectionSnapshots[configuration.id]
    }

    /// Made under an Address this device no longer holds: readable, never connected or sent from.
    /// Read live, since a link can stamp the chat while this view model exists.
    var isFromPreviousIdentity: Bool {
        appViewModel.isFromPreviousIdentity(storedRowOf: session)
    }

    /// Sends are refused in a previous-identity chat and in a Claude Station, which has its own composer.
    private var acceptsSends: Bool {
        !isFromPreviousIdentity && !isStation
    }

    /// The previous-identity chat's one action: a new chat with the same agent, as the current Address.
    func startNewChat() {
        appViewModel.createNewSession(for: configuration)
    }

    /// This chat's status, from its own connection, never the background agent check.
    /// `connectingFor` is measured by the view, so "Connecting…" becomes "Can't connect" after 10 s.
    func connectionStatus(connectingFor: TimeInterval = 0) -> ChatConnectionStatus {
        if incompatibility != nil {
            return .unreachable(.incompatible)
        }
        if service.isHostedAgentStatusLive {
            return service.isAgentRequestActive ? .working : .live
        }
        if service.connectionError != nil
            || ["Offline", "Connection error"].contains(service.hostedAgentStatus) {
            return .unreachable(.noAnswer)
        }
        if service.isConnected {
            return connectingFor >= ChatConnectionStatus.unreachableAfter
                ? .unreachable(.noAnswer)
                : .connecting
        }
        return .notConnected
    }

    var isConnecting: Bool {
        connectionStatus() == .connecting
    }

    /// The status's Retry: drop this chat's connection and open it again.
    func retryConnection() {
        service.disconnect()
        service.connect(with: configuration)
    }

    func connectIfNeeded() {
        if !service.isConnected, !isFromPreviousIdentity {
            service.connect(with: configuration)
        }
    }

    func startStatusMonitoring() {
        guard configuration.connectionType == .byAddress else { return }

        statusTask?.cancel()
        appViewModel.refreshAgentStatus(for: configuration)

        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                guard let self else { break }
                self.appViewModel.refreshAgentStatus(for: self.configuration)
            }
        }
    }

    func stopStatusMonitoring() {
        statusTask?.cancel()
        statusTask = nil
    }

    var canAttachFiles: Bool {
        guard configuration.connectionType == .byAddress,
              pendingInteraction == nil else {
            return false
        }
        return service.hostedFileInputCapabilities?.isSupported != false
    }

    var fileInputHelpText: String {
        if configuration.connectionType != .byAddress {
            return "File upload is available for hosted ConnectOnion agents"
        }
        if service.hostedFileInputCapabilities?.isSupported == false {
            return "This agent does not accept file uploads"
        }
        let limits = currentFileInputCapabilities
        return "Attach up to \(limits.maxFilesPerRequest ?? 10) files, "
            + "\(limits.maxFileSizeMB ?? 10) MB each"
    }

    /// Validates and loads picked or dropped files, collecting per-file errors
    /// so one bad file does not reject the rest of the batch.
    @discardableResult
    func addAttachments(from urls: [URL]) -> Bool {
        guard canAttachFiles else {
            attachmentError = fileInputHelpText
            return false
        }

        let limits = currentFileInputCapabilities
        let maxFiles = limits.maxFilesPerRequest ?? 10
        let maxBytes = (limits.maxFileSizeMB ?? 10) * 1_024 * 1_024
        var addedAny = false
        var errors: [String] = []

        for url in urls {
            guard pendingAttachments.count < maxFiles else {
                errors.append("You can attach up to \(maxFiles) files")
                break
            }

            let name = url.lastPathComponent
            guard !pendingAttachments.contains(where: { $0.name == name }) else {
                errors.append("\(name) is already attached")
                continue
            }

            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                )
                guard values.isRegularFile == true else {
                    errors.append("\(name) is not a regular file")
                    continue
                }
                if let fileSize = values.fileSize, fileSize > maxBytes {
                    errors.append(
                        "\(name) is larger than \(limits.maxFileSizeMB ?? 10) MB"
                    )
                    continue
                }

                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= maxBytes else {
                    errors.append(
                        "\(name) is larger than \(limits.maxFileSizeMB ?? 10) MB"
                    )
                    continue
                }

                let mimeType = UTType(filenameExtension: url.pathExtension)?
                    .preferredMIMEType ?? "application/octet-stream"
                pendingAttachments.append(
                    ConnectOnionInputFile(
                        name: name,
                        mimeType: mimeType,
                        data: data
                    )
                )
                addedAny = true
            } catch {
                errors.append("Could not read \(name): \(error.localizedDescription)")
            }
        }

        attachmentError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return addedAny
    }

    func removeAttachment(_ attachment: ConnectOnionInputFile) {
        pendingAttachments.removeAll { $0.id == attachment.id }
        attachmentError = nil
    }

    /// Captures the composer text before recording so the live transcript
    /// appends to what was typed instead of replacing it.
    func toggleVoiceInput() {
        guard !voiceInputService.isTranscribing, dictatingRoomID == nil else { return }
        if voiceInputService.isRecording {
            voiceInputService.stopRecording()
        } else {
            textBeforeVoiceInput = inputText
            voiceInputService.startRecording()
        }
    }
}

/// Message submission, retries, runtime interaction responses, and
/// execution-run bookkeeping.
extension ChatViewModel {
    /// Sends the composer contents; an attachment-only send is given a default
    /// summarize prompt so the request text is never empty.
    func sendMessage() {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty || !pendingAttachments.isEmpty,
              !service.isMirroredTurn, acceptsSends else { return }

        if let validationError = attachmentValidationError {
            attachmentError = validationError
            return
        }

        let filesToSend = pendingAttachments
        let textToSend = trimmedInput.isEmpty
            ? "Please read and summarize the attached file(s)."
            : inputText
        submitRequest(
            ChatRetryRequest(
                displayContent: textToSend,
                requestContent: textToSend,
                files: filesToSend
            ),
            title: trimmedInput.isEmpty
                ? (filesToSend.first?.name ?? textToSend)
                : inputText,
            clearsComposer: true
        )
    }

    /// A Control Center button's `/skill args` line, already checked by the kit pane, goes out as a
    /// normal, visible user turn (O Chat and Android do the same). The composer draft is left alone.
    func runControlCenterSkill(_ message: String) {
        guard pendingInteraction == nil else { return }
        submitRequest(
            ChatRetryRequest(displayContent: message, requestContent: message, files: []),
            title: message,
            clearsComposer: false
        )
    }

    /// Only your latest sent message can be edited, and only while nothing is running.
    func canEditMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .user, let index = latestRedoableMessageIndex() else {
            return false
        }
        return messages[index].id == message.id
    }

    /// Only the agent's latest reply, to your latest message, can be retried.
    func canRetryAgentMessage(_ agentMessage: ChatMessage) -> Bool {
        guard agentMessage.role == .agent,
              let index = latestRedoableMessageIndex(),
              let replyIndex = messages.lastIndex(where: { $0.role == .agent }),
              replyIndex > index else {
            return false
        }
        return messages[replyIndex].id == agentMessage.id
    }

    func canRetryFailedMessage(_ message: ChatMessage) -> Bool {
        message.role == .user
            && message.status == .error
            && pendingInteraction == nil
            && !service.isAgentRequestActive
            && retryRequest(for: message) != nil
    }

    /// Sends a failed message again: the failed copy goes, a fresh one is sent in its place.
    func retryFailedMessage(_ message: ChatMessage) {
        guard canRetryFailedMessage(message),
              let request = retryRequest(for: message) else {
            return
        }
        failureByMessageID[message.id] = nil
        messages.removeAll { $0.id == message.id }
        appViewModel.messages.removeAll { $0.id == message.id }
        attachmentError = nil
        submitRequest(request, title: nil, clearsComposer: false)
    }

    /// Has the agent answer your latest message again; its old answer is replaced in place.
    func retryAgentMessage(_ agentMessage: ChatMessage) {
        guard canRetryAgentMessage(agentMessage) else {
            return
        }
        redoLatestTurn(editedText: nil)
    }

    /// Changes your latest message in place and has the agent answer it again.
    func editLatestMessage(_ message: ChatMessage, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canEditMessage(message) else {
            return
        }
        redoLatestTurn(editedText: trimmed)
    }

    func submitAskUser(answer: String, displayAnswer: String? = nil) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let response = ChatMessage(
            sessionId: session.id,
            role: .user,
            content: displayAnswer ?? trimmed
        )
        messages.append(response)
        appViewModel.addMessage(response)
        pendingInteraction = nil
        interactionError = nil

        Task {
            await service.respondToAskUser(trimmed)
        }
    }

    /// The running tool the open approval card asks about. Its row shows Awaiting approval.
    var toolAwaitingApprovalID: String? {
        guard case .approval(let request)? = pendingInteraction,
              let runID = activeExecutionRunID,
              let run = executionRuns.first(where: { $0.id == runID }) else {
            return nil
        }
        // Matched by name and arguments. If the approval encodes a number differently from the
        // tool call (1 vs 1.0), nothing matches and the row just stays Running: harmless.
        return run.items.last { item in
            guard case .toolCall(let toolCall) = item else { return false }
            return toolCall.status == .running
                && toolCall.name.lowercased() == request.tool.lowercased()
                && JSONValue.object(toolCall.args) == request.arguments
        }?.id
    }

    func submitApproval(_ decision: ConnectOnionApprovalDecision) {
        if case .rejectSoft = decision, let toolID = toolAwaitingApprovalID {
            markTool(toolID, as: .skipped)
        }
        if case .approval(let request)? = pendingInteraction {
            let recordedDecision: ApprovalRecordDecision
            switch decision {
            case .approveOnce:
                recordedDecision = .approvedOnce
            case .approveSession:
                recordedDecision = .approvedForSession
            case .rejectSoft:
                recordedDecision = .skipped
            case .rejectHard:
                recordedDecision = .rejectedAndStopped
            }
            upsertExecutionItem(
                .approval(
                    ApprovalExecutionItem(
                        id: "approval-\(request.id)",
                        tool: request.tool,
                        target: request.targetSummary,
                        risk: request.riskLevel,
                        decision: recordedDecision
                    )
                )
            )
        }
        pendingInteraction = nil
        interactionError = nil

        Task {
            await service.respondToApproval(decision)
        }
    }

    func setExecutionMode(_ mode: AgentExecutionMode) {
        guard pendingInteraction == nil else { return }
        Task {
            await service.setExecutionMode(mode)
        }
    }

    func submitPlanReview(_ decision: ConnectOnionPlanReviewDecision) {
        pendingInteraction = nil
        interactionError = nil
        Task {
            await service.respondToPlanReview(decision)
        }
    }

    func submitULWCheckpoint(_ decision: ConnectOnionULWCheckpointDecision) {
        pendingInteraction = nil
        interactionError = nil
        Task {
            await service.respondToULWCheckpoint(decision)
        }
    }

    func submitInviteCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSubmittingInteraction = true
        interactionError = nil
        Task {
            await service.submitInviteCode(trimmed)
            self.isSubmittingInteraction = false
        }
    }

    func retryRecovery() {
        recoveryStatus = "Retrying hosted session recovery"
        interactionError = nil
        Task {
            await service.retryRecovery()
        }
    }

    var canSendMessage: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !pendingAttachments.isEmpty,
              attachmentValidationError == nil,
              pendingInteraction == nil,
              !voiceInputService.isRecording,
              !voiceInputService.isTranscribing else {
            return false
        }
        return configuration.connectionType == .byAddress
            && !service.isInterruptRequested
    }

    /// Another device's turn is streaming; Send stays off until it finishes.
    var isReplyingElsewhere: Bool { service.isMirroredTurn }

    /// A prompt typed on another device: shown as a user turn and given a run so the
    /// reply streams into the transcript as for a local one.
    private func appendMirroredUserMessage(_ text: String) {
        prepareForNewRequest()
        var message = ChatMessage(sessionId: session.id, role: .user, content: text)
        message.status = .sent
        messages.append(message)
        appViewModel.addMessage(message)
        startExecutionRun(for: message.id)
        appViewModel.updateSessionDate(session)
    }

    /// Adds the host's turns this device has not seen, using the Kit's matcher shared with iOS.
    private func catchUp(with items: [CatchUpItem], isRunning: Bool) {
        let local = messages.map { CatchUpItem(role: $0.role == .user ? .user : .agent, text: $0.content) }
        for step in MirroredTurn.catchUpSteps(host: items, local: local, isRunning: isRunning) {
            switch step {
            case .user(let text):
                let message = ChatMessage(sessionId: session.id, role: .user, content: text)
                messages.append(message)
                appViewModel.addMessage(message)
            case .agent(let text):
                appendAgentMessage(text)
            case .runningUser(let text, let isKnown):
                if !isKnown {
                    appendMirroredUserMessage(text)
                } else if activeExecutionRunID == nil,
                          let existing = messages.last(where: {
                              $0.role == .user && MirroredTurn.sameText($0.content, text)
                          }) {
                    startExecutionRun(for: existing.id)
                }
            }
        }
    }

    var canInterruptAgent: Bool {
        configuration.connectionType == .byAddress
            && service.isAgentRequestActive
    }

    var isInterruptRequested: Bool {
        service.isInterruptRequested
    }

    var isInterruptEscalating: Bool {
        service.isInterruptEscalating
    }

    /// Optimistically settles outstanding messages and the active run, then
    /// asks the service to interrupt; suppression rolls back if nothing was
    /// actually in flight.
    func interruptAgent() {
        guard canInterruptAgent, !service.isInterruptRequested else { return }
        isDiscardingInterruptedEvents = true
        pendingUsage = nil
        pendingArtifacts = []
        pendingArtifactWarnings = []
        pendingInteraction = nil
        interactionError = nil
        recoveryStatus = nil
        markOutstandingMessages(as: .sent)
        finishActiveExecutionRun(with: .done)
        Task {
            let wasRequested = await service.interruptCurrentRequest()
            if !wasRequested {
                self.isDiscardingInterruptedEvents = false
            }
        }
    }

    var showsExecutionModeSelector: Bool {
        configuration.connectionType == .byAddress
    }

    var desiredExecutionMode: AgentExecutionMode {
        service.desiredExecutionMode
    }

    var confirmedExecutionMode: AgentExecutionMode {
        service.confirmedExecutionMode
    }
    /// Pending until mode_changed arrives. When idle the request rides the next INPUT
    var isExecutionModeChangePending: Bool {
        service.desiredExecutionMode != service.confirmedExecutionMode
    }

    /// Accept (full-access) only when the host lists it; the host rejects it with -32602 otherwise
    var offeredExecutionModes: [AgentExecutionMode] {
        AgentExecutionMode.allCases.filter {
            $0 != .accept || service.availableExecutionModes.contains(.accept)
        }
    }

    var acceptTurnsLeft: Int? {
        service.confirmedExecutionMode == .accept ? service.acceptTurnsLeft : nil
    }

    var canChangeExecutionMode: Bool {
        pendingInteraction == nil
    }

    private var currentFileInputCapabilities:
        ConnectOnionAgentInfo.FileInputCapabilities {
        service.hostedFileInputCapabilities ?? .protocolDefault
    }

    private var attachmentValidationError: String? {
        attachmentValidationError(for: pendingAttachments)
    }

    private func attachmentValidationError(
        for attachments: [ConnectOnionInputFile]
    ) -> String? {
        guard !attachments.isEmpty else { return nil }
        guard configuration.connectionType == .byAddress else {
            return "File upload is only available for hosted ConnectOnion agents"
        }

        let limits = currentFileInputCapabilities
        guard limits.isSupported else {
            return "This agent does not accept file uploads"
        }
        let maxFiles = limits.maxFilesPerRequest ?? 10
        guard attachments.count <= maxFiles else {
            return "You can attach up to \(maxFiles) files"
        }
        let maxBytes = (limits.maxFileSizeMB ?? 10) * 1_024 * 1_024
        if let oversized = attachments.first(where: { $0.byteCount > maxBytes }) {
            return "\(oversized.name) is larger than \(limits.maxFileSizeMB ?? 10) MB"
        }
        return nil
    }

    private func appendAgentMessage(
        _ text: String,
        usage: ChatUsageSummary? = nil,
        replyToMessageID: UUID? = nil,
        artifacts: [GeneratedArtifactReference] = [],
        artifactWarnings: [String] = []
    ) {
        let newMessage = ChatMessage(
            sessionId: session.id,
            role: .agent,
            content: text,
            usage: usage,
            replyToMessageID: replyToMessageID,
            artifacts: artifacts.isEmpty ? nil : artifacts,
            artifactWarnings: artifactWarnings.isEmpty ? nil : artifactWarnings
        )
        messages.append(newMessage)
        appViewModel.addMessage(newMessage)
    }

    /// A problem that belongs to no message: one quiet row, not repeated.
    private func appendSystemNotice(_ text: String) {
        if let last = messages.last, last.role == .system, last.content == text {
            return
        }
        let notice = ChatMessage(sessionId: session.id, role: .system, content: text)
        messages.append(notice)
        appViewModel.addMessage(notice)
    }

    private var outstandingMessageIDs: [UUID] {
        messages
            .filter { $0.status == .sending || $0.status == .queued }
            .map(\.id)
    }

    private func consumePendingArtifacts() -> [GeneratedArtifactReference] {
        defer { pendingArtifacts = [] }
        return pendingArtifacts
    }

    private func consumePendingArtifactWarnings() -> [String] {
        defer { pendingArtifactWarnings = [] }
        return pendingArtifactWarnings
    }

    private func appendAgentImage(
        _ url: String,
        replyToMessageID: UUID? = nil
    ) {
        let newMessage = ChatMessage(
            sessionId: session.id,
            role: .agent,
            content: "",
            imageURL: url,
            replyToMessageID: replyToMessageID
        )
        messages.append(newMessage)
        appViewModel.addMessage(newMessage)
    }

    /// Shared path for new sends and retries: records the user message, caches
    /// it for retry, opens an execution run, and hands off to the service.
    private func submitRequest(
        _ request: ChatRetryRequest,
        title: String?,
        clearsComposer: Bool
    ) {
        guard !service.isInterruptRequested, acceptsSends else { return }
        let summaries = request.files.map {
            ChatAttachmentSummary(name: $0.name, byteCount: $0.byteCount)
        }
        var message = ChatMessage(
            sessionId: session.id,
            role: .user,
            content: request.displayContent,
            attachments: summaries.isEmpty ? nil : summaries
        )
        message.status = .sending
        prepareForNewRequest()
        messages.append(message)
        appViewModel.addMessage(message)
        appViewModel.cacheRetryRequest(request, for: message.id)
        startExecutionRun(for: message.id)
        if let title {
            appViewModel.updateSessionTitle(session, with: title)
        }
        appViewModel.updateSessionDate(session)

        if clearsComposer {
            inputText = ""
            pendingAttachments = []
            attachmentError = nil
        }

        Task {
            if !service.isConnected {
                service.connect(with: configuration)
            }
            await service.sendMessage(
                request.requestContent,
                files: request.files,
                localMessageID: message.id,
                using: configuration
            )
        }
    }

    /// Your latest message, when it was sent, nothing is running, and it can be rebuilt to send again.
    private func latestRedoableMessageIndex() -> Int? {
        guard !isRedoing,
              !isFromPreviousIdentity,
              pendingInteraction == nil,
              !service.isAgentRequestActive,
              !voiceInputService.isRecording,
              !voiceInputService.isTranscribing,
              let index = messages.lastIndex(where: { $0.role == .user }),
              messages[index].status == .sent,
              let request = retryRequest(for: messages[index]),
              attachmentValidationError(for: request.files) == nil else {
            return nil
        }
        return index
    }

    /// Rewinds the agent's session to before your latest message, then sends it again in place.
    private func redoLatestTurn(editedText: String?) {
        guard let index = latestRedoableMessageIndex(),
              let cached = retryRequest(for: messages[index]) else {
            return
        }
        let messageID = messages[index].id
        let request = editedText.map {
            ChatRetryRequest(displayContent: $0, requestContent: $0, files: cached.files)
        } ?? cached
        attachmentError = nil
        // Set before the Task: the send only marks a request active once it starts, so a second
        // click in between would rewind again and lose the turn before this one.
        isRedoing = true
        Task {
            defer { isRedoing = false }
            if !service.isConnected {
                service.connect(with: configuration)
            }
            // The prompt as the host has it, so the cut lands on that message and not on one
            // Core added mid-turn.
            guard await service.rewindLatestTurn(prompt: cached.requestContent) else {
                appendSystemNotice("Couldn't redo that. Send it again as a new message instead.")
                return
            }
            replaceLatestTurn(messageID: messageID, with: request)
            await service.sendMessage(
                request.requestContent,
                files: request.files,
                localMessageID: messageID,
                using: configuration
            )
        }
    }

    /// Drops everything after your message, including its tool steps, and marks it as sending again.
    private func replaceLatestTurn(messageID: UUID, with request: ChatRetryRequest) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        let dropped = messages[(index + 1)...]
        let droppedIDs = Set(dropped.map(\.id))
        // Their exported files go too, as when a chat is deleted.
        appViewModel.generatedArtifactStore.removeArtifacts(dropped.flatMap { $0.artifacts ?? [] })
        messages.removeSubrange((index + 1)...)
        appViewModel.messages.removeAll { droppedIDs.contains($0.id) }
        messages[index].content = request.displayContent
        messages[index].status = .sending
        appViewModel.upsertMessage(messages[index])
        appViewModel.cacheRetryRequest(request, for: messageID)
        setExecutionRuns(executionRuns.filter { $0.userMessageId != messageID })
        prepareForNewRequest()
        startExecutionRun(for: messageID)
        appViewModel.updateSessionDate(session)
    }

    /// Only a newly submitted request may release the event fence left by an
    /// interrupted run. Terminal events from the old socket must not do so.
    private func prepareForNewRequest() {
        isDiscardingInterruptedEvents = false
        pendingUsage = nil
        pendingArtifacts = []
        pendingArtifactWarnings = []
        pendingInteraction = nil
        interactionError = nil
        recoveryStatus = nil
    }

    /// Rebuilds a text-only request when the cache no longer has one; sends
    /// that included attachments cannot be reconstructed and are not retryable.
    private func retryRequest(
        for sourceMessage: ChatMessage
    ) -> ChatRetryRequest? {
        if let cached = appViewModel.retryRequest(for: sourceMessage.id) {
            return cached
        }
        guard sourceMessage.attachments?.isEmpty != false else {
            return nil
        }
        return ChatRetryRequest(
            displayContent: sourceMessage.content,
            requestContent: sourceMessage.content,
            files: []
        )
    }

    private var activeRequestMessageID: UUID? {
        guard let activeExecutionRunID,
              let run = executionRuns.first(where: {
                  $0.id == activeExecutionRunID
              }) else {
            return nil
        }
        return run.userMessageId
    }

    private func setExecutionItems(_ items: [ExecutionItem]) {
        executionItems = items
        appViewModel.setExecutionItems(items, for: session.id)
    }

    private func setExecutionRuns(_ runs: [ExecutionRun]) {
        executionRuns = runs
        appViewModel.setExecutionRuns(runs, for: session.id)
    }

    private func startExecutionRun(for userMessageID: UUID) {
        let run = ExecutionRun(
            sessionId: session.id,
            userMessageId: userMessageID
        )
        activeExecutionRunID = run.id
        setExecutionRuns(executionRuns + [run])
    }

    private func finishActiveExecutionRun(with status: ExecutionRunStatus) {
        guard let runID = activeExecutionRunID,
              let index = executionRuns.firstIndex(where: { $0.id == runID }) else {
            activeExecutionRunID = nil
            return
        }

        var runs = executionRuns
        runs[index].status = status
        runs[index].endedAt = Date()
        runs[index].items = runs[index].items.map {
            finalizedExecutionItem($0, runStatus: status)
        }
        setExecutionRuns(runs)
        syncExecutionItems(from: runs[index])
        activeExecutionRunID = nil
    }

    private func finalizedExecutionItem(
        _ item: ExecutionItem,
        runStatus: ExecutionRunStatus
    ) -> ExecutionItem {
        let itemStatus: ExecutionStatus = runStatus == .error ? .error : .done
        switch item {
        case .thinking(var thinking) where thinking.status == .running:
            thinking.status = itemStatus
            return .thinking(thinking)
        case .toolCall(var toolCall) where toolCall.status == .running:
            // It never got a result, so it never finished: Stop, a lost connection, a
            // failure, or the rest of a batch you stopped (the host sends those nothing).
            toolCall.status = .interrupted
            return .toolCall(toolCall)
        case .approval:
            return item
        default:
            return item
        }
    }

    private func syncExecutionItems(from run: ExecutionRun) {
        guard !run.items.isEmpty else {
            return
        }

        var items = executionItems
        for item in run.items {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item.mergingDisplayFields(from: items[index])
            } else {
                items.append(item)
            }
        }
        setExecutionItems(items)
    }

    private func upsertExecutionItem(_ item: ExecutionItem) {
        var items = executionItems
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item.mergingDisplayFields(from: items[index])
        } else {
            items.append(item)
        }
        setExecutionItems(items)
        upsertExecutionItemInActiveRun(item)
    }

    /// Execution events can arrive with no request in flight, so an implicit
    /// run is created on demand to keep the trace grouped.
    private func upsertExecutionItemInActiveRun(_ item: ExecutionItem) {
        if activeExecutionRunID == nil {
            let run = ExecutionRun(sessionId: session.id, userMessageId: nil)
            activeExecutionRunID = run.id
            executionRuns.append(run)
        }

        guard let runID = activeExecutionRunID,
              let runIndex = executionRuns.firstIndex(where: { $0.id == runID }) else {
            return
        }

        var runs = executionRuns
        if let itemIndex = runs[runIndex].items.firstIndex(where: { $0.id == item.id }) {
            runs[runIndex].items[itemIndex] = item.mergingDisplayFields(
                from: runs[runIndex].items[itemIndex]
            )
        } else {
            runs[runIndex].items.append(item)
        }
        setExecutionRuns(runs)
    }

    private func markTool(_ toolID: String, as status: ExecutionStatus) {
        guard let runID = activeExecutionRunID,
              let run = executionRuns.first(where: { $0.id == runID }),
              case .toolCall(var toolCall)? = run.items.first(where: { $0.id == toolID }) else {
            return
        }
        toolCall.status = status
        upsertExecutionItem(.toolCall(toolCall))
    }

    private func updateMessageStatus(_ messageID: UUID, to status: MessageStatus) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].status = status
        appViewModel.updateMessageStatus(messageID, to: status)
    }

    private func markOutstandingMessages(as status: MessageStatus) {
        let outstandingIDs = messages
            .filter { $0.status == .sending || $0.status == .queued }
            .map(\.id)
        for messageID in outstandingIDs {
            updateMessageStatus(messageID, to: status)
        }
    }
}
