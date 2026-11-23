import Combine
import ConnectOnionKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

// 21.2: the page the host sends in DASHBOARD_SNAPSHOT, kept for the session.
extension ConnectOnionServiceTests {
    private func makeDashboardStub(
        address: String,
        eventsOnSend: [ConnectOnionTransportEvent] = []
    ) async throws -> StubRemoteAgentClient {
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: try XCTUnwrap(URL(string: "wss://agent.test/ws")),
            httpBaseURL: try XCTUnwrap(URL(string: "https://agent.test")),
            isDirect: true,
            info: nil
        )
        return await StubRemoteAgentClient(endpoint: endpoint, eventsOnSend: eventsOnSend)
    }

    private struct DashboardChat {
        let stub: StubRemoteAgentClient
        let service: ConnectOnionService
        let chat: ChatViewModel
        let configuration: GeneralAgentConfiguration
    }

    @MainActor
    private func makeDashboardChat(
        address: String,
        eventsOnSend: [ConnectOnionTransportEvent] = []
    ) async throws -> DashboardChat {
        let stub = try await makeDashboardStub(address: address, eventsOnSend: eventsOnSend)
        let service = ConnectOnionService(remoteAgentFactory: { _, _, _ in stub })
        let configuration = GeneralAgentConfiguration(
            name: "Dashboard Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let chat = ChatViewModel(
            session: ChatSession(agentConfigId: configuration.id, title: "Dashboard"),
            configuration: configuration,
            service: service,
            appViewModel: AppViewModel(storage: makeIsolatedDefaults())
        )

        return DashboardChat(stub: stub, service: service, chat: chat, configuration: configuration)
    }

    @MainActor
    func testTheViewModelHoldsTheSecondOfTwoSnapshots() async throws {
        let chat = try await makeDashboardChat(address: "0x" + String(repeating: "21", count: 32)).chat
        var pagesSeen: [OIPDashboard?] = []
        let cancellable = chat.$dashboard.sink { pagesSeen.append($0) }

        chat.handleIncomingEvent(.dashboard(OIPDashboard(html: "<p>one</p>")))
        chat.handleIncomingEvent(.dashboard(OIPDashboard(html: "<p>two</p>")))

        XCTAssertEqual(chat.dashboard, .page(html: "<p>two</p>"))
        XCTAssertEqual(pagesSeen, [nil, .page(html: "<p>one</p>"), .page(html: "<p>two</p>")])
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testAnIdenticalSnapshotChangesNothing() async throws {
        let chat = try await makeDashboardChat(address: "0x" + String(repeating: "22", count: 32)).chat
        var pagesSeen: [OIPDashboard?] = []
        let cancellable = chat.$dashboard.sink { pagesSeen.append($0) }

        for _ in 0..<4 {
            chat.handleIncomingEvent(.dashboard(OIPDashboard(html: "<p>same</p>")))
        }

        XCTAssertEqual(pagesSeen, [nil, .page(html: "<p>same</p>")], "four identical pages publish one change")
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testASnapshotSentOnReattachReplacesThePage() async throws {
        let fixture = try await makeDashboardChat(
            address: "0x" + String(repeating: "23", count: 32),
            eventsOnSend: [.dashboard(OIPDashboard(html: "<p>first</p>"))]
        )
        let stub = fixture.stub
        let service = fixture.service
        let chat = fixture.chat
        let configuration = fixture.configuration
        // Hand the service's events to the view model right away. The view model also listens through an async
        // stream, which a test cannot wait on reliably; equal pages are skipped, so receiving an event twice is harmless.
        let cancellable = service.incomingEvents.sink { chat.handleIncomingEvent($0) }

        service.connect(with: configuration)
        await waitUntil { service.isHostedAgentStatusLive }
        await service.sendMessage("Go", localMessageID: UUID(), using: configuration)
        XCTAssertEqual(chat.dashboard, .page(html: "<p>first</p>"))

        await stub.setPendingExecution(true)
        await stub.setEventsOnRecover([.dashboard(OIPDashboard(html: "<p>after reattach</p>"))])
        await service.retryRecovery()

        XCTAssertEqual(chat.dashboard, .page(html: "<p>after reattach</p>"))
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testAPageOverTheCapIsHeldAsTooLargeAndALaterSmallOneReplacesIt() async throws {
        let chat = try await makeDashboardChat(address: "0x" + String(repeating: "26", count: 32)).chat
        let huge = String(repeating: "a", count: OIPDashboard.clientCapBytes + 1)

        chat.handleIncomingEvent(.dashboard(OIPDashboard(html: huge)))
        XCTAssertEqual(chat.dashboard, .tooLarge(bytes: OIPDashboard.clientCapBytes + 1))

        chat.handleIncomingEvent(.dashboard(OIPDashboard(html: "<p>small</p>")))
        XCTAssertEqual(chat.dashboard, .page(html: "<p>small</p>"))
    }
}

extension ConnectOnionRemoteAgentTests {
    private func dashboardFrame(sessionID: String?, html: String = "<p>page</p>") -> [String: Any] {
        var frame: [String: Any] = ["type": "DASHBOARD_SNAPSHOT", "html": html]
        if let sessionID {
            frame["session_id"] = sessionID
        }
        return frame
    }

    func testSnapshotIsReadWithTheKitAndFilteredBySession() {
        let ours = ConnectOnionRemoteAgentClient.dashboardSnapshotEvent(
            from: dashboardFrame(sessionID: "session-1", html: "<p>mine</p>"),
            currentSessionID: "session-1"
        )
        guard case .dashboard(let page)? = ours else {
            return XCTFail("a snapshot for our own session must be taken")
        }
        XCTAssertEqual(page, .page(html: "<p>mine</p>"))

        XCTAssertNil(
            ConnectOnionRemoteAgentClient.dashboardSnapshotEvent(
                from: dashboardFrame(sessionID: "someone-else"),
                currentSessionID: "session-1"
            ),
            "a snapshot that names another session is ignored"
        )
        XCTAssertNotNil(
            ConnectOnionRemoteAgentClient.dashboardSnapshotEvent(
                from: dashboardFrame(sessionID: nil),
                currentSessionID: "session-1"
            ),
            "session_id is optional"
        )
        XCTAssertNotNil(
            ConnectOnionRemoteAgentClient.dashboardSnapshotEvent(
                from: dashboardFrame(sessionID: "session-1"),
                currentSessionID: nil
            ),
            "before CONNECTED names our session there is nothing to compare with"
        )
        XCTAssertNotNil(
            ConnectOnionRemoteAgentClient.dashboardSnapshotEvent(
                from: dashboardFrame(sessionID: nil, html: ""),
                currentSessionID: nil
            ),
            "an empty page is still a page"
        )
        XCTAssertNil(
            ConnectOnionRemoteAgentClient.dashboardSnapshotEvent(
                from: ["type": "DASHBOARD_SNAPSHOT"],
                currentSessionID: nil
            ),
            "a frame without html is not a snapshot"
        )
    }

    func testAFrameOverTheCapIsReadWholeAndComesBackTooLarge() {
        let huge = String(repeating: "a", count: OIPDashboard.clientCapBytes + 1)
        let event = ConnectOnionRemoteAgentClient.dashboardSnapshotEvent(
            from: dashboardFrame(sessionID: nil, html: huge),
            currentSessionID: nil
        )
        guard case .dashboard(let page)? = event else {
            return XCTFail("a big page is still a snapshot")
        }
        XCTAssertEqual(page, .tooLarge(bytes: OIPDashboard.clientCapBytes + 1))
    }

    func testSnapshotsOnTheSocketReachTheEventHandlerAndAnotherSessionsAreDropped() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let address = makeAddress("92")
        let socket = try ScriptedWebSocketTask(events: [
            [
                "type": "CONNECTED",
                "status": "new",
                "session_id": "session-1",
                "protocol": ["name": "oip", "version": "0.1", "min_version": "0.1", "max_version": "0.1"]
            ],
            dashboardFrame(sessionID: "session-1", html: "<p>mine</p>"),
            dashboardFrame(sessionID: "someone-else", html: "<p>theirs, and longer</p>"),
            ["type": "OUTPUT", "result": "done", "session": ["trace": []]]
        ])
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Live Agent", "address": address])
            )
        }
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()

        _ = try await client.send(prompt: "Run the task", onUpdate: { _ in }, onEvent: { await recorder.record($0) })

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.events, ["dashboard:11"], "only our own session's page, 11 bytes, got through")
    }
}
