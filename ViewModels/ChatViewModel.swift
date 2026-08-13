import Foundation
import Combine
import UniformTypeIdentifiers

/// Drives a single conversation: transcript, composer, attachments, voice
/// input, and runtime interactions, all mirrored into the shared AppViewModel
/// store so the state outlives this view model.
@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var executionItems: [ExecutionItem] = []
    @Published var executionRuns: [ExecutionRun] = []
    @Published var inputText: String = ""
    @Published var pendingAttachments: [ConnectOnionInputFile] = []
    @Published var attachmentError: String?
    /// Runtime question or approval awaiting the user's answer; sending and
    /// attaching stay disabled until it resolves.
    @Published var pendingInteraction: ConnectOnionPendingInteraction?
    @Published var interactionError: String?
    @Published var recoveryStatus: String?
    @Published var isSubmittingInteraction = false
    @Published private(set) var latestUsage: ChatUsageSummary?
    /// Set after an interrupt so every trailing event from that cancelled run
    /// is discarded instead of reaching the transcript.
    @Published private(set) var isDiscardingInterruptedEvents = false

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
    let voiceInputService = VoiceInputService()

    private var messageTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingUsage: ChatUsageSummary?
    private var pendingArtifacts: [GeneratedArtifactReference] = []
    private var pendingArtifactWarnings: [String] = []
    private var textBeforeVoiceInput = ""
    private var activeExecutionRunID: UUID?

    init(session: ChatSession, configuration: GeneralAgentConfiguration, service: ConnectOnionService, appViewModel: AppViewModel) {
        self.session = session
        self.initialConfiguration = configuration
        self.service = service
        self.appViewModel = appViewModel

        messages = appViewModel.findMessages(for: session.id)
        executionItems = appViewModel.findExecutionItems(for: session.id)
        executionRuns = appViewModel.findExecutionRuns(for: session.id)
        latestUsage = messages.reversed().compactMap(\.usage).first

        setupBindings()
    }

    deinit {
        messageTask?.cancel()
        statusTask?.cancel()
    }

    private func setupBindings() {
        service.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
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
                let prefix = self.textBeforeVoiceInput
                self.inputText = prefix.isEmpty ? transcript : "\(prefix) \(transcript)"
            }
            .store(in: &cancellables)

        messageTask = Task { [weak self] in
            for await event in service.incomingEvents.values {
                if Task.isCancelled { break }
                guard let self else { break }
                self.handleIncomingEvent(event)
            }
        }
    }

    func handleIncomingEvent(_ event: ConnectOnionTransportEvent) {
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

        case .error(let message):
            pendingUsage = nil
            isSubmittingInteraction = false
            interactionError = message
            let replyToMessageID = activeRequestMessageID
            finishActiveExecutionRun(with: .error)
            if case .onboarding? = pendingInteraction {
                return
            }
            markOutstandingMessages(as: .error)
            if configuration.connectionType == .byAddress {
                appViewModel.setAgentConnected(configuration, isConnected: false)
            }
            appendAgentMessage(
                "Error: \(message)",
                replyToMessageID: replyToMessageID,
                artifacts: consumePendingArtifacts(),
                artifactWarnings: consumePendingArtifactWarnings()
            )
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

    func connectIfNeeded() {
        if !service.isConnected {
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
        guard !voiceInputService.isTranscribing else { return }
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
        guard !trimmedInput.isEmpty || !pendingAttachments.isEmpty else { return }

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

    func canRetryAgentMessage(_ agentMessage: ChatMessage) -> Bool {
        guard agentMessage.role == .agent,
              pendingInteraction == nil,
              !service.isAgentRequestActive,
              !voiceInputService.isRecording,
              !voiceInputService.isTranscribing,
              let sourceMessage = sourceUserMessage(for: agentMessage),
              let request = retryRequest(for: sourceMessage),
              attachmentValidationError(for: request.files) == nil else {
            return false
        }
        return true
    }

    func retryAgentMessage(_ agentMessage: ChatMessage) {
        guard canRetryAgentMessage(agentMessage),
              let sourceMessage = sourceUserMessage(for: agentMessage),
              let request = retryRequest(for: sourceMessage) else {
            return
        }

        attachmentError = nil
        submitRequest(request, title: nil, clearsComposer: false)
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

    func submitApproval(_ decision: ConnectOnionApprovalDecision) {
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

    var isExecutionModeChangePending: Bool {
        service.isAgentRequestActive
            && service.desiredExecutionMode != service.confirmedExecutionMode
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

    private func sourceUserMessage(
        for agentMessage: ChatMessage
    ) -> ChatMessage? {
        guard agentMessage.role == .agent else { return nil }
        if let replyToMessageID = agentMessage.replyToMessageID,
           let sourceMessage = messages.first(where: {
               $0.id == replyToMessageID && $0.role == .user
           }) {
            return sourceMessage
        }
        guard let agentIndex = messages.firstIndex(where: {
            $0.id == agentMessage.id
        }) else {
            return nil
        }
        return messages[..<agentIndex].last { $0.role == .user }
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
            toolCall.status = itemStatus
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
