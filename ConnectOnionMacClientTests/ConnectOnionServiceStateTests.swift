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
            XCTAssertEqual(service.hostedAgentStatus, "Disconnected")
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
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == .user }.map(\.content),
            ["Describe this image", "Describe this image"]
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
        XCTAssertFalse(viewModel.isExecutionModeChangePending)

        service.isAgentRequestActive = true
        XCTAssertTrue(viewModel.isExecutionModeChangePending)
        service.isAgentRequestActive = false

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

}
