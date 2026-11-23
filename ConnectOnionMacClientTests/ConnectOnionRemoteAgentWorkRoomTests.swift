import ConnectOnionKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

/// The Work Room's side of the remote client: provider frames and acks reaching the store, ERRORs that are the
/// Work Room's, and the connection held open between turns.
extension ConnectOnionRemoteAgentTests {
    func testStaleAnswerErrorDoesNotFailTheTurn() async throws {
        let address = makeAddress("a6")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Stale Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "stale-session"],
            ["type": "ERROR", "code": "STALE_ANSWER", "message": "Already answered"],
            ["type": "OUTPUT", "result": "done"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )

        let output = try await client.send(prompt: "Go", onUpdate: { _ in }, onEvent: { _ in })

        XCTAssertEqual(output, "done")
    }

    func testProviderInterruptAckReachesTheStoreAndTheTurnContinues() async throws {
        let address = makeAddress("a7")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Ack Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "ack-session"],
            ["type": "PROVIDER_INTERRUPT_ACK", "requestId": "r1", "invocationId": "codex:call-7",
             "accepted": true, "stateRevision": 2],
            ["type": "OUTPUT", "result": "done"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()
        let output = try await client.send(
            prompt: "Go",
            onUpdate: { await recorder.record($0) },
            onEvent: { await recorder.record($0) }
        )

        XCTAssertEqual(output, "done")
        let events = await recorder.snapshot().events
        XCTAssertTrue(events.contains("work_room_frame"))
    }

    func testProviderInputAckReachesTheStoreAndTheTurnContinues() async throws {
        let address = makeAddress("a8")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Ack Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "ack-session"],
            ["type": "PROVIDER_INPUT_ACK", "requestId": "r1", "invocationId": "codex:call-7",
             "accepted": true, "stateRevision": 2],
            ["type": "OUTPUT", "result": "done"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()
        let output = try await client.send(
            prompt: "Go",
            onUpdate: { await recorder.record($0) },
            onEvent: { await recorder.record($0) }
        )

        XCTAssertEqual(output, "done")
        let events = await recorder.snapshot().events
        XCTAssertTrue(events.contains("work_room_frame"))
    }

    func testProviderPermissionAckReachesTheStoreAndTheTurnContinues() async throws {
        let address = makeAddress("b1")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Ack Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "ack-session"],
            ["type": "PROVIDER_PERMISSION_ACK", "requestId": "r1", "invocationId": "codex:call-7",
             "accepted": true, "stateRevision": 2],
            ["type": "OUTPUT", "result": "done"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()
        let output = try await client.send(
            prompt: "Go",
            onUpdate: { await recorder.record($0) },
            onEvent: { await recorder.record($0) }
        )

        XCTAssertEqual(output, "done")
        let events = await recorder.snapshot().events
        XCTAssertTrue(events.contains("work_room_frame"))
    }

    func testProviderStationAttachAckReachesTheStoreAndTheTurnContinues() async throws {
        let address = makeAddress("b2")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Station Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "station-session"],
            ["type": "PROVIDER_STATION_ATTACH_ACK", "request_id": "r1", "accepted": true,
             "sessionId": "station-session"],
            ["type": "OUTPUT", "result": "done"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()
        let output = try await client.send(
            prompt: "Go",
            onUpdate: { await recorder.record($0) },
            onEvent: { await recorder.record($0) }
        )

        XCTAssertEqual(output, "done")
        let events = await recorder.snapshot().events
        XCTAssertTrue(events.contains("work_room_frame"))
    }

    func testProviderSessionAndControlAckReachTheStoreAndTheTurnContinues() async throws {
        let address = makeAddress("b2")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Station Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "station-session"],
            ["type": "provider_session", "provider": "claude_code",
             "invocationId": "claude_code:station:station-session",
             "parentToolCallId": "claude_station:station-session", "sessionId": "",
             "owner": "terminal", "phase": "local_observing", "stateRevision": 2],
            ["type": "PROVIDER_CONTROL_ACK", "requestId": "r1", "request_id": "r1", "action": "take",
             "accepted": true, "stateRevision": 3],
            ["type": "OUTPUT", "result": "done"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()
        let output = try await client.send(
            prompt: "Go",
            onUpdate: { await recorder.record($0) },
            onEvent: { await recorder.record($0) }
        )

        XCTAssertEqual(output, "done")
        let events = await recorder.snapshot().events
        XCTAssertEqual(events.filter { $0 == "work_room_frame" }.count, 2)
    }

    func testProviderArtifactReachesTheStoreAndTheTurnContinues() async throws {
        let address = makeAddress("b3")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Preview Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "preview-session"],
            ["type": "provider_artifact", "provider": "codex", "invocationId": "codex:call-7",
             "parentToolCallId": "call-7", "artifactId": "latest-2", "kind": "screenshot", "stateRevision": 2,
             "alt": "Latest provider workspace view",
             "thumbnailDataUrl": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4"
                + "nGP436AARAwQCgAw7gZ9vw2nHQAAAABJRU5ErkJggg=="],
            ["type": "OUTPUT", "result": "done"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()
        let artifacts = LockedLog()
        let output = try await client.send(
            prompt: "Go",
            onUpdate: { await recorder.record($0) },
            onEvent: {
                if case .workRoomFrame(.providerArtifact) = $0 { artifacts.append("artifact") }
                await recorder.record($0)
            }
        )

        XCTAssertEqual(output, "done")
        let events = await recorder.snapshot().events
        XCTAssertEqual(events.filter { $0 == "work_room_frame" }.count, 1)
        XCTAssertEqual(artifacts.values, ["artifact"])
    }

    func testWorkRoomConnectionSetsAndClearsTheStoreTransport() async throws {
        let address = makeAddress("a9")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Room Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "room-session"],
            ["type": "PROVIDER_INPUT_ACK", "requestId": "r1", "invocationId": "codex:call-7",
             "accepted": true, "stateRevision": 2]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let seen = LockedLog()

        let shouldRetry = await client.holdWorkRoomConnection { event in
            switch event {
            case .workRoomTransport: seen.append("transport")
            case .workRoomFrame: seen.append("frame")
            case .workRoomConnectionDropped: seen.append("dropped")
            default: break
            }
        }

        XCTAssertEqual(seen.values, ["transport", "frame", "dropped"])
        // The socket ended on its own, so the caller opens another; nothing here needs session-sync.
        XCTAssertTrue(shouldRetry)
        let connect = try XCTUnwrap(socket.sentJSONObjects().first)
        XCTAssertNil((connect["payload"] as? [String: Any])?["extensions"])
    }

    private func heldStationConnection(
        _ events: [[String: Any]], inviteCode: String?
    ) async throws -> HeldConnection {
        let address = makeAddress("b1")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Station", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: events)
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let seen = LockedLog()
        let shouldRetry = await client.holdWorkRoomConnection(inviteCode: inviteCode, handlesOnboarding: true) { event in
            switch event {
            case .workRoomTransport: seen.append("transport")
            case .onboardingRequired: seen.append("onboarding")
            case .error(let message): seen.append("error: \(message)")
            default: break
            }
        }
        return HeldConnection(seen: seen.values, sent: try socket.sentJSONObjects(), shouldRetry: shouldRetry)
    }

    func testStationConnectionAnswersOnboardingWithTheInviteCode() async throws {
        let result = try await heldStationConnection([
            ["type": "ONBOARD_REQUIRED", "identity": "0xabc", "methods": ["invite_code"]],
            ["type": "ONBOARD_SUCCESS", "identity": "0xabc", "level": "contact"],
            ["type": "CONNECTED", "status": "connected", "session_id": "s1"]
        ], inviteCode: "pair-me")

        XCTAssertEqual(result.sent.compactMap { $0["type"] as? String }, ["CONNECT", "ONBOARD_SUBMIT"])
        let payload = result.sent.last?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["invite_code"] as? String, "pair-me")
        XCTAssertEqual(result.seen, ["transport"])
    }

    func testStationConnectionAsksForACodeAndShowsAWrongOne() async throws {
        let asked = try await heldStationConnection([
            ["type": "ONBOARD_REQUIRED", "identity": "0xabc", "methods": ["invite_code"]]
        ], inviteCode: nil)
        XCTAssertEqual(asked.seen, ["onboarding"])
        XCTAssertEqual(asked.sent.compactMap { $0["type"] as? String }, ["CONNECT"])
        XCTAssertFalse(asked.shouldRetry, "the user has to enter a code first")

        let wrong = try await heldStationConnection([
            ["type": "ONBOARD_REQUIRED", "identity": "0xabc", "methods": ["invite_code"]],
            ["type": "ERROR", "message": "Invalid invite code"]
        ], inviteCode: "nope")
        XCTAssertEqual(wrong.seen, ["onboarding", "error: Invalid invite code"])
        XCTAssertFalse(wrong.shouldRetry)
    }

    // Seen live: with the host down, the relay refuses the CONNECT. That is a failed connection, not something the
    // user can fix, so the held connection must be opened again.
    func testARefusedConnectWithNoCodeSentIsRetried() async throws {
        let offline = try await heldStationConnection([
            ["type": "ERROR", "message": "Agent is offline"]
        ], inviteCode: nil)
        XCTAssertTrue(offline.shouldRetry)
        XCTAssertEqual(offline.seen, [])
    }

    func testAnErrorAnsweringAWorkRoomRequestDoesNotFailTheTurn() async throws {
        let address = makeAddress("c1")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Room Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "room-session"],
            ["type": "ERROR", "request_id": "room-request", "message": "Not allowed"],
            ["type": "OUTPUT", "result": "done"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )

        let output = try await client.send(prompt: "Go", onUpdate: { _ in }, onEvent: { event in
            if case .workRoomTransport(_, let send) = event {
                _ = await send(["type": .string("PROVIDER_INPUT"), "requestId": .string("room-request")])
            }
        })

        XCTAssertEqual(output, "done")
    }

    func testAStationRefusingTheInputEndsTheTurnAsStationOnly() async throws {
        let address = makeAddress("c2")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Station", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "station-session"],
            ["type": "ERROR", "code": "provider_station_only", "message": "Use the Claude Work Room"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )

        do {
            _ = try await client.send(prompt: "Go", onUpdate: { _ in }, onEvent: { _ in })
            XCTFail("A Station never answers INPUT")
        } catch ConnectOnionRemoteError.stationOnly {
            // The chat shows no failure for it.
        }
    }
}

final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// What a held Station connection did: the events it raised, the frames it sent, and whether to open another.
struct HeldConnection {
    let seen: [String]
    let sent: [[String: Any]]
    let shouldRetry: Bool
}
