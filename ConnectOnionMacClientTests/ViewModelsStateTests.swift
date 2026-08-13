import AppKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

extension ViewModelsTests {
    @MainActor
    func testStoredStateReloadsAndLegacyConnectionMessagesAreFiltered() async throws {
        let storage = makeIsolatedDefaults()
        let configuration = makeHostedConfiguration()
        let session = ChatSession(agentConfigId: configuration.id, title: "Stored")
        let visibleMessage = ChatMessage(
            sessionId: session.id,
            role: .user,
            content: "Visible"
        )
        let legacyMessage = ChatMessage(
            sessionId: session.id,
            role: .system,
            content: "Connected to Old Agent"
        )
        let legacyAcknowledgement = ChatMessage(
            sessionId: session.id,
            role: .agent,
            content: "Understood, I'll handle that."
        )
        let finalResponse = ChatMessage(
            sessionId: session.id,
            role: .agent,
            content: "Final response"
        )
        let item = ExecutionItem.intent(
            IntentExecutionItem(id: "stored", status: .understood)
        )
        let run = ExecutionRun(sessionId: session.id)
        let original = AppViewModel(storage: storage)
        original.configurations = [configuration]
        original.sessions = [session]
        original.messages = [
            visibleMessage,
            legacyAcknowledgement,
            finalResponse,
            legacyMessage
        ]
        original.setExecutionItems([item], for: session.id)
        original.setExecutionRuns([run], for: session.id)

        let reloaded = AppViewModel(storage: storage)

        XCTAssertEqual(reloaded.configurations, [configuration])
        XCTAssertEqual(reloaded.sessions.count, 1)
        XCTAssertEqual(reloaded.sessions[0].agentConfigId, session.agentConfigId)
        XCTAssertEqual(reloaded.sessions[0].title, session.title)
        XCTAssertEqual(
            reloaded.sessions[0].agentIdentity,
            configuration.agentIdentity
        )
        XCTAssertEqual(reloaded.messages, [visibleMessage, finalResponse])
        XCTAssertEqual(reloaded.findExecutionItems(for: session.id), [item])
        XCTAssertEqual(reloaded.findExecutionRuns(for: session.id), [run])
    }

    @MainActor
    func testInvalidAddressConfigurationProducesInvalidStatusState() async {
        let viewModel = makeViewModel()
        let invalidConfiguration = GeneralAgentConfiguration(
            name: "Missing Address",
            connectionType: .byAddress,
            addressConfiguration: nil
        )
        viewModel.configurations = [invalidConfiguration]

        await viewModel.refreshAgentStatusAndWait(for: invalidConfiguration)

        XCTAssertEqual(
            viewModel.agentConnectionSnapshots[invalidConfiguration.id],
            AgentConnectionSnapshot(
                state: .invalid,
                route: nil,
                remoteName: nil,
                tools: [],
                detail: "Missing agent target"
            )
        )

    }

    @MainActor
    func testLegacyDirectAPIConfigurationsAreRemovedFromStorage() async throws {
        let storage = makeIsolatedDefaults()
        let legacyID = UUID()
        let legacyPayload: [[String: Any]] = [[
            "id": legacyID.uuidString,
            "name": "Legacy API Agent",
            "connectionType": "byApi",
            "apiConfiguration": [
                "apiKey": "legacy-secret",
                "baseURL": "https://api.example.com/v1",
                "model": "legacy-model",
                "systemPrompt": "legacy"
            ]
        ]]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload)
        storage.set(legacyData, forKey: "saved_configurations")

        let viewModel = AppViewModel(
            storage: storage,
            localAgentDefinitions: []
        )

        XCTAssertTrue(viewModel.configurations.isEmpty)
        let persisted = try XCTUnwrap(storage.data(forKey: "saved_configurations"))
        let persistedJSON = try XCTUnwrap(String(data: persisted, encoding: .utf8))
        XCTAssertFalse(persistedJSON.contains("byApi"))
        XCTAssertFalse(persistedJSON.contains("legacy-secret"))
    }

    @MainActor
    func testChatViewModelPresentsHostedConnectionAndAttachmentState() async {
        let appViewModel = makeViewModel()
        let configuration = makeHostedConfiguration()
        let session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        let service = ConnectOnionService(conversationID: session.id)
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: service,
            appViewModel: appViewModel
        )

        XCTAssertFalse(viewModel.isConfigurationConnected)
        XCTAssertTrue(viewModel.canAttachFiles)
        XCTAssertEqual(
            viewModel.fileInputHelpText,
            "Attach up to 10 files, 10 MB each"
        )
        XCTAssertTrue(viewModel.showsExecutionModeSelector)
        XCTAssertFalse(viewModel.canSendMessage)

        viewModel.inputText = "  Ready to send  "
        XCTAssertTrue(viewModel.canSendMessage)

        service.isAgentRequestActive = true
        XCTAssertTrue(viewModel.canInterruptAgent)
        XCTAssertTrue(viewModel.canSendMessage)
    }

    @MainActor
    func testHostedChatAllowsRuntimeInputWhileAgentIsRunning() async {
        let appViewModel = makeViewModel()
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "ab", count: 32)
            )
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        let service = ConnectOnionService(conversationID: session.id)
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: service,
            appViewModel: appViewModel
        )

        service.isAgentRequestActive = true
        viewModel.inputText = "Focus on the authentication module"

        XCTAssertTrue(viewModel.canInterruptAgent)
        XCTAssertTrue(viewModel.canSendMessage)
    }

    @MainActor
    func testInterruptImmediatelyStopsVisibleRunAndSuppressesFinalOutput() async {
        let appViewModel = makeViewModel()
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "ab", count: 32)
            )
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        let service = ConnectOnionService(conversationID: session.id)
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: service,
            appViewModel: appViewModel
        )

        viewModel.inputText = "Write a long answer"
        viewModel.sendMessage()
        service.isAgentRequestActive = true
        viewModel.handleIncomingEvent(
            .executionItem(.thinking(ThinkingExecutionItem(
                id: "thinking",
                status: .running,
                model: nil,
                durationMS: nil,
                usage: nil,
                contextPercent: nil
            )))
        )

        viewModel.interruptAgent()

        XCTAssertTrue(viewModel.isDiscardingInterruptedEvents)
        XCTAssertEqual(viewModel.executionRuns.last?.status, .done)
        XCTAssertEqual(viewModel.messages.last?.status, .sent)

        viewModel.handleIncomingEvent(
            .executionItem(.toolCall(ToolCallExecutionItem(
                id: "late-tool",
                name: "write",
                args: [:],
                status: .running,
                result: nil,
                timingMS: nil
            )))
        )
        viewModel.handleIncomingEvent(.output("This answer arrived too late"))

        XCTAssertTrue(viewModel.isDiscardingInterruptedEvents)
        XCTAssertFalse(viewModel.executionItems.contains { $0.id == "late-tool" })
        XCTAssertFalse(viewModel.messages.contains { $0.content == "This answer arrived too late" })
    }

    @MainActor
    func testInterruptTerminalEventKeepsDiscardingLateOutputAndErrors() async {
        let appViewModel = makeViewModel()
        let configuration = makeHostedConfiguration()
        let session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        let service = ConnectOnionService(conversationID: session.id)
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: service,
            appViewModel: appViewModel
        )
        service.isAgentRequestActive = true

        viewModel.interruptAgent()
        viewModel.handleIncomingEvent(.interrupted)
        viewModel.handleIncomingEvent(.output("late output"))
        viewModel.handleIncomingEvent(.error("late error"))

        XCTAssertTrue(viewModel.isDiscardingInterruptedEvents)
        XCTAssertFalse(viewModel.messages.contains { $0.content == "late output" })
        XCTAssertFalse(viewModel.messages.contains { $0.content.hasPrefix("Error:") })
    }

    @MainActor
    func testNewRequestReleasesInterruptedEventFence() async {
        let appViewModel = makeViewModel()
        let configuration = makeHostedConfiguration()
        let session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        let service = ConnectOnionService(conversationID: session.id)
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: service,
            appViewModel: appViewModel
        )
        service.isAgentRequestActive = true

        viewModel.interruptAgent()
        viewModel.handleIncomingEvent(.interrupted)
        XCTAssertTrue(viewModel.isDiscardingInterruptedEvents)

        service.isAgentRequestActive = false
        viewModel.inputText = "Start over"
        viewModel.sendMessage()

        XCTAssertFalse(viewModel.isDiscardingInterruptedEvents)
    }

    @MainActor
    func testChatViewModelErrorMarksOutstandingMessagesAndPersistsResponse() async {
        let appViewModel = makeViewModel()
        let configuration = makeHostedConfiguration()
        let session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        var message = ChatMessage(
            sessionId: session.id,
            role: .user,
            content: "Pending"
        )
        message.status = .sending
        appViewModel.messages = [message]
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: appViewModel
        )

        viewModel.handleIncomingEvent(.error("Request failed"))

        XCTAssertEqual(viewModel.messages[0].status, .error)
        XCTAssertEqual(appViewModel.messages[0].status, .error)
        XCTAssertEqual(viewModel.messages.last?.role, .agent)
        XCTAssertEqual(viewModel.messages.last?.content, "Error: Request failed")
        XCTAssertEqual(appViewModel.messages.last, viewModel.messages.last)
        XCTAssertEqual(viewModel.interactionError, "Request failed")
    }

    @MainActor
    func testBalanceViewModelLoadsBalance() async {
        let provider = StubDockerAccountProvider()
        provider.statusOutput = "Balance: $12.50"
        let service = WalletService(accountProvider: provider)
        let viewModel = BalanceViewModel(service: service)

        await viewModel.fetchBalance()

        guard case .loaded(let balance) = viewModel.state else {
            return XCTFail("Expected a loaded balance")
        }
        XCTAssertEqual(balance, Decimal(string: "12.50"))
    }

    @MainActor
    func testBalanceDisplayUsesTwoDecimalPlaces() {
        guard let fractionalBalance = Decimal(string: "4.2250"),
              let groupedBalance = Decimal(string: "1234.5678") else {
            return XCTFail("Expected test decimal literals to parse")
        }

        XCTAssertEqual(
            BalanceAndAddressView.formattedBalance(fractionalBalance),
            "4.23"
        )
        XCTAssertEqual(
            BalanceAndAddressView.formattedBalance(groupedBalance),
            "1,234.57"
        )
    }

    @MainActor
    func testBalanceViewModelReportsFailureAndHidesRecoverySeed() async {
        let provider = StubDockerAccountProvider()
        provider.statusError = DockerRuntimeError.dockerUnavailable
        let service = WalletService(accountProvider: provider)
        let viewModel = BalanceViewModel(service: service)
        viewModel.isShowingRecoverySeed = true

        await viewModel.fetchBalance()
        viewModel.hideRecoverySeed()

        guard case .error(let message) = viewModel.state else {
            return XCTFail("Expected an error state")
        }
        XCTAssertEqual(message, WalletServiceError.commandFailed.localizedDescription)
        XCTAssertFalse(viewModel.isShowingRecoverySeed)
    }

    @MainActor
    func testReconcileReattachesOrphanedSessionByAgentIdentity() async {
        let viewModel = makeViewModel()
        let address = "0x" + String(repeating: "ab", count: 32)
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        viewModel.configurations = [configuration]

        let orphan = ChatSession(
            agentConfigId: UUID(),
            agentIdentity: ConnectOnionAgentTarget.normalized(address),
            title: "Lost chat"
        )
        viewModel.sessions = [orphan]

        viewModel.reconcileSessions()

        XCTAssertEqual(viewModel.sessions[0].agentConfigId, configuration.id)
        XCTAssertTrue(viewModel.orphanedSessions.isEmpty)
    }

    @MainActor
    func testReconcileCollectsUnrecoverableSessionsAsOrphans() async {
        let viewModel = makeViewModel()
        viewModel.configurations = []

        let orphan = ChatSession(
            agentConfigId: UUID(),
            agentIdentity: nil,
            title: "No anchor"
        )
        viewModel.sessions = [orphan]

        viewModel.reconcileSessions()

        XCTAssertEqual(viewModel.orphanedSessions.map(\.id), [orphan.id])
    }

    @MainActor
    func testReconcileBackfillsIdentityOnAttachedSessions() async {
        let viewModel = makeViewModel()
        let address = "0x" + String(repeating: "cd", count: 32)
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        viewModel.configurations = [configuration]

        let legacy = ChatSession(
            agentConfigId: configuration.id,
            agentIdentity: nil,
            title: "Old chat"
        )
        viewModel.sessions = [legacy]

        viewModel.reconcileSessions()

        XCTAssertEqual(
            viewModel.sessions[0].agentIdentity,
            ConnectOnionAgentTarget.normalized(address)
        )
        XCTAssertTrue(viewModel.orphanedSessions.isEmpty)
    }

    @MainActor
    func testSaveAgentReusesConfigurationForSameIdentity() async {
        let viewModel = makeViewModel()
        let address = "0x" + String(repeating: "ef", count: 32)
        let existing = GeneralAgentConfiguration(
            name: "Original",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        viewModel.configurations = [existing]

        let duplicate = GeneralAgentConfiguration(
            name: "Renamed",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        viewModel.saveAgent(duplicate)

        XCTAssertEqual(viewModel.configurations.count, 1)
        XCTAssertEqual(viewModel.configurations[0].id, existing.id)
        XCTAssertEqual(viewModel.configurations[0].name, "Renamed")
        let newSession = viewModel.sessions.last
        XCTAssertEqual(newSession?.agentConfigId, existing.id)
        XCTAssertEqual(
            newSession?.agentIdentity,
            ConnectOnionAgentTarget.normalized(address)
        )
    }

    @MainActor
    func testDiscardOrphanedSessionsRemovesTheirHistory() async {
        let viewModel = makeViewModel()
        let address = "0x" + String(repeating: "12", count: 32)
        let orphan = ChatSession(
            agentConfigId: UUID(),
            agentIdentity: nil,
            title: "Lost chat"
        )
        viewModel.configurations = [
            GeneralAgentConfiguration(
                name: "Hosted Agent",
                connectionType: .byAddress,
                addressConfiguration: AgentAddressConfiguration(agentAddress: address)
            )
        ]
        viewModel.sessions = [orphan]
        viewModel.messages = [
            ChatMessage(sessionId: orphan.id, role: .user, content: "hello")
        ]

        viewModel.reconcileSessions()
        XCTAssertEqual(viewModel.orphanedSessions.count, 1)

        viewModel.discardOrphanedSessions()

        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.orphanedSessions.isEmpty)
    }

    @MainActor
    func makeViewModel() -> AppViewModel {
        AppViewModel(
            storage: makeIsolatedDefaults(),
            localAgentDefinitions: []
        )
    }

    @MainActor
    func makeHostedConfiguration() -> GeneralAgentConfiguration {
        GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "ab", count: 32)
            )
        )
    }

    func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "ViewModelsTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to create isolated UserDefaults suite")
        }
        storage.removePersistentDomain(forName: suiteName)
        return storage
    }

    private func message(
        _ role: MessageRole,
        _ content: String,
        in sessionID: UUID
    ) -> ChatMessage {
        ChatMessage(sessionId: sessionID, role: role, content: content)
    }

    // A: merging a hosted snapshot must not drop a second message the client
    // sent so fast the running turn's snapshot predates it.
    @MainActor
    func testHostedMergePreservesATrailingLocalOnlyMessage() {
        let id = UUID()
        let projected = [message(.user, "first", in: id), message(.agent, "reply", in: id)]
        let local = projected + [message(.user, "second", in: id)]

        let merged = preservingLocalMetadata(from: local, in: projected)

        XCTAssertEqual(
            merged.map(\.content),
            ["first", "reply", "second"],
            "A trailing local message the snapshot lacks must survive the merge."
        )
    }

    // A: a non-trailing local message the server dropped must not be resurrected.
    @MainActor
    func testHostedMergeDoesNotResurrectAnOlderRemovedMessage() {
        let id = UUID()
        let local = [
            message(.user, "removed", in: id),
            message(.user, "first", in: id),
            message(.agent, "reply", in: id)
        ]
        let projected = [message(.user, "first", in: id), message(.agent, "reply", in: id)]

        let merged = preservingLocalMetadata(from: local, in: projected)

        XCTAssertEqual(merged.map(\.content), ["first", "reply"])
    }

    // C: the overwrite guard treats a trailing local-only user message as
    // "client is ahead", but still reconciles a server-reworded assistant reply.
    @MainActor
    func testTrailingLocalOnlyUserMessageGuard() {
        let id = UUID()
        let projected = [message(.user, "first", in: id), message(.agent, "reply", in: id)]
        let ahead = projected + [message(.user, "second", in: id)]

        XCTAssertTrue(
            AppViewModel.hasLocalOnlyTrailingUserMessage(local: ahead, projected: projected),
            "A trailing user message the snapshot lacks means the client is ahead."
        )
        XCTAssertFalse(
            AppViewModel.hasLocalOnlyTrailingUserMessage(local: ahead, projected: ahead),
            "Once the snapshot includes the message the guard releases."
        )
        let agentTail = projected + [message(.agent, "reworded", in: id)]
        XCTAssertFalse(
            AppViewModel.hasLocalOnlyTrailingUserMessage(local: agentTail, projected: projected),
            "A trailing assistant reply must still reconcile, not block the merge."
        )
    }
}
