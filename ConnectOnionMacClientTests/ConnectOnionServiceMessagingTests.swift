import Combine
import XCTest
@testable import ConnectOnionMacClient

final class ConnectOnionServiceMessagingTests: XCTestCase {
    @MainActor
    func testSendMessageRejectsRetiredDirectAPIConfiguration() async {
        let service = ConnectOnionService()
        let configuration = GeneralAgentConfiguration(
            name: "Legacy API Agent",
            connectionType: .legacyByApi,
            addressConfiguration: nil
        )
        let recorder = EventRecorder(service: service)

        await service.sendMessage(
            "Hello",
            localMessageID: UUID(),
            using: configuration
        )

        XCTAssertFalse(service.isConnected)
        let message =
            "Direct API configurations are no longer supported. Connect to a hosted ConnectOnion agent instead."
        XCTAssertEqual(service.connectionError, message)
        XCTAssertEqual(recorder.errors, [message])
    }

    @MainActor
    func testSendMessageReportsInvalidHostedTarget() async {
        let service = ConnectOnionService()
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "not-an-agent"
            )
        )
        let recorder = EventRecorder(service: service)

        await service.sendMessage(
            "Hello",
            localMessageID: UUID(),
            using: configuration
        )

        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(
            recorder.errors,
            ["Enter a valid ConnectOnion 0x address or HTTP(S) Direct URL"]
        )
    }
}

private final class EventRecorder {
    private(set) var errors: [String] = []
    private var cancellable: AnyCancellable?

    @MainActor
    init(service: ConnectOnionService) {
        cancellable = service.incomingEvents.sink { [weak self] event in
            guard case .error(let message) = event else { return }
            self?.errors.append(message)
        }
    }
}
