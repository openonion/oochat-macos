import XCTest
@testable import ConnectOnionMacClient

final class ConnectOnionServiceConnectionTests: XCTestCase {
    @MainActor
    func testRetiredDirectAPIConfigurationClearsEveryPublishedConnectionField() async {
        let service = ConnectOnionService()
        service.isConnected = true
        service.hostedAgentStatus = "Connected"
        service.hostedAgentStatusDetail = "Direct endpoint"
        service.isHostedAgentStatusLive = true
        service.hostedFilesystemEnabled = true
        service.hostedWorkspacePath = "/workspace"
        service.hostedFileInputCapabilities = .protocolDefault
        service.hostedExecutionModesEnabled = true
        service.desiredExecutionMode = .accept
        service.confirmedExecutionMode = .accept
        service.isAgentRequestActive = true

        service.connect(
            with: GeneralAgentConfiguration(
                name: "Legacy API Agent",
                connectionType: .legacyByApi,
                addressConfiguration: nil
            )
        )

        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(
            service.connectionError,
            "Direct API configurations are no longer supported. Connect to a hosted ConnectOnion agent instead."
        )
        XCTAssertEqual(service.hostedAgentStatus, "Disconnected")
        XCTAssertNil(service.hostedAgentStatusDetail)
        XCTAssertFalse(service.isHostedAgentStatusLive)
        XCTAssertFalse(service.hostedFilesystemEnabled)
        XCTAssertNil(service.hostedWorkspacePath)
        XCTAssertNil(service.hostedFileInputCapabilities)
        XCTAssertFalse(service.hostedExecutionModesEnabled)
        XCTAssertEqual(service.desiredExecutionMode, .safe)
        XCTAssertEqual(service.confirmedExecutionMode, .safe)
        XCTAssertFalse(service.isAgentRequestActive)
    }

    @MainActor
    func testValidHostedAddressEntersResolvingStateUntilProbeCompletes() async {
        let service = ConnectOnionService(conversationID: UUID())
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "http://127.0.0.1:1"
            )
        )

        service.connect(with: configuration)

        XCTAssertTrue(service.isConnected)
        XCTAssertNil(service.connectionError)
        XCTAssertEqual(service.hostedAgentStatus, "Resolving")
        XCTAssertNil(service.hostedAgentStatusDetail)
        XCTAssertFalse(service.isHostedAgentStatusLive)
        XCTAssertFalse(service.hostedFilesystemEnabled)
        XCTAssertTrue(service.hostedExecutionModesEnabled)
        XCTAssertEqual(service.desiredExecutionMode, .safe)
        XCTAssertEqual(service.confirmedExecutionMode, .safe)

        service.disconnect()
    }

    @MainActor
    func testDisconnectIsIdempotentAndResetsRequestState() async {
        let service = ConnectOnionService()
        service.isConnected = true
        service.hostedAgentStatus = "Connected"
        service.isAgentRequestActive = true

        service.disconnect()
        service.disconnect()

        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isAgentRequestActive)
        XCTAssertEqual(service.hostedAgentStatus, "Disconnected")
        XCTAssertNil(service.hostedAgentStatusDetail)
        XCTAssertNil(service.connectionError)
        XCTAssertEqual(service.desiredExecutionMode, .safe)
        XCTAssertEqual(service.confirmedExecutionMode, .safe)
    }

    @MainActor
    func testHTTPURLValidationAcceptsSupportedVariants() async {
        let localURL = ConnectOnionService.validatedHTTPURL(
            from: "  HTTP://localhost:8080/path?q=1  "
        )
        XCTAssertEqual(localURL?.scheme?.lowercased(), "http")
        XCTAssertEqual(localURL?.host, "localhost")
        XCTAssertEqual(localURL?.port, 8080)
        XCTAssertEqual(localURL?.path, "/path")
        XCTAssertEqual(localURL?.query, "q=1")
        XCTAssertEqual(
            ConnectOnionService.validatedHTTPURL(
                from: "https://127.0.0.1:8000"
            )?.host,
            "127.0.0.1"
        )
    }

    @MainActor
    func testHTTPURLValidationRejectsUnsupportedOrIncompleteValues() async {
        for value in [
            "ws://example.com/socket",
            "ftp://example.com/file",
            "https://",
            "/relative/path",
            "   "
        ] {
            XCTAssertNil(
                ConnectOnionService.validatedHTTPURL(from: value),
                "Expected invalid URL: \(value)"
            )
        }
    }

}
