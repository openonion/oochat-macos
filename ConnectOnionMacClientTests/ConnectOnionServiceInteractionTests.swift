import Combine
import XCTest
@testable import ConnectOnionMacClient

final class ConnectOnionServiceInteractionTests: XCTestCase {
    @MainActor
    func testHostedResponsesReportNotConnectedWithoutRemoteClient() async {
        let service = ConnectOnionService()
        let recorder = InteractionEventRecorder(service: service)

        await service.respondToAskUser("Answer")
        await service.respondToApproval(.approveOnce)
        await service.respondToPlanReview(.approve)
        await service.respondToULWCheckpoint(.returnToSafe)
        await service.submitInviteCode("invite-code")

        XCTAssertEqual(
            recorder.errors,
            Array(repeating: "Not connected", count: 5)
        )
    }

    @MainActor
    func testExecutionModeChangeIsIgnoredWhenFeatureIsDisabled() async {
        let service = ConnectOnionService()
        let recorder = InteractionEventRecorder(service: service)

        await service.setExecutionMode(.plan)

        XCTAssertEqual(service.desiredExecutionMode, .safe)
        XCTAssertEqual(service.confirmedExecutionMode, .safe)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    @MainActor
    func testExecutionModeRollsBackWhenRemoteClientIsUnavailable() async {
        let service = ConnectOnionService()
        service.hostedExecutionModesEnabled = true
        service.desiredExecutionMode = .safe
        let recorder = InteractionEventRecorder(service: service)

        await service.setExecutionMode(.accept)

        XCTAssertEqual(service.desiredExecutionMode, .safe)
        XCTAssertEqual(recorder.errors, ["Not connected"])
    }

    @MainActor
    func testRetryRecoveryReportsWhenNoHostedExecutionExists() async {
        let service = ConnectOnionService()
        let recorder = InteractionEventRecorder(service: service)

        await service.retryRecovery()

        XCTAssertFalse(service.isAgentRequestActive)
        XCTAssertEqual(
            recorder.errors,
            ["There is no hosted session waiting to be recovered"]
        )
    }

    @MainActor
    func testRetryRecoveryDoesNothingWhileRequestIsActive() async {
        let service = ConnectOnionService()
        service.isAgentRequestActive = true
        let recorder = InteractionEventRecorder(service: service)

        await service.retryRecovery()

        XCTAssertTrue(service.isAgentRequestActive)
        XCTAssertTrue(recorder.errors.isEmpty)
    }
}

private final class InteractionEventRecorder {
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
