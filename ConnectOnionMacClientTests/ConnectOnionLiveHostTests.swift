import Foundation
import XCTest
@testable import ConnectOnionMacClient

final class ConnectOnionLiveHostTests: XCTestCase {
    func testUserHostedAgentRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawTarget = environment["CONNECTONION_E2E_TARGET"],
              !rawTarget.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            throw XCTSkip(
                "Set CONNECTONION_E2E_TARGET to a live 0x address or Direct URL."
            )
        }
        let target = try XCTUnwrap(
            ConnectOnionAgentTarget.normalized(rawTarget),
            "CONNECTONION_E2E_TARGET must be a 0x address or HTTP(S) Direct URL."
        )
        let identityStore = makeIdentityStore(environment: environment)
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: target,
            conversationID: nil,
            identityStore: identityStore
        )

        let endpoint = try await client.probe()
        try assertExpectedRoute(
            environment["CONNECTONION_E2E_EXPECT_ROUTE"],
            endpoint: endpoint
        )

        let expectedText = nonemptyValue(
            environment["CONNECTONION_E2E_EXPECTED_TEXT"]
        ) ?? "CONNECTONION_E2E_OK"
        let prompt = nonemptyValue(
            environment["CONNECTONION_E2E_PROMPT"]
        ) ?? "Reply with exactly \(expectedText)."
        let timeoutSeconds = timeoutSeconds(
            environment["CONNECTONION_E2E_TIMEOUT_SECONDS"]
        )

        let response: String
        do {
            response = try await send(
                prompt: prompt,
                through: client,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()

        XCTAssertTrue(
            response.localizedCaseInsensitiveContains(expectedText),
            "The live Host response did not contain '\(expectedText)': \(response)"
        )
    }

    private func makeIdentityStore(
        environment: [String: String]
    ) -> ConnectOnionIdentityStore {
        if environment["CONNECTONION_E2E_USE_SHARED_IDENTITY"] == "1" {
            return .shared
        }
        let identityURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionLiveHostTests-\(UUID().uuidString)")
            .appendingPathComponent("identity")
        return ConnectOnionIdentityStore(identityFileURL: identityURL)
    }

    private func assertExpectedRoute(
        _ rawValue: String?,
        endpoint: ConnectOnionResolvedEndpoint
    ) throws {
        guard let route = nonemptyValue(rawValue)?.lowercased() else {
            return
        }
        switch route {
        case "direct":
            guard endpoint.isDirect else {
                throw LiveHostTestError.routeMismatch(
                    expected: "direct",
                    actual: "relay"
                )
            }
        case "relay":
            guard !endpoint.isDirect else {
                throw LiveHostTestError.routeMismatch(
                    expected: "relay",
                    actual: "direct"
                )
            }
        default:
            throw LiveHostTestError.invalidExpectedRoute(route)
        }
    }

    private func timeoutSeconds(_ rawValue: String?) -> UInt64 {
        guard let rawValue,
              let value = UInt64(rawValue),
              (1...600).contains(value) else {
            return 120
        }
        return value
    }

    private func nonemptyValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func send(
        prompt: String,
        through client: ConnectOnionRemoteAgentClient,
        timeoutSeconds: UInt64
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await client.send(
                    prompt: prompt,
                    onUpdate: { _ in },
                    onEvent: { _ in }
                )
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: timeoutSeconds * 1_000_000_000
                )
                await client.disconnect()
                throw LiveHostTestError.timedOut(seconds: timeoutSeconds)
            }

            defer { group.cancelAll() }
            guard let response = try await group.next() else {
                throw LiveHostTestError.missingResponse
            }
            return response
        }
    }
}

private enum LiveHostTestError: LocalizedError {
    case invalidExpectedRoute(String)
    case missingResponse
    case routeMismatch(expected: String, actual: String)
    case timedOut(seconds: UInt64)

    var errorDescription: String? {
        switch self {
        case .invalidExpectedRoute(let route):
            return "CONNECTONION_E2E_EXPECT_ROUTE must be direct or relay, not \(route)."
        case .missingResponse:
            return "The live Host test finished without a response."
        case .routeMismatch(let expected, let actual):
            return "Expected a \(expected) Host route, but resolved \(actual)."
        case .timedOut(let seconds):
            return "The live Host did not respond within \(seconds) seconds."
        }
    }
}
