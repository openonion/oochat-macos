import ConnectOnionKit
import Foundation
import XCTest

@testable import ConnectOnionMacClient

/// Counts the sockets the client asks for and the backoff sleeps it takes between attempts.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var socketCount = 0
    private var sleepCount = 0

    var sockets: Int { lock.withLock { socketCount } }
    var sleeps: Int { lock.withLock { sleepCount } }

    func openedSocket() { lock.withLock { socketCount += 1 } }
    func slept() { lock.withLock { sleepCount += 1 } }
}

// 13.3: CONNECT adoption. Needs `ScriptedWebSocketTask`, `makeResolver`, `makeAddress`,
// `makeHTTPResponse` and `makeJSONData` from the existing test support.
extension ConnectOnionRemoteAgentTests {
    private func makeClient(
        conversationID: UUID,
        socket: ScriptedWebSocketTask,
        counter: AttemptCounter
    ) -> ConnectOnionRemoteAgentClient {
        let address = makeAddress("91")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Live Agent", "address": address])
            )
        }
        return ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in
                counter.openedSocket()
                return socket
            },
            sleep: { _ in counter.slept() }
        )
    }

    func testIncompatibleVersionFailsOnceAndNamesTheVersionNeeded() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let socket = try ScriptedWebSocketTask(events: [
            [
                "type": "ERROR",
                "code": -32010,
                "message": "Unsupported OIP protocol",
                "retryable": false,
                "protocol": [
                    "name": "oip",
                    "version": "9.9",
                    "min_version": "9.9",
                    "max_version": "9.9",
                    "websocket_path": "/ws"
                ]
            ]
        ])
        let counter = AttemptCounter()
        let client = makeClient(conversationID: conversationID, socket: socket, counter: counter)

        do {
            _ = try await client.send(prompt: "Run the task", onUpdate: { _ in }, onEvent: { _ in })
            XCTFail("-32010 must end the attempt with an error")
        } catch let error as ConnectOnionRemoteError {
            let incompatibility = try XCTUnwrap(error.incompatibility)
            XCTAssertEqual(incompatibility.neededVersion, "9.9")
            XCTAssertEqual(incompatibility.direction, .appTooOld)
            XCTAssertFalse(error.isRetryable)
            XCTAssertTrue(error.localizedDescription.contains("OIP 9.9"))
        }

        XCTAssertEqual(counter.sockets, 1, "one attempt, not four")
        XCTAssertEqual(counter.sleeps, 0, "no backoff before a second attempt")
        XCTAssertTrue(socket.wasCancelled, "the host leaves the socket open after its ERROR")
        let sentTypes = try socket.sentJSONObjects().compactMap { $0["type"] as? String }
        XCTAssertEqual(sentTypes, ["CONNECT"], "INPUT is never sent to an agent that refused CONNECT")
        let hasPending = await client.hasPendingExecution()
        XCTAssertFalse(hasPending, "recoverIfNeeded must not reconnect at the next launch")
    }

    func testConnectDeclaresTheOIPDescriptorAndSignedCommands() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let socket = try ScriptedWebSocketTask(events: [
            [
                "type": "CONNECTED",
                "status": "new",
                "session_id": "session-1",
                "protocol": ["name": "oip", "version": "0.1", "min_version": "0.1", "max_version": "0.1"]
            ],
            ["type": "OUTPUT", "result": "done", "session": ["trace": []]]
        ])
        let counter = AttemptCounter()
        let client = makeClient(conversationID: conversationID, socket: socket, counter: counter)

        let output = try await client.send(prompt: "Run the task", onUpdate: { _ in }, onEvent: { _ in })

        XCTAssertEqual(output, "done")
        XCTAssertEqual(counter.sockets, 1)
        let connect = try XCTUnwrap(socket.sentJSONObjects().first)
        XCTAssertEqual(connect["type"] as? String, "CONNECT")
        let descriptor = try XCTUnwrap(connect["protocol"] as? [String: Any])
        XCTAssertEqual(descriptor["name"] as? String, "oip")
        XCTAssertEqual(descriptor["version"] as? String, "0.1")
        let payload = try XCTUnwrap(connect["payload"] as? [String: Any])
        XCTAssertEqual(payload["signed_commands"] as? Int, 1)
        XCTAssertNotNil(connect["signature"] as? String)
    }

    func testHostErrorWithoutACodeIsAServerErrorAndOneAttempt() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "ERROR", "message": "unauthorized: wrong recipient"]
        ])
        let counter = AttemptCounter()
        let client = makeClient(conversationID: conversationID, socket: socket, counter: counter)

        do {
            _ = try await client.send(prompt: "Run the task", onUpdate: { _ in }, onEvent: { _ in })
            XCTFail("a rejected CONNECT must end the attempt with an error")
        } catch let error as ConnectOnionRemoteError {
            guard case .server(let message) = error else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertEqual(message, "unauthorized: wrong recipient")
            XCTAssertNil(error.incompatibility)
        }
        XCTAssertEqual(counter.sockets, 1)
    }

    func testAnIncompatibleAnswerAfterOnboardingStillEndsTheAttempt() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "ONBOARD_REQUIRED", "identity": "onboarding-1", "methods": ["invite_code"]],
            ["type": "ONBOARD_SUCCESS"],
            ["type": "ERROR", "code": -32010, "message": "Unsupported OIP protocol", "retryable": false]
        ])
        let counter = AttemptCounter()
        let client = makeClient(conversationID: conversationID, socket: socket, counter: counter)

        do {
            _ = try await client.send(prompt: "Run the task", onUpdate: { _ in }, onEvent: { _ in })
            XCTFail("-32010 must end the attempt with an error")
        } catch let error as ConnectOnionRemoteError {
            XCTAssertNotNil(error.incompatibility)
            XCTAssertNil(error.incompatibility?.neededVersion, "no descriptor was sent")
        }
        XCTAssertEqual(counter.sockets, 1)
    }

    // 16.2: the host's modes and turns_left reach the app.
    func testSessionModesAndTurnsLeftReachTheApp() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let socket = try ScriptedWebSocketTask(events: [
            [
                "type": "CONNECTED",
                "status": "new",
                "session_id": "session-1",
                "protocol": ["name": "oip", "version": "0.1", "min_version": "0.1", "max_version": "0.1"],
                "session_modes": [
                    "currentModeId": "auto",
                    "turnsLeft": NSNull(),
                    "availableModes": [["id": "read-only"], ["id": "auto"]]
                ]
            ],
            ["type": "mode_changed", "mode": "full-access", "turns_left": 5],
            ["type": "OUTPUT", "result": "done", "session": ["trace": []]]
        ])
        let client = makeClient(conversationID: conversationID, socket: socket, counter: AttemptCounter())
        let recorder = RemoteProtocolRecorder()

        _ = try await client.send(
            prompt: "Run the task",
            onUpdate: { _ in },
            onEvent: { await recorder.record($0) }
        )

        let events = await recorder.snapshot().events
        XCTAssertTrue(events.contains("modes:plan,safe:safe"), "\(events)")
        XCTAssertTrue(events.contains("mode:ulw:5"), "\(events)")
    }
}

// 15.2: EXEC runs on its own short-lived socket. Reuses `makeClient` and `AttemptCounter` above.
extension ConnectOnionRemoteAgentTests {
    private func connectedFrame() -> [String: Any] {
        [
            "type": "CONNECTED",
            "status": "new",
            "session_id": "session-1",
            "protocol": ["name": "oip", "version": "0.1", "min_version": "0.1", "max_version": "0.1"]
        ]
    }

    func testExecReturnsTheMatchingResultOnItsOwnSocket() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let socket = try ScriptedWebSocketTask(events: [
            connectedFrame(),
            ["type": "PING"],
            ["type": "EXEC_RESULT", "exec_id": "someone-else", "status": "success", "result": "not mine"],
            ["type": "EXEC_RESULT", "exec_id": "e-1", "tool": "bash", "status": "success", "result": "max", "duration_ms": 12]
        ])
        let counter = AttemptCounter()
        let client = makeClient(conversationID: conversationID, socket: socket, counter: counter)

        let result = try await client.runExec(execID: "e-1", tool: "bash", args: ["command": .string("whoami")])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.result, "max")
        XCTAssertEqual(result.durationMS, 12)
        XCTAssertEqual(counter.sockets, 1)
        XCTAssertTrue(socket.wasCancelled, "the EXEC socket is closed once the reply is in")
        let sent = try socket.sentJSONObjects()
        XCTAssertEqual(sent.compactMap { $0["type"] as? String }, ["CONNECT", "EXEC", "PONG"])
        let exec = try XCTUnwrap(sent.first { $0["type"] as? String == "EXEC" })
        XCTAssertEqual(exec["exec_id"] as? String, "e-1")
        XCTAssertEqual(exec["tool"] as? String, "bash")
        XCTAssertEqual((exec["args"] as? [String: Any])?["command"] as? String, "whoami")
        let hasPending = await client.hasPendingExecution()
        XCTAssertFalse(hasPending, "an EXEC leaves no execution to recover")
    }

    func testAFailedToolIsAResultNotAnError() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let socket = try ScriptedWebSocketTask(events: [
            connectedFrame(),
            ["type": "EXEC_RESULT", "exec_id": "e-2", "tool": "bash", "status": "error", "error": "blocked: cat"]
        ])
        let client = makeClient(conversationID: conversationID, socket: socket, counter: AttemptCounter())

        let result = try await client.runExec(execID: "e-2", tool: "bash", args: ["command": .string("cat /etc/hosts")])

        XCTAssertFalse(result.isSuccess)
        XCTAssertNil(result.result)
        XCTAssertEqual(result.error, "blocked: cat")
    }

    func testExecAgainstAnIncompatibleHostThrowsAndLeavesNothingToRecover() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let socket = try ScriptedWebSocketTask(events: [
            [
                "type": "ERROR",
                "code": -32010,
                "message": "Unsupported OIP protocol",
                "retryable": false,
                "protocol": ["name": "oip", "version": "9.9", "min_version": "9.9", "max_version": "9.9"]
            ]
        ])
        let client = makeClient(conversationID: conversationID, socket: socket, counter: AttemptCounter())

        do {
            _ = try await client.runExec(execID: "e-3", tool: "bash", args: [:])
            XCTFail("a refused handshake must throw")
        } catch let error as ConnectOnionRemoteError {
            XCTAssertNotNil(error.incompatibility)
        }

        let sentTypes = try socket.sentJSONObjects().compactMap { $0["type"] as? String }
        XCTAssertEqual(sentTypes, ["CONNECT"], "EXEC is never sent to a host that refused CONNECT")
        let hasPending = await client.hasPendingExecution()
        XCTAssertFalse(hasPending)
    }

    func testExecOnADeadSocketThrowsAndClosesIt() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let socket = ScriptedWebSocketTask(receiveError: URLError(.networkConnectionLost))
        let client = makeClient(conversationID: conversationID, socket: socket, counter: AttemptCounter())

        do {
            _ = try await client.runExec(execID: "e-4", tool: "bash", args: [:])
            XCTFail("a lost socket must throw")
        } catch {
            XCTAssertTrue(socket.wasCancelled)
        }
        let hasPending = await client.hasPendingExecution()
        XCTAssertFalse(hasPending)
    }
}
