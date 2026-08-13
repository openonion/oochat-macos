import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// App-wide source of truth for agent configurations, sessions, messages, and
/// execution history. Persists everything to UserDefaults and keeps sessions
/// attached to the right agent as configurations come and go.
@MainActor
class AppViewModel: ObservableObject {
    @Published var previousSelection: NavigationItem?
    /// Configurations currently believed reachable, updated by both status
    /// probes and live chat traffic.
    @Published var connectedConfigurationIds: Set<UUID> = []
    @Published var agentConnectionSnapshots: [UUID: AgentConnectionSnapshot] = [:]

    @Published var configurations: [GeneralAgentConfiguration] = [] {
        didSet { saveConfigurations() }
    }
    @Published var sessions: [ChatSession] = [] {
        didSet { saveSessions() }
    }

    @Published var messages: [ChatMessage] = [] {
        didSet { saveMessages() }
    }
    @Published var executionItemsBySession: [UUID: [ExecutionItem]] = [:] {
        didSet { saveExecutionItems() }
    }
    @Published var executionRunsBySession: [UUID: [ExecutionRun]] = [:] {
        didSet { saveExecutionRuns() }
    }

    @Published var selection: NavigationItem?
    /// Bumped on every explicit history selection so views can re-focus the
    /// session even when the selection value itself did not change.
    @Published private(set) var sessionSelectionRevision = 0
    /// Sessions that no longer resolve to a live agent configuration and could
    /// not be reconciled by their stable identity.
    @Published private(set) var orphanedSessions: [ChatSession] = []

    private let configKey = "saved_configurations"
    private let sessionKey = "saved_sessions"
    private let messageKey = "saved_messages"
    private let executionItemsKey = "saved_execution_items"
    private let executionRunsKey = "saved_execution_runs"
    private let deletedRemoteSessionIDsKey = "deleted_remote_session_ids"
    private let storage: UserDefaults
    let generatedArtifactStore: GeneratedArtifactStore
    private let resolveAgentEndpoint: (String) async throws -> ConnectOnionResolvedEndpoint
    private let historyClient: ConnectOnionHistoryClient
    private let localAgentDefinitions: [LocalAgentDefinition]
    private var agentStatusTasks: [UUID: Task<Void, Never>] = [:]
    private var retryRequestsByMessageID: [UUID: ChatRetryRequest] = [:]
    private var retryRequestOrder: [UUID] = []
    private var deletedRemoteSessionIDs: Set<String> = []
    private let retryRequestCountLimit = 20
    private let retryAttachmentByteLimit = 50 * 1_024 * 1_024

    init(
        storage: UserDefaults = .standard,
        generatedArtifactStore: GeneratedArtifactStore = .shared,
        localAgentDefinitions: [LocalAgentDefinition] =
            LocalAgentDefinition.automaticDiscoveryTargets,
        historyClient: ConnectOnionHistoryClient = ConnectOnionHistoryClient(),
        resolveAgentEndpoint: @escaping (String) async throws -> ConnectOnionResolvedEndpoint = {
            try await ConnectOnionEndpointResolver().resolve($0)
        }
    ) {
        self.storage = storage
        self.generatedArtifactStore = generatedArtifactStore
        self.localAgentDefinitions = localAgentDefinitions
        self.historyClient = historyClient
        self.resolveAgentEndpoint = resolveAgentEndpoint
        loadData()
    }

    /// Seeds the remote session ID from the local UUID so the transcript the
    /// host stores for this chat can be matched back during history import.
    func createNewSession(for config: GeneralAgentConfiguration) {
        let sessionID = UUID()
        let newSession = ChatSession(
            id: sessionID,
            agentConfigId: config.id,
            agentIdentity: config.agentIdentity,
            remoteSessionID: sessionID.uuidString.lowercased(),
            title: "New Chat"
        )
        sessions.append(newSession)
        selection = .session(newSession.id)
    }

    func selectHistoricalSession(_ sessionId: UUID) {
        selection = .session(sessionId)
        sessionSelectionRevision &+= 1
    }

    func deleteConfiguration(_ configuration: GeneralAgentConfiguration) {
        let sessionIds = sessions
            .filter { $0.agentConfigId == configuration.id }
            .map { $0.id }
        let artifactReferences = messages
            .filter { sessionIds.contains($0.sessionId) }
            .flatMap { $0.artifacts ?? [] }

        agentStatusTasks[configuration.id]?.cancel()
        agentStatusTasks[configuration.id] = nil
        connectedConfigurationIds.remove(configuration.id)
        agentConnectionSnapshots[configuration.id] = nil
        configurations.removeAll { $0.id == configuration.id }
        sessions.removeAll { $0.agentConfigId == configuration.id }
        messages.removeAll { sessionIds.contains($0.sessionId) }
        for sessionId in sessionIds {
            executionItemsBySession.removeValue(forKey: sessionId)
            executionRunsBySession.removeValue(forKey: sessionId)
        }
        generatedArtifactStore.removeArtifacts(artifactReferences)

        if case .session(let selectedSessionId) = selection,
           sessionIds.contains(selectedSessionId) {
            selection = nil
        }
    }

    /// Removes sessions that could not be reconciled to any live agent,
    /// along with their messages and execution history.
    func discardOrphanedSessions() {
        let orphanIDs = orphanedSessions.map { $0.id }
        guard !orphanIDs.isEmpty else { return }
        sessions.removeAll { orphanIDs.contains($0.id) }
        messages.removeAll { orphanIDs.contains($0.sessionId) }
        for sessionId in orphanIDs {
            executionItemsBySession.removeValue(forKey: sessionId)
            executionRunsBySession.removeValue(forKey: sessionId)
        }
        orphanedSessions = []
    }

    /// Tombstones the remote session ID before removing local state so a later
    /// hosted-history sync cannot resurrect the deleted chat.
    func deleteSession(_ session: ChatSession) {
        markRemoteSessionDeleted(
            session.remoteSessionID ?? session.id.uuidString.lowercased()
        )
        let artifactReferences = messages
            .filter { $0.sessionId == session.id }
            .flatMap { $0.artifacts ?? [] }
        sessions.removeAll { $0.id == session.id }
        messages.removeAll { $0.sessionId == session.id }
        executionItemsBySession.removeValue(forKey: session.id)
        executionRunsBySession.removeValue(forKey: session.id)
        generatedArtifactStore.removeArtifacts(artifactReferences)

        if selection == .session(session.id) {
            selection = nil
        }
    }

    /// Titles the session from its first message, but only while it still
    /// shows the placeholder title.
    func updateSessionTitle(_ session: ChatSession, with message: String) {
        guard session.title == "New Chat",
              let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            return
        }

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(trimmedMessage.prefix(40))
        sessions[index].title = title.isEmpty ? "New Chat" : title
    }

    func renameSession(_ session: ChatSession, to title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[index].title = trimmedTitle.isEmpty ? "New Chat" : trimmedTitle
    }

    func renameAgent(_ configuration: GeneralAgentConfiguration, to name: String) {
        guard let index = configurations.firstIndex(where: { $0.id == configuration.id }) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        configurations[index].name = trimmedName
    }

    func updateSessionDate(_ session: ChatSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            return
        }

        sessions[index].updatedAt = Date()
    }

    /// Inserts or updates a configuration, merging duplicates by stable agent
    /// identity, then opens a fresh session for the effective record.
    func saveAgent(_ config: GeneralAgentConfiguration) {
        let effectiveConfig: GeneralAgentConfiguration
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
            effectiveConfig = configurations[index]
        } else if let identity = config.agentIdentity,
                  let duplicateIndex = configurations.firstIndex(where: {
                      $0.agentIdentity == identity
                  }) {
            // Reuse the existing configuration so sessions attached to the
            // same agent keep their stable UUID instead of being orphaned.
            var merged = config
            merged.id = configurations[duplicateIndex].id
            configurations[duplicateIndex] = merged
            effectiveConfig = configurations[duplicateIndex]
        } else {
            configurations.append(config)
            effectiveConfig = config
        }

        createNewSession(for: effectiveConfig)
        reconcileSessions()
    }

    func updateAgentAvatar(
        _ configuration: GeneralAgentConfiguration,
        textColorHex: String?,
        backgroundColorHex: String?
    ) {
        guard let index = configurations.firstIndex(where: { $0.id == configuration.id }) else {
            return
        }

        configurations[index].avatarTextColorHex = textColorHex
        configurations[index].avatarBackgroundColorHex = backgroundColorHex
    }

    /// Adds an agent from a pasted address or URL, rejecting targets that fail
    /// normalization and targets that normalize to an existing configuration.
    @discardableResult
    func addAgent(_ rawTarget: String) -> AddAgentResult {
        guard let target = ConnectOnionAgentTarget.normalized(rawTarget) else {
            return .invalid
        }

        let isDuplicate = configurations.contains { configuration in
            guard configuration.connectionType == .byAddress,
                  let existingTarget = configuration.addressConfiguration?.agentAddress else {
                return false
            }
            return ConnectOnionAgentTarget.normalized(existingTarget) == target
        }
        guard !isDuplicate else {
            return .duplicate
        }

        let configuration = GeneralAgentConfiguration(
            name: suggestedAgentName(for: target),
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: target)
        )
        configurations.append(configuration)
        refreshAgentStatus(for: configuration)
        reconcileSessions()
        return .added(configuration)
    }

    func isAgentConnected(_ config: GeneralAgentConfiguration) -> Bool {
        connectedConfigurationIds.contains(config.id)
    }

    func setAgentConnected(_ config: GeneralAgentConfiguration, isConnected: Bool) {
        if isConnected {
            connectedConfigurationIds.insert(config.id)
        } else {
            connectedConfigurationIds.remove(config.id)
        }
    }

    func refreshAgentStatus(for config: GeneralAgentConfiguration) {
        agentStatusTasks[config.id]?.cancel()

        guard config.connectionType == .byAddress else {
            connectedConfigurationIds.remove(config.id)
            agentConnectionSnapshots[config.id] = nil
            return
        }

        if agentConnectionSnapshots[config.id] == nil {
            agentConnectionSnapshots[config.id] = .checking
        }
        agentStatusTasks[config.id] = Task { [weak self] in
            await self?.refreshAgentStatusAndWait(for: config)
        }
    }

    func refreshAgentStatuses() {
        for config in configurations {
            refreshAgentStatus(for: config)
        }
    }

    func monitorLocalAgents(
        intervalNanoseconds: UInt64 = 15_000_000_000
    ) async {
        while !Task.isCancelled {
            await discoverLocalAgents()
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                return
            }
        }
    }

    /// Probes each built-in local endpoint, reusing an existing configuration
    /// whenever the target or its resolved address already matches so repeated
    /// discovery never duplicates the Main Agent.
    func discoverLocalAgents() async {
        for definition in localAgentDefinitions {
            guard !Task.isCancelled else { return }

            do {
                let endpoint = try await resolveAgentEndpoint(definition.endpoint)
                let configuration: GeneralAgentConfiguration
                if let existing = matchingConfiguration(
                    matching: definition.endpoint,
                    resolvedAddress: endpoint.agentAddress
                ) {
                    configuration = existing
                } else {
                    configuration = GeneralAgentConfiguration(
                        name: endpoint.info?.name ?? definition.fallbackName,
                        connectionType: .byAddress,
                        addressConfiguration: AgentAddressConfiguration(
                            agentAddress: definition.endpoint
                        )
                    )
                    configurations.append(configuration)
                }
                apply(endpoint: endpoint, to: configuration)
                await syncHostedHistoryIfAvailable(
                    from: endpoint,
                    for: configuration
                )
            } catch {
                guard let existing = matchingConfiguration(
                    matching: definition.endpoint,
                    resolvedAddress: nil
                ) else {
                    continue
                }
                applyConnectionFailure(error, to: existing)
            }
        }
    }

    func refreshAgentStatusAndWait(for config: GeneralAgentConfiguration) async {
        await checkAgentStatus(for: config)
    }

    func findMessages(for sessionId: UUID) -> [ChatMessage] {
        return messages.filter { $0.sessionId == sessionId }
    }

    func findExecutionItems(for sessionId: UUID) -> [ExecutionItem] {
        return executionItemsBySession[sessionId] ?? []
    }

    /// Resolves the live configuration for a session, preferring its stored
    /// config UUID and falling back to the stable agent identity.
    func configuration(for session: ChatSession) -> GeneralAgentConfiguration? {
        if let config = configurations.first(where: { $0.id == session.agentConfigId }) {
            return config
        }
        if let identity = session.agentIdentity {
            return configurations.first { $0.agentIdentity == identity }
        }
        return nil
    }

    func findExecutionRuns(for sessionId: UUID) -> [ExecutionRun] {
        return executionRunsBySession[sessionId] ?? []
    }

    func setExecutionItems(_ items: [ExecutionItem], for sessionId: UUID) {
        executionItemsBySession[sessionId] = items
    }

    func setExecutionRuns(_ runs: [ExecutionRun], for sessionId: UUID) {
        executionRunsBySession[sessionId] = runs
    }

    func addExecutionItem(_ item: ExecutionItem, for sessionId: UUID) {
        var items = executionItemsBySession[sessionId] ?? []
        items.append(item)
        executionItemsBySession[sessionId] = items
    }

    func addMessage(_ message: ChatMessage) {
        messages.append(message)
    }

    /// Caches an outbound request so it can be retried, evicting the oldest
    /// entries once the count or combined attachment size exceeds its budget.
    func cacheRetryRequest(
        _ request: ChatRetryRequest,
        for messageID: UUID
    ) {
        retryRequestOrder.removeAll { $0 == messageID }
        retryRequestOrder.append(messageID)
        retryRequestsByMessageID[messageID] = request

        while retryRequestOrder.count > retryRequestCountLimit
            || cachedRetryAttachmentByteCount > retryAttachmentByteLimit {
            guard let oldestMessageID = retryRequestOrder.first else { break }
            retryRequestOrder.removeFirst()
            retryRequestsByMessageID.removeValue(forKey: oldestMessageID)
        }
    }

    func retryRequest(for messageID: UUID) -> ChatRetryRequest? {
        retryRequestsByMessageID[messageID]
    }

    private var cachedRetryAttachmentByteCount: Int {
        retryRequestsByMessageID.values.reduce(0) {
            $0 + $1.attachmentByteCount
        }
    }

    func upsertMessage(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    func updateMessageStatus(_ messageID: UUID, to status: MessageStatus) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].status = status
    }

    func saveMessages() {
        if let data = try? JSONEncoder().encode(messages) {
            storage.set(data, forKey: messageKey)
        }
    }

    func saveExecutionItems() {
        if let data = try? JSONEncoder().encode(executionItemsBySession) {
            storage.set(data, forKey: executionItemsKey)
        }
    }

    func saveExecutionRuns() {
        if let data = try? JSONEncoder().encode(executionRunsBySession) {
            storage.set(data, forKey: executionRunsKey)
        }
    }

    private func saveConfigurations() {
        if let data = try? JSONEncoder().encode(configurations) {
            storage.set(data, forKey: configKey)
        }
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            storage.set(data, forKey: sessionKey)
        }
    }

    /// Restores persisted state, migrating older records along the way: legacy
    /// non-address configurations are dropped, missing remote session IDs are
    /// backfilled, and obsolete connection notices are filtered out.
    private func loadData() {
        if let deletedSessionData = storage.data(
            forKey: deletedRemoteSessionIDsKey
        ), let decodedIDs = try? JSONDecoder().decode(
            Set<String>.self,
            from: deletedSessionData
        ) {
            deletedRemoteSessionIDs = decodedIDs
        }

        if let configData = storage.data(forKey: configKey),
           let decodedConfigs = try? JSONDecoder().decode([GeneralAgentConfiguration].self, from: configData) {
            configurations = decodedConfigs.filter {
                $0.connectionType == .byAddress
            }
            if configurations.count != decodedConfigs.count {
                saveConfigurations()
            }
        }

        if let sessionData = storage.data(forKey: sessionKey),
           let decodedSessions = try? JSONDecoder().decode([ChatSession].self, from: sessionData) {
            var migratedSessions = decodedSessions
            for index in migratedSessions.indices
                where migratedSessions[index].remoteSessionID == nil {
                migratedSessions[index].remoteSessionID =
                    connectOnionPersistedRemoteSessionID(
                        for: migratedSessions[index].id,
                        storage: storage
                    )
            }
            sessions = migratedSessions
        }

        if let messageData = storage.data(forKey: messageKey),
           let decodedMessages = try? JSONDecoder().decode([ChatMessage].self, from: messageData) {
            messages = Self.collapsingIntermediateAgentMessages(
                decodedMessages.filter { message in
                    !(message.role == .system
                        && message.content.hasPrefix("Connected to "))
                }
            )
        }

        if let executionData = storage.data(forKey: executionItemsKey),
           let decodedItems = try? JSONDecoder().decode([UUID: [ExecutionItem]].self, from: executionData) {
            executionItemsBySession = decodedItems
        }

        if let executionRunData = storage.data(forKey: executionRunsKey),
           let decodedRuns = try? JSONDecoder().decode([UUID: [ExecutionRun]].self, from: executionRunData) {
            executionRunsBySession = decodedRuns
        }

        reconcileSessions()
    }

    /// Re-attaches sessions to live configurations using their stable agent
    /// identity and surfaces sessions that can no longer be resolved.
    func reconcileSessions() {
        var reconciled = 0
        var orphans: [ChatSession] = []
        var updatedSessions = sessions
        for index in updatedSessions.indices {
            var session = updatedSessions[index]
            let isAttached = configurations.contains(where: {
                $0.id == session.agentConfigId
            })
            if isAttached {
                if session.agentIdentity == nil {
                    session.agentIdentity = configuration(for: session)?.agentIdentity
                    updatedSessions[index] = session
                }
                continue
            }
            if let identity = session.agentIdentity,
               let config = configurations.first(where: {
                   $0.agentIdentity == identity
               }) {
                session.agentConfigId = config.id
                updatedSessions[index] = session
                reconciled += 1
            } else {
                orphans.append(session)
            }
        }
        sessions = updatedSessions
        orphanedSessions = orphans
        if reconciled > 0 {
            saveSessions()
        }
    }

    private func checkAgentStatus(for config: GeneralAgentConfiguration) async {
        guard config.connectionType == .byAddress,
              let address = config.addressConfiguration?.agentAddress
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            connectedConfigurationIds.remove(config.id)
            agentConnectionSnapshots[config.id] = AgentConnectionSnapshot(
                state: .invalid,
                route: nil,
                remoteName: nil,
                tools: [],
                detail: "Missing agent target"
            )
            return
        }

        do {
            let endpoint = try await resolveAgentEndpoint(address)
            guard !Task.isCancelled,
                  configurations.contains(where: { $0.id == config.id }) else {
                return
            }

            apply(endpoint: endpoint, to: config)
            await syncHostedHistoryIfAvailable(from: endpoint, for: config)
        } catch {
            guard !Task.isCancelled,
                  configurations.contains(where: { $0.id == config.id }) else {
                return
            }

            applyConnectionFailure(error, to: config)
        }
    }

    /// Matches by normalized target first, then by resolved 0x address so a
    /// URL entry and an address entry for the same agent count as one.
    private func matchingConfiguration(
        matching target: String,
        resolvedAddress: String?
    ) -> GeneralAgentConfiguration? {
        let normalizedResolvedAddress = resolvedAddress.flatMap(
            ConnectOnionAddress.normalized
        )
        return configurations.first { configuration in
            guard configuration.connectionType == .byAddress,
                  let existingTarget = configuration.addressConfiguration?
                    .agentAddress else {
                return false
            }
            if ConnectOnionAgentTarget.normalized(existingTarget)
                == ConnectOnionAgentTarget.normalized(target) {
                return true
            }
            guard let normalizedResolvedAddress else { return false }
            return ConnectOnionAddress.normalized(existingTarget)
                == normalizedResolvedAddress
        }
    }

    private func apply(
        endpoint: ConnectOnionResolvedEndpoint,
        to configuration: GeneralAgentConfiguration
    ) {
        connectedConfigurationIds.insert(configuration.id)
        agentConnectionSnapshots[configuration.id] = AgentConnectionSnapshot(
            state: .online,
            route: endpoint.isDirect ? .direct : .relay,
            remoteName: endpoint.info?.name,
            tools: endpoint.info?.tools ?? [],
            detail: endpoint.isDirect ? "Direct endpoint" : "ConnectOnion relay",
            model: endpoint.info?.model,
            trust: endpoint.info?.trust,
            version: endpoint.info?.version
        )
    }

    /// Pulls durable history only from the local Docker host. Relay/remote
    /// endpoints are intentionally excluded because their history endpoint is
    /// not authenticated for cross-device enumeration.
    private func syncHostedHistoryIfAvailable(
        from endpoint: ConnectOnionResolvedEndpoint,
        for configuration: GeneralAgentConfiguration
    ) async {
        guard endpoint.isDirect,
              let baseURL = endpoint.httpBaseURL,
              let host = baseURL.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host) else {
            return
        }

        do {
            let hostedSessions = try await historyClient.sessions(from: baseURL)
            mergeHostedSessions(hostedSessions, for: configuration)
        } catch {
            // History reconciliation is best-effort and must never mark an
            // otherwise healthy agent offline.
        }
    }

    /// Imports hosted transcripts as local sessions, skipping tombstoned IDs,
    /// sessions with unsent local messages, and anything already newer locally.
    private func mergeHostedSessions(
        _ hostedSessions: [ConnectOnionHostedSession],
        for configuration: GeneralAgentConfiguration
    ) {
        var updatedSessions = sessions
        var updatedMessages = messages
        var didChangeSessions = false
        var didChangeMessages = false

        for hosted in hostedSessions {
            let remoteID = Self.normalizedRemoteSessionID(hosted.sessionID)
            guard !remoteID.isEmpty else { continue }
            guard !deletedRemoteSessionIDs.contains(remoteID) else { continue }

            let localID = UUID(uuidString: remoteID) ?? UUID()
            let projected = Self.projectMessages(
                from: hosted,
                sessionID: localID
            )
            guard !projected.isEmpty else { continue }

            let createdAt = Self.date(fromUnixTimestamp: hosted.created) ?? Date()
            let remoteUpdatedAt = Self.date(
                fromUnixTimestamp: hosted.conversation?.updated
            ) ?? createdAt
            let existingIndex = updatedSessions.firstIndex {
                $0.remoteSessionID == remoteID
                    || $0.id.uuidString.caseInsensitiveCompare(remoteID)
                        == .orderedSame
            }

            if let existingIndex {
                let existing = updatedSessions[existingIndex]
                if existing.remoteSessionID == nil {
                    updatedSessions[existingIndex].remoteSessionID = remoteID
                    didChangeSessions = true
                }
                let localSessionMessages = updatedMessages.filter {
                    $0.sessionId == existing.id
                }
                // Skip a destructive overwrite while the client is ahead of the
                // hosted snapshot: an unsent/queued message, a locally newer
                // session, or a just-sent trailing message the snapshot predates
                // (marked .sent by the turn's OUTPUT before the server reflected
                // it). Without the last check that message would be wiped.
                if localSessionMessages.contains(where: {
                    $0.status == .sending || $0.status == .queued
                }) || remoteUpdatedAt <= existing.updatedAt
                    || Self.hasLocalOnlyTrailingUserMessage(
                        local: localSessionMessages,
                        projected: projected
                    ) {
                    continue
                }

                updatedSessions[existingIndex].agentConfigId = configuration.id
                updatedSessions[existingIndex].agentIdentity =
                    configuration.agentIdentity
                updatedSessions[existingIndex].updatedAt = remoteUpdatedAt
                if updatedSessions[existingIndex].title == "New Chat" {
                    updatedSessions[existingIndex].title = Self.title(
                        for: projected
                    )
                }
                didChangeSessions = true

                let localTranscript = updatedMessages.filter {
                    $0.sessionId == existing.id
                }
                if Self.transcriptSignature(localTranscript)
                    == Self.transcriptSignature(projected) {
                    // Preserve native-only metadata such as usage, files,
                    // artifacts, reply links, and stable local message IDs.
                    continue
                }

                let mergedMessages = preservingLocalMetadata(
                    from: localTranscript,
                    in: projected
                )
                updatedMessages.removeAll { $0.sessionId == existing.id }
                updatedMessages.append(contentsOf: mergedMessages.map {
                    var message = $0
                    message.sessionId = existing.id
                    return message
                })
                didChangeMessages = true
            } else {
                let session = ChatSession(
                    id: localID,
                    agentConfigId: configuration.id,
                    agentIdentity: configuration.agentIdentity,
                    remoteSessionID: remoteID,
                    title: Self.title(for: projected),
                    createdAt: createdAt,
                    updatedAt: remoteUpdatedAt
                )
                updatedSessions.append(session)
                updatedMessages.append(contentsOf: projected)
                didChangeSessions = true
                didChangeMessages = true
            }
        }

        if didChangeSessions {
            sessions = updatedSessions.sorted { $0.updatedAt > $1.updatedAt }
        }
        if didChangeMessages {
            messages = updatedMessages
        }
    }

    private static func projectMessages(
        from hosted: ConnectOnionHostedSession,
        sessionID: UUID
    ) -> [ChatMessage] {
        let source = hosted.conversation?.messages ?? []
        let baseDate = date(fromUnixTimestamp: hosted.created) ?? Date()
        var projected: [ChatMessage] = []

        for (index, message) in source.enumerated() {
            guard message.isInternal != true,
                  let text = message.text?.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ),
                  !text.isEmpty else {
                continue
            }
            let role: MessageRole
            switch message.role.lowercased() {
            case "user":
                role = .user
            case "assistant", "agent", "model":
                role = .agent
            case "system":
                role = .system
            default:
                continue
            }
            projected.append(
                ChatMessage(
                    sessionId: sessionID,
                    role: role,
                    content: text,
                    timestamp: baseDate.addingTimeInterval(Double(index))
                )
            )
        }

        if !projected.contains(where: { $0.role == .user }) {
            let prompt = hosted.prompt.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !prompt.isEmpty {
                projected.insert(
                    ChatMessage(
                        sessionId: sessionID,
                        role: .user,
                        content: prompt,
                        timestamp: baseDate
                    ),
                    at: 0
                )
            }
        }
        if let result = hosted.result?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
           !result.isEmpty,
           projected.last(where: { $0.role == .agent })?.content != result {
            projected.append(
                ChatMessage(
                    sessionId: sessionID,
                    role: .agent,
                    content: result,
                    timestamp: date(
                        fromUnixTimestamp: hosted.conversation?.updated
                    ) ?? baseDate
                )
            )
        }
        return collapsingIntermediateAgentMessages(projected)
    }

    /// Older hosts persisted the user-visible intent acknowledgement as an
    /// ordinary assistant message immediately before the real answer. The live
    /// client renders that acknowledgement in the execution trace, so keeping
    /// both history records produces two avatar replies for a single turn.
    /// Retain only the final message in each consecutive assistant sequence.
    private static func collapsingIntermediateAgentMessages(
        _ messages: [ChatMessage]
    ) -> [ChatMessage] {
        var collapsed: [ChatMessage] = []
        var lastMessageIndexBySession: [UUID: Int] = [:]
        for message in messages {
            if message.role == .agent,
               let lastIndex = lastMessageIndexBySession[message.sessionId],
               collapsed[lastIndex].role == .agent {
                collapsed[lastIndex] = message
            } else {
                collapsed.append(message)
                lastMessageIndexBySession[message.sessionId] = collapsed.count - 1
            }
        }
        return collapsed
    }

    private static func title(for messages: [ChatMessage]) -> String {
        guard let firstUserMessage = messages.first(where: { $0.role == .user })
        else {
            return "Imported Chat"
        }
        let title = firstUserMessage.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return title.isEmpty ? "Imported Chat" : String(title.prefix(40))
    }

    /// Accepts seconds or milliseconds; implausibly large values are assumed
    /// to be milliseconds and scaled down.
    private static func date(fromUnixTimestamp timestamp: Double?) -> Date? {
        guard let timestamp, timestamp > 0 else { return nil }
        let seconds = timestamp > 10_000_000_000
            ? timestamp / 1_000
            : timestamp
        return Date(timeIntervalSince1970: seconds)
    }

    private static func normalizedRemoteSessionID(_ sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed)?.uuidString.lowercased() ?? trimmed
    }

    /// Persists a deletion tombstone so hosted-history sync never re-imports
    /// the session.
    private func markRemoteSessionDeleted(_ sessionID: String) {
        let normalized = Self.normalizedRemoteSessionID(sessionID)
        guard !normalized.isEmpty,
              deletedRemoteSessionIDs.insert(normalized).inserted,
              let data = try? JSONEncoder().encode(deletedRemoteSessionIDs)
        else {
            return
        }
        storage.set(data, forKey: deletedRemoteSessionIDsKey)
    }

    private func applyConnectionFailure(
        _ error: Error,
        to configuration: GeneralAgentConfiguration
    ) {
        connectedConfigurationIds.remove(configuration.id)
        let state: AgentConnectionState
        if case ConnectOnionRemoteError.invalidAgentTarget = error {
            state = .invalid
        } else {
            state = .offline
        }
        agentConnectionSnapshots[configuration.id] = AgentConnectionSnapshot(
            state: state,
            route: nil,
            remoteName: nil,
            tools: [],
            detail: error.localizedDescription
        )
    }

    private func suggestedAgentName(for target: String) -> String {
        if let address = ConnectOnionAddress.normalized(target) {
            return "\(address.prefix(6))…\(address.suffix(4))"
        }

        guard let url = ConnectOnionAgentTarget.directURL(from: target),
              let host = url.host else {
            return "Direct Agent"
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}

extension AppViewModel {
    /// True when the local transcript ends with a user message the hosted
    /// snapshot does not contain — the client is ahead (e.g. a second message
    /// sent before the running turn's snapshot was taken), so overwriting the
    /// transcript now would drop it. Scoped to the trailing user message so a
    /// server-reworded assistant reply still reconciles, and it self-resolves
    /// once the hosted snapshot includes that message.
    static func hasLocalOnlyTrailingUserMessage(
        local: [ChatMessage],
        projected: [ChatMessage]
    ) -> Bool {
        guard let lastLocal = local.last(where: {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), lastLocal.role == .user,
        let signature = transcriptSignature([lastLocal]).first else {
            return false
        }
        return !transcriptSignature(projected).contains(signature)
    }

    private static func transcriptSignature(
        _ messages: [ChatMessage]
    ) -> [String] {
        messages.compactMap { message in
            let content = message.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !content.isEmpty else { return nil }
            return "\(message.role.rawValue)\u{0}\(content)"
        }
    }
}

/// Hosted history owns message text, while the native client owns metadata
/// that the history endpoint does not return. Match exact messages first, then
/// align remaining messages by role from the end so the latest generated file
/// stays attached to the latest Agent response.
func preservingLocalMetadata(
    from localMessages: [ChatMessage],
    in projectedMessages: [ChatMessage]
) -> [ChatMessage] {
    var merged = projectedMessages
    var unmatchedLocalIndices = Array(localMessages.indices)
    var localIndexByProjectedIndex: [Int: Int] = [:]

    for projectedIndex in merged.indices {
        let projected = merged[projectedIndex]
        guard let unmatchedPosition = unmatchedLocalIndices.firstIndex(
            where: { localIndex in
                let local = localMessages[localIndex]
                return local.role == projected.role
                    && local.content.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) == projected.content.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
            }
        ) else {
            continue
        }
        localIndexByProjectedIndex[projectedIndex] =
            unmatchedLocalIndices.remove(at: unmatchedPosition)
    }

    for projectedIndex in merged.indices.reversed()
    where localIndexByProjectedIndex[projectedIndex] == nil {
        let projected = merged[projectedIndex]
        guard let unmatchedPosition = unmatchedLocalIndices.lastIndex(
            where: { localMessages[$0].role == projected.role }
        ) else {
            continue
        }
        localIndexByProjectedIndex[projectedIndex] =
            unmatchedLocalIndices.remove(at: unmatchedPosition)
    }

    for (projectedIndex, localIndex) in localIndexByProjectedIndex {
        let local = localMessages[localIndex]
        merged[projectedIndex].id = local.id
        merged[projectedIndex].attachments =
            local.attachments ?? merged[projectedIndex].attachments
        merged[projectedIndex].imageURL =
            local.imageURL ?? merged[projectedIndex].imageURL
        merged[projectedIndex].usage =
            local.usage ?? merged[projectedIndex].usage
        merged[projectedIndex].replyToMessageID =
            local.replyToMessageID ?? merged[projectedIndex].replyToMessageID
        merged[projectedIndex].artifacts =
            local.artifacts ?? merged[projectedIndex].artifacts
        merged[projectedIndex].artifactWarnings =
            local.artifactWarnings ?? merged[projectedIndex].artifactWarnings
    }

    // Preserve trailing local messages the hosted snapshot has not caught up to
    // yet — e.g. a second message sent so fast the running turn's snapshot
    // predates it. Only messages after the last matched local message are kept,
    // so anything the server deliberately dropped earlier is not resurrected.
    if let lastMatchedLocalIndex = localIndexByProjectedIndex.values.max() {
        for localIndex in unmatchedLocalIndices.sorted()
        where localIndex > lastMatchedLocalIndex {
            merged.append(localMessages[localIndex])
        }
    }

    return merged
}
