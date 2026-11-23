import Combine
import CryptoKit
import XCTest
@testable import ConnectOnionMacClient

extension ConnectOnionServiceTests {
    func testDisconnectClearsPublishedConnectionState() async {
        await MainActor.run {
            let service = ConnectOnionService()
            service.isConnected = true
            service.connectionError = "Old error"
            service.hostedAgentStatus = "Connected"
            service.hostedAgentStatusDetail = "Working"
            service.isHostedAgentStatusLive = true
            service.hostedFilesystemEnabled = true
            service.hostedWorkspacePath = "/tmp/workspace"

            service.disconnect()

            XCTAssertFalse(service.isConnected)
            XCTAssertNil(service.connectionError)
            XCTAssertEqual(service.hostedAgentStatus, "Not Connected")
            XCTAssertNil(service.hostedAgentStatusDetail)
            XCTAssertFalse(service.isHostedAgentStatusLive)
            XCTAssertFalse(service.hostedFilesystemEnabled)
            XCTAssertNil(service.hostedWorkspacePath)
        }
    }

    @MainActor
    func testAppViewModelAddsNormalizedAddressAndRejectsDuplicate() async {
        let storage = makeIsolatedDefaults()
        let viewModel = AppViewModel(
            storage: storage,
            resolveAgentEndpoint: { _ in
                throw ConnectOnionRemoteError.agentOffline
            }
        )
        let uppercaseAddress = "0x" + String(repeating: "AB", count: 32)
        let normalizedAddress = "0x" + String(repeating: "ab", count: 32)

        let firstResult = viewModel.addAgent(uppercaseAddress)
        let duplicateResult = viewModel.addAgent(normalizedAddress)

        guard case .added(let configuration) = firstResult else {
            return XCTFail("Expected the first address to be added")
        }
        XCTAssertEqual(
            configuration.addressConfiguration?.agentAddress,
            normalizedAddress
        )
        XCTAssertEqual(viewModel.configurations, [configuration])
        XCTAssertEqual(duplicateResult, .duplicate)
        XCTAssertEqual(viewModel.addAgent("0x1234"), .invalid)
    }

    @MainActor
    func testAppViewModelAddsDirectURLAndRejectsCanonicalDuplicate() async {
        let viewModel = AppViewModel(
            storage: makeIsolatedDefaults(),
            localAgentDefinitions: [],
            resolveAgentEndpoint: { _ in
                throw ConnectOnionRemoteError.agentOffline
            }
        )

        let firstResult = viewModel.addAgent("  HTTP://LOCALHOST:8000/  ")
        let duplicateResult = viewModel.addAgent("http://localhost:8000")

        guard case .added(let configuration) = firstResult else {
            return XCTFail("Expected the Direct URL to be added")
        }
        XCTAssertEqual(configuration.name, "localhost:8000")
        XCTAssertEqual(
            configuration.addressConfiguration?.agentAddress,
            "http://localhost:8000"
        )
        XCTAssertEqual(viewModel.configurations, [configuration])
        XCTAssertEqual(duplicateResult, .duplicate)
    }

    @MainActor
    func testAppViewModelStoresDirectConnectionMetadata() async {
        let storage = makeIsolatedDefaults()
        let address = "0x" + String(repeating: "ab", count: 32)
        let info = ConnectOnionAgentInfo(
            name: "Workspace Agent",
            address: address,
            tools: ["read_file", "grep", "edit"],
            model: "co/gemini-2.5-pro",
            trust: "careful",
            version: "1.2.1",
            acceptedInputs: nil
        )
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: URL(string: "wss://agent.example/ws")!,
            httpBaseURL: URL(string: "https://agent.example")!,
            isDirect: true,
            info: info
        )
        let viewModel = AppViewModel(
            storage: storage,
            resolveAgentEndpoint: { _ in endpoint }
        )
        let configuration = GeneralAgentConfiguration(
            name: "Saved Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        viewModel.configurations = [configuration]

        await viewModel.refreshAgentStatusAndWait(for: configuration)

        XCTAssertTrue(viewModel.isAgentConnected(configuration))
        XCTAssertEqual(
            viewModel.agentConnectionSnapshots[configuration.id],
            AgentConnectionSnapshot(
                state: .online,
                route: .direct,
                remoteName: "Workspace Agent",
                tools: ["read_file", "grep", "edit"],
                detail: "Direct endpoint",
                model: "co/gemini-2.5-pro",
                trust: "careful",
                version: "1.2.1"
            )
        )
    }

    @MainActor
    func testAppViewModelStoresOfflineConnectionError() async {
        let storage = makeIsolatedDefaults()
        let address = "0x" + String(repeating: "cd", count: 32)
        let viewModel = AppViewModel(
            storage: storage,
            resolveAgentEndpoint: { _ in
                throw ConnectOnionRemoteError.agentOffline
            }
        )
        let configuration = GeneralAgentConfiguration(
            name: "Offline Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        viewModel.configurations = [configuration]

        await viewModel.refreshAgentStatusAndWait(for: configuration)

        XCTAssertFalse(viewModel.isAgentConnected(configuration))
        XCTAssertEqual(
            viewModel.agentConnectionSnapshots[configuration.id]?.state,
            .offline
        )
        XCTAssertEqual(
            viewModel.agentConnectionSnapshots[configuration.id]?.detail,
            "The ConnectOnion agent is offline"
        )
    }

    @MainActor
    func testDeletingAgentClearsRelatedDataAndConnectionSnapshot() async {
        let storage = makeIsolatedDefaults()
        let viewModel = AppViewModel(storage: storage)
        let configuration = GeneralAgentConfiguration(
            name: "Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "ef", count: 32)
            )
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        let message = ChatMessage(
            sessionId: session.id,
            role: .user,
            content: "Hello"
        )
        viewModel.configurations = [configuration]
        viewModel.sessions = [session]
        viewModel.messages = [message]
        viewModel.selection = .session(session.id)
        viewModel.setAgentConnected(configuration, isConnected: true)
        viewModel.agentConnectionSnapshots[configuration.id] = .checking

        viewModel.deleteConfiguration(configuration)

        XCTAssertTrue(viewModel.configurations.isEmpty)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isAgentConnected(configuration))
        XCTAssertNil(viewModel.agentConnectionSnapshots[configuration.id])
        XCTAssertNil(viewModel.selection)
    }

    @MainActor
    func testChatViewModelAddsAndRemovesLocalAttachment() throws {
        let storage = makeIsolatedDefaults()
        let appViewModel = AppViewModel(storage: storage)
        let configuration = GeneralAgentConfiguration(
            name: "Document Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "ef", count: 32)
            )
        )
        let session = ChatSession(
            agentConfigId: configuration.id,
            title: "New Chat"
        )
        let service = ConnectOnionService(conversationID: session.id)
        service.hostedFileInputCapabilities = .init(
            isSupported: true,
            maxFileSizeMB: 1,
            maxFilesPerRequest: 2
        )
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: service,
            appViewModel: appViewModel
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        try Data("hello attachment".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(viewModel.addAttachments(from: [fileURL]))
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)
        XCTAssertEqual(viewModel.pendingAttachments.first?.mimeType, "text/plain")
        XCTAssertTrue(viewModel.canSendMessage)

        if let attachment = viewModel.pendingAttachments.first {
            viewModel.removeAttachment(attachment)
        }
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)
        XCTAssertFalse(viewModel.canSendMessage)
    }

    @MainActor
    func testChatViewModelRejectsFilesWhenAgentDisablesUploads() throws {
        let storage = makeIsolatedDefaults()
        let appViewModel = AppViewModel(storage: storage)
        let configuration = GeneralAgentConfiguration(
            name: "Text Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "12", count: 32)
            )
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        let service = ConnectOnionService(conversationID: session.id)
        service.hostedFileInputCapabilities = .init(isSupported: false)
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: service,
            appViewModel: appViewModel
        )

        XCTAssertFalse(viewModel.canAttachFiles)
        XCTAssertFalse(
            viewModel.addAttachments(
                from: [FileManager.default.temporaryDirectory]
            )
        )
        XCTAssertEqual(
            viewModel.attachmentError,
            "This agent does not accept file uploads"
        )
    }

    @MainActor
    func testChatViewModelRetryResendsExactRequestAndAttachment() async throws {
        let storage = makeIsolatedDefaults()
        let appViewModel = AppViewModel(storage: storage)
        let address = "0x" + String(repeating: "45", count: 32)
        let fileCapabilities = ConnectOnionAgentInfo.FileInputCapabilities(
            isSupported: true,
            maxFileSizeMB: 10,
            maxFilesPerRequest: 2
        )
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: URL(string: "wss://agent.test/ws")!,
            httpBaseURL: URL(string: "https://agent.test")!,
            isDirect: true,
            info: ConnectOnionAgentInfo(
                name: "Main Agent",
                address: address,
                tools: ["read_file"],
                model: "co/test",
                trust: nil,
                version: "1",
                acceptedInputs: ConnectOnionAgentInfo.AcceptedInputs(
                    text: true,
                    images: true,
                    files: fileCapabilities
                )
            )
        )
        let remote = await StubRemoteAgentClient(endpoint: endpoint)
        let configuration = GeneralAgentConfiguration(
            name: "Main Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: address
            )
        )
        let session = ChatSession(
            agentConfigId: configuration.id,
            title: "Retry"
        )
        let service = ConnectOnionService(
            conversationID: session.id,
            remoteAgentFactory: { _, _, _ in remote }
        )
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: service,
            appViewModel: appViewModel
        )
        let attachment = ConnectOnionInputFile(
            name: "photo.jpeg",
            mimeType: "image/jpeg",
            data: Data("same-image-bytes".utf8)
        )
        viewModel.connectIfNeeded()
        await waitUntil {
            service.isHostedAgentStatusLive
        }
        viewModel.inputText = "Describe this image"
        viewModel.pendingAttachments = [attachment]

        viewModel.sendMessage()
        await waitUntil {
            let requests = await remote.sentRequestSnapshot()
            return requests.count == 1
                && !service.isAgentRequestActive
        }
        if !viewModel.messages.contains(where: { $0.role == .agent }) {
            viewModel.handleIncomingEvent(.output("First response"))
        }

        let firstUserMessage = try XCTUnwrap(
            viewModel.messages.first { $0.role == .user }
        )
        let firstAgentMessage = try XCTUnwrap(
            viewModel.messages.first { $0.role == .agent }
        )
        XCTAssertEqual(
            firstAgentMessage.replyToMessageID,
            firstUserMessage.id
        )
        XCTAssertTrue(viewModel.canRetryAgentMessage(firstAgentMessage))

        viewModel.retryAgentMessage(firstAgentMessage)
        await waitUntil {
            await remote.sentRequestSnapshot().count == 2
                && !service.isAgentRequestActive
        }

        let sentRequests = await remote.sentRequestSnapshot()
        XCTAssertEqual(sentRequests[0].prompt, sentRequests[1].prompt)
        XCTAssertEqual(sentRequests[0].prompt, "Describe this image")
        XCTAssertEqual(sentRequests[0].files, [attachment])
        XCTAssertEqual(sentRequests[1].files, [attachment])
        // Redone in place: still one message of yours, the same one.
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == .user }.map(\.id),
            [firstUserMessage.id]
        )
    }

    @MainActor
    func testChatViewModelDisablesRetryWhenHistoricalAttachmentDataIsUnavailable() {
        let storage = makeIsolatedDefaults()
        let appViewModel = AppViewModel(storage: storage)
        let configuration = GeneralAgentConfiguration(
            name: "Main Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "46", count: 32)
            )
        )
        let session = ChatSession(
            agentConfigId: configuration.id,
            title: "History"
        )
        let userMessage = ChatMessage(
            sessionId: session.id,
            role: .user,
            content: "Describe this image",
            attachments: [
                ChatAttachmentSummary(
                    name: "photo.jpeg",
                    byteCount: 572_000
                )
            ]
        )
        let agentMessage = ChatMessage(
            sessionId: session.id,
            role: .agent,
            content: "Historical response",
            replyToMessageID: userMessage.id
        )
        appViewModel.messages = [userMessage, agentMessage]
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: appViewModel
        )

        XCTAssertFalse(viewModel.canRetryAgentMessage(agentMessage))
    }

    @MainActor
    func testChatViewModelPersistsImagesInEventOrderBeforeOutput() throws {
        let storage = makeIsolatedDefaults()
        let appViewModel = AppViewModel(storage: storage)
        let configuration = GeneralAgentConfiguration(
            name: "External Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "34", count: 32)
            )
        )
        let session = ChatSession(
            agentConfigId: configuration.id,
            title: "External Agent Chat"
        )
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: appViewModel
        )

        viewModel.handleIncomingEvent(
            .agentImage("https://oo.openonion.ai/img/first.png")
        )
        viewModel.handleIncomingEvent(
            .agentImage("https://oo.openonion.ai/img/second.png")
        )
        viewModel.handleIncomingEvent(.output("Finished"))

        XCTAssertEqual(
            viewModel.messages.map(\.imageURL),
            [
                "https://oo.openonion.ai/img/first.png",
                "https://oo.openonion.ai/img/second.png",
                nil
            ]
        )
        XCTAssertEqual(viewModel.messages.map(\.content), ["", "", "Finished"])
        XCTAssertEqual(appViewModel.messages, viewModel.messages)

        let savedData = try XCTUnwrap(
            storage.data(forKey: "saved_messages")
        )
        let savedMessages = try JSONDecoder().decode(
            [ChatMessage].self,
            from: savedData
        )
        XCTAssertEqual(savedMessages, viewModel.messages)
    }

    @MainActor
    func testChatViewModelTracksPlanReviewAndULWCheckpoint() {
        let storage = makeIsolatedDefaults()
        let appViewModel = AppViewModel(storage: storage)
        let configuration = GeneralAgentConfiguration(
            name: "Mode Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "78", count: 32)
            )
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Modes")
        let service = ConnectOnionService(conversationID: session.id)
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: service,
            appViewModel: appViewModel
        )
        XCTAssertTrue(viewModel.showsExecutionModeSelector)

        service.desiredExecutionMode = .plan
        service.confirmedExecutionMode = .safe
        XCTAssertEqual(viewModel.desiredExecutionMode, .plan)
        XCTAssertEqual(viewModel.confirmedExecutionMode, .safe)
        XCTAssertTrue(viewModel.isExecutionModeChangePending, "pending while idle too, until mode_changed")
        service.confirmedExecutionMode = .plan
        XCTAssertFalse(viewModel.isExecutionModeChangePending)

        XCTAssertEqual(viewModel.offeredExecutionModes, [.safe, .plan], "accept hidden until the host lists it")
        service.availableExecutionModes = [.safe, .plan, .accept]
        XCTAssertEqual(viewModel.offeredExecutionModes, [.safe, .plan, .accept])

        service.acceptTurnsLeft = 3
        XCTAssertNil(viewModel.acceptTurnsLeft, "turns left only shows in accept")
        service.confirmedExecutionMode = .accept
        XCTAssertEqual(viewModel.acceptTurnsLeft, 3)

        let plan = ConnectOnionPlanReviewRequest(id: "plan-1", content: "# Plan")
        viewModel.handleIncomingEvent(.planReviewRequired(plan))
        XCTAssertEqual(viewModel.pendingInteraction, .planReview(plan))
        XCTAssertFalse(viewModel.canChangeExecutionMode)

        let checkpoint = ConnectOnionULWCheckpointRequest(
            id: "ulw-1",
            turnsUsed: 10,
            maxTurns: 10
        )
        viewModel.handleIncomingEvent(.ulwCheckpointRequired(checkpoint))
        XCTAssertEqual(viewModel.pendingInteraction, .ulwCheckpoint(checkpoint))
        XCTAssertFalse(viewModel.canChangeExecutionMode)
    }

    @MainActor
    func testChatViewModelPersistsLatestUsageWithAgentOutput() throws {
        let storage = makeIsolatedDefaults()
        let appViewModel = AppViewModel(storage: storage)
        let configuration = GeneralAgentConfiguration(
            name: "Usage Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "56", count: 32)
            )
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Usage")
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: appViewModel
        )
        let usage = ChatUsageSummary(
            tokenCount: 450_500,
            totalCost: 0.31,
            contextPercent: 35
        )

        viewModel.handleIncomingEvent(.usage(usage))
        XCTAssertNil(viewModel.latestUsage)
        viewModel.handleIncomingEvent(.output("Finished"))

        XCTAssertEqual(viewModel.latestUsage, usage)
        XCTAssertEqual(viewModel.messages.last?.usage, usage)

        let savedData = try XCTUnwrap(storage.data(forKey: "saved_messages"))
        let savedMessages = try JSONDecoder().decode(
            [ChatMessage].self,
            from: savedData
        )
        XCTAssertEqual(savedMessages.last?.usage, usage)
    }

    // MARK: - Redo the latest turn in place

    @MainActor
    func testRetryRedoesTheLatestTurnInPlace() async throws {
        let chat = try await makeChatWithOneTurn()
        let yourMessage = try XCTUnwrap(chat.viewModel.messages.first { $0.role == .user })
        let reply = try XCTUnwrap(chat.viewModel.messages.last { $0.role == .agent })

        chat.viewModel.retryAgentMessage(reply)
        await waitUntil {
            await chat.remote.sentRequestSnapshot().count == 2
                && !chat.service.isAgentRequestActive
        }
        // As in makeChatWithOneTurn: the stub's reply doesn't always reach the chat on its own.
        if !chat.viewModel.messages.contains(where: { $0.role == .agent }) {
            chat.viewModel.handleIncomingEvent(.output("Second response"))
        }

        let messages = chat.viewModel.messages
        XCTAssertEqual(messages.filter { $0.role == .user }.map(\.id), [yourMessage.id])
        XCTAssertEqual(messages.filter { $0.role == .agent }.count, 1)
        XCTAssertFalse(messages.contains { $0.id == reply.id }, "the old reply is gone")
        XCTAssertEqual(messages.first { $0.role == .user }?.status, .sent)
    }

    @MainActor
    func testEditRedoesYourLatestMessageInPlace() async throws {
        let chat = try await makeChatWithOneTurn()
        let yourMessage = try XCTUnwrap(chat.viewModel.messages.first { $0.role == .user })
        chat.viewModel.inputText = "Half-written draft"

        chat.viewModel.editLatestMessage(yourMessage, to: "  Hello again ")
        await waitUntil {
            await chat.remote.sentRequestSnapshot().count == 2
                && !chat.service.isAgentRequestActive
        }

        let sent = await chat.remote.sentRequestSnapshot()
        XCTAssertEqual(sent.last?.prompt, "Hello again")
        let yours = chat.viewModel.messages.filter { $0.role == .user }
        XCTAssertEqual(yours.map(\.id), [yourMessage.id])
        XCTAssertEqual(yours.map(\.content), ["Hello again"])
        XCTAssertEqual(chat.viewModel.inputText, "Half-written draft", "your draft is left alone")
    }

    // Every send opens a new socket with the saved session, so it must be cut back first.
    @MainActor
    func testRedoRewindsTheSessionBeforeSending() async throws {
        let chat = try await makeChatWithOneTurn()
        let reply = try XCTUnwrap(chat.viewModel.messages.last { $0.role == .agent })

        chat.viewModel.retryAgentMessage(reply)
        await waitUntil {
            await chat.remote.sentRequestSnapshot().count == 2
        }

        let calls = await chat.remote.callSnapshot()
        // The prompt goes with it, so the cut lands on that message and not one Core added.
        let rewind = try XCTUnwrap(calls.firstIndex(of: "rewindLatestTurn:Hello"))
        let resend = try XCTUnwrap(calls.lastIndex(of: "send:Hello:0"))
        XCTAssertLessThan(rewind, resend)
    }

    // A second click before the send has started must not rewind a second time.
    @MainActor
    func testADoubleClickedRetryRewindsOnce() async throws {
        let chat = try await makeChatWithOneTurn()
        let reply = try XCTUnwrap(chat.viewModel.messages.last { $0.role == .agent })

        chat.viewModel.retryAgentMessage(reply)
        XCTAssertFalse(chat.viewModel.canRetryAgentMessage(reply))
        chat.viewModel.retryAgentMessage(reply)
        await waitUntil {
            await chat.remote.sentRequestSnapshot().count == 2
        }

        let rewinds = await chat.remote.callSnapshot().filter { $0.hasPrefix("rewindLatestTurn") }
        XCTAssertEqual(rewinds.count, 1)
    }

    @MainActor
    func testNothingChangesWhenTheSessionCannotBeRewound() async throws {
        let chat = try await makeChatWithOneTurn(rewindSucceeds: false)
        let before = chat.viewModel.messages
        let reply = try XCTUnwrap(before.last { $0.role == .agent })

        chat.viewModel.retryAgentMessage(reply)
        await waitUntil {
            chat.viewModel.messages.last?.role == .system
        }

        XCTAssertEqual(Array(chat.viewModel.messages.dropLast()), before)
        let sentCount = await chat.remote.sentRequestSnapshot().count
        XCTAssertEqual(sentCount, 1)
    }

    private struct RedoChat {
        let viewModel: ChatViewModel
        let remote: StubRemoteAgentClient
        let service: ConnectOnionService
    }

    /// A chat where you sent "Hello" and the agent replied.
    @MainActor
    private func makeChatWithOneTurn(rewindSucceeds: Bool = true) async throws -> RedoChat {
        let appViewModel = AppViewModel(storage: makeIsolatedDefaults())
        let address = "0x" + String(repeating: "47", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: try XCTUnwrap(URL(string: "wss://agent.test/ws")),
            httpBaseURL: try XCTUnwrap(URL(string: "https://agent.test")),
            isDirect: true,
            info: nil
        )
        let remote = await StubRemoteAgentClient(endpoint: endpoint, rewindSucceeds: rewindSucceeds)
        let configuration = GeneralAgentConfiguration(
            name: "Main Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Redo")
        let service = ConnectOnionService(
            conversationID: session.id,
            remoteAgentFactory: { _, _, _ in remote }
        )
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: service,
            appViewModel: appViewModel
        )
        viewModel.connectIfNeeded()
        await waitUntil {
            service.isHostedAgentStatusLive
        }
        viewModel.inputText = "Hello"
        viewModel.sendMessage()
        await waitUntil {
            await remote.sentRequestSnapshot().count == 1
                && !service.isAgentRequestActive
        }
        if !viewModel.messages.contains(where: { $0.role == .agent }) {
            viewModel.handleIncomingEvent(.output("First response"))
        }
        return RedoChat(viewModel: viewModel, remote: remote, service: service)
    }

    // MARK: - Tool row states

    // The host announces the tool, then asks permission. Until you answer, it isn't running.
    @MainActor
    func testToolWaitingOnItsApprovalCardIsAwaitingApproval() {
        let chat = makeToolChat()

        chat.handleIncomingEvent(.executionItem(.toolCall(touchTool(status: .running))))
        chat.handleIncomingEvent(.approvalRequired(touchApproval))

        XCTAssertEqual(chat.toolAwaitingApprovalID, "tool-touch")
    }

    // The host reports a skipped tool as an error ("User rejected…"); you chose it, so it's Skipped.
    @MainActor
    func testSkippedToolStaysSkippedWhenTheHostReportsItAsAnError() {
        let chat = makeToolChat()
        chat.handleIncomingEvent(.executionItem(.toolCall(touchTool(status: .running))))
        chat.handleIncomingEvent(.approvalRequired(touchApproval))

        chat.submitApproval(.rejectSoft(feedback: ""))
        chat.handleIncomingEvent(.executionItem(.toolCall(
            touchTool(status: .error, result: "Error: User rejected tool 'bash'.")
        )))
        chat.handleIncomingEvent(.output("Skipped it."))

        XCTAssertEqual(toolStatuses(in: chat), [.skipped])
        XCTAssertNil(chat.toolAwaitingApprovalID)
    }

    // Stop while a tool runs: it never finishes, so it must not show as done.
    @MainActor
    func testToolRunningWhenYouStopIsInterrupted() {
        let chat = makeToolChat()
        chat.service.isAgentRequestActive = true
        chat.handleIncomingEvent(.executionItem(.toolCall(touchTool(status: .running))))

        chat.interruptAgent()

        XCTAssertEqual(toolStatuses(in: chat), [.interrupted])
    }

    // After you stop a batch, the host sends the rest of it no result, but the reply still comes.
    @MainActor
    func testToolsLeftWithoutAResultWhenTheReplyArrivesAreInterrupted() {
        let chat = makeToolChat()
        chat.handleIncomingEvent(.executionItem(.toolCall(touchTool(status: .running))))
        chat.handleIncomingEvent(.executionItem(.toolCall(ToolCallExecutionItem(
            id: "tool-echo",
            name: "bash",
            args: ["command": .string("echo hi")],
            status: .running,
            result: nil,
            timingMS: nil
        ))))
        chat.handleIncomingEvent(.executionItem(.toolCall(touchTool(status: .done, result: ""))))

        chat.handleIncomingEvent(.output("Stopped as you asked."))

        XCTAssertEqual(toolStatuses(in: chat), [.done, .interrupted])
    }

    private var touchApproval: ConnectOnionApprovalRequest {
        ConnectOnionApprovalRequest(
            id: "approval-touch",
            tool: "bash",
            arguments: .object(["command": .string("touch a.txt")]),
            description: nil,
            batchRemaining: []
        )
    }

    private func touchTool(status: ExecutionStatus, result: String? = nil) -> ToolCallExecutionItem {
        ToolCallExecutionItem(
            id: "tool-touch",
            name: "bash",
            args: ["command": .string("touch a.txt")],
            status: status,
            result: result,
            timingMS: nil
        )
    }

    @MainActor
    private func toolStatuses(in chat: ChatViewModel) -> [ExecutionStatus] {
        (chat.executionRuns.last?.items ?? []).compactMap { item in
            guard case .toolCall(let toolCall) = item else { return nil }
            return toolCall.status
        }
    }

    @MainActor
    private func makeToolChat() -> ChatViewModel {
        let configuration = GeneralAgentConfiguration(
            name: "Main Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "49", count: 32)
            )
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Tools")
        return ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: AppViewModel(storage: makeIsolatedDefaults())
        )
    }
}
