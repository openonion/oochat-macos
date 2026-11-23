import ConnectOnionKit
import CryptoKit
import XCTest
@testable import ConnectOnionMacClient

private final class RestoreStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) -> Result<(Int, String), URLError>)?
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let respond = Self.respond else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        switch respond(request) {
        case .success(let (status, body)):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class HistoryRestoreTests: XCTestCase {
    private let sessionID = UUID().uuidString.lowercased()
    private let address = "0x" + String(repeating: "ab", count: 32)

    private func make(
        direct: Bool = true,
        keyStore: InMemoryPrivateKeyStore = InMemoryPrivateKeyStore(),
        defaults: UserDefaults? = nil
    ) throws -> (AppViewModel, GeneralAgentConfiguration) {
        let defaults = try defaults ?? XCTUnwrap(UserDefaults(suiteName: "restore-\(UUID())"))
        let config = GeneralAgentConfiguration(
            name: "A", connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: try XCTUnwrap(URL(string: "ws://127.0.0.1:8000/ws")),
            httpBaseURL: direct ? URL(string: "http://127.0.0.1:8000") : nil,
            isDirect: direct, info: nil
        )
        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.protocolClasses = [RestoreStub.self]
        let appViewModel = AppViewModel(
            storage: defaults, localAgentDefinitions: [],
            historyURLSession: URLSession(configuration: urlConfig),
            historyKeyStore: keyStore,
            resolveAgentEndpoint: { _ in endpoint }
        )
        appViewModel.configurations = [config]
        return (appViewModel, config)
    }

    private var body: String {
        """
        {"sessions":[{"session_id":"\(sessionID)","status":"done","prompt":"Hi","result":"Hello",
        "created":1700000000,"session":{"updated":1700000010,"messages":[
        {"role":"user","content":"Hi"},{"role":"assistant","content":"Hello"}]}}]}
        """
    }

    func testARestoredChatWithNoTitleMessageUsesTheNewChatTitle() {
        let commandOnly = [ChatMessage(sessionId: UUID(), role: .user, content: "/help")]
        XCTAssertEqual(AppViewModel.title(for: commandOnly), ChatSession.defaultTitle)
        XCTAssertEqual(AppViewModel.title(for: []), ChatSession.defaultTitle)
    }

    func testRestoredSessionMapsBySessionIDAndRefreshesDoNotDuplicate() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.body)) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        await appViewModel.refreshAgentStatusAndWait(for: config)
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertEqual(appViewModel.sessions.count, 1)
        XCTAssertEqual(appViewModel.sessions[0].remoteSessionID, sessionID)
        XCTAssertEqual(appViewModel.sessions[0].id.uuidString.lowercased(), sessionID)
        XCTAssertEqual(appViewModel.findMessages(for: appViewModel.sessions[0].id).map(\.content), ["Hi", "Hello"])
        XCTAssertEqual(appViewModel.historyRestoreStates[config.id], .restored)
    }

    func testAuthRejectionIsFailedNotEmptyHistory() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((401, "{}")) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertEqual(appViewModel.historyRestoreStates[config.id], .failed)
    }

    func testUnreachableIsPendingAndRetriesNextConnect() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .failure(URLError(.cannotConnectToHost)) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertEqual(appViewModel.historyRestoreStates[config.id], .pending)
        RestoreStub.respond = { _ in .success((200, self.body)) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertEqual(appViewModel.historyRestoreStates[config.id], .restored)
        XCTAssertEqual(appViewModel.sessions.count, 1)
    }

    func testRelayOnlyAgentIsPendingWithoutRequest() async throws {
        let (appViewModel, config) = try make(direct: false)
        RestoreStub.respond = { _ in XCTFail("no request expected"); return .failure(URLError(.badURL)) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertEqual(appViewModel.historyRestoreStates[config.id], .pending)
    }

    // The Settings status poll runs on a timer, and History Restore has no timer: a poll only retries an
    // agent that has not restored yet. Launch, foreground and refresh still restore.
    func testAStatusPollRestoresOnlyAnAgentNotYetRestored() async throws {
        let (appViewModel, config) = try make()
        let fetches = LockedCounter()
        RestoreStub.respond = { _ in
            fetches.increment()
            return .failure(URLError(.cannotConnectToHost))
        }
        await appViewModel.refreshAgentStatusAndWait(for: config, trigger: .poll)
        XCTAssertEqual(fetches.value, 1, "a pending agent retries on a poll")

        RestoreStub.respond = { _ in
            fetches.increment()
            return .success((200, self.body))
        }
        await appViewModel.refreshAgentStatusAndWait(for: config, trigger: .poll)
        await appViewModel.refreshAgentStatusAndWait(for: config, trigger: .poll)
        XCTAssertEqual(fetches.value, 2, "a restored agent is not fetched again by the poll")

        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertEqual(fetches.value, 3, "an explicit refresh restores again")
    }

    // History Restore never merges into a chat from a previous identity, even one with the same session id.
    func testRestoreLeavesAPreviousIdentityChatAlone() async throws {
        let (appViewModel, config) = try make()
        let localID = try XCTUnwrap(UUID(uuidString: sessionID))
        appViewModel.sessions = [ChatSession(
            id: localID,
            agentConfigId: config.id,
            remoteSessionID: sessionID,
            identityAddress: "0x" + String(repeating: "cd", count: 32),
            title: "Old",
            updatedAt: .distantPast
        )]
        appViewModel.messages = [
            ChatMessage(sessionId: localID, role: .user, content: "old"),
            ChatMessage(sessionId: localID, role: .agent, content: "old reply")
        ]
        RestoreStub.respond = { _ in .success((200, self.body)) }

        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertEqual(appViewModel.sessions.map(\.title), ["Old"])
        XCTAssertEqual(appViewModel.findMessages(for: localID).map(\.content), ["old", "old reply"])
    }

    // A link that replaces the key while the host answers: those sessions belong to the old Address.
    func testARestoreFetchedBeforeALinkAddsNothing() async throws {
        let keyStore = InMemoryPrivateKeyStore()
        let (appViewModel, config) = try make(keyStore: keyStore)
        RestoreStub.respond = { _ in
            try? keyStore.replacePrivateKey(with: Curve25519.Signing.PrivateKey().rawRepresentation)
            return .success((200, self.body))
        }

        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertTrue(appViewModel.sessions.isEmpty)
    }

    func testRestoreStateMapping() {
        XCTAssertEqual(HistoryRestoreState(error: URLError(.timedOut)), .pending)
        XCTAssertEqual(HistoryRestoreState(error: SessionsClientError.authRejected(status: 403)), .failed)
        XCTAssertEqual(HistoryRestoreState(error: SessionsClientError.http(status: 500)), .failed)
    }
}

// One agent per Address (spec 02, Agent Names).
extension HistoryRestoreTests {
    // An older build could save a Direct URL agent and a 0x agent for the same Address. They load as one: the
    // earliest keeps its name and takes the other's chats, a deleted chat stays deleted, and restore runs once.
    func testStoredDuplicatesMergeIntoTheEarliestAgentAndRestoreOnce() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "merge-\(UUID())"))
        var byURL = GeneralAgentConfiguration(
            name: "Mine", connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: "http://127.0.0.1:8000")
        )
        byURL.resolvedAddress = address
        let byAddress = GeneralAgentConfiguration(
            name: "Other", connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: "0x" + String(repeating: "AB", count: 32))
        )
        let first = ChatSession(agentConfigId: byURL.id, agentIdentity: byURL.agentIdentity, title: "First")
        let second = ChatSession(agentConfigId: byAddress.id, agentIdentity: address, title: "Second")
        defaults.set(try JSONEncoder().encode([byURL, byAddress]), forKey: "saved_configurations")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "saved_sessions")
        let storedMessages = [first, second].map { ChatMessage(sessionId: $0.id, role: .user, content: $0.title) }
        defaults.set(try JSONEncoder().encode(storedMessages), forKey: "saved_messages")
        defaults.set(try JSONEncoder().encode(Set([sessionID])), forKey: "deleted_remote_session_ids")
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address, webSocketURL: try XCTUnwrap(URL(string: "ws://127.0.0.1:8000/ws")),
            httpBaseURL: URL(string: "http://127.0.0.1:8000"), isDirect: true, info: nil
        )
        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.protocolClasses = [RestoreStub.self]
        let fetches = LockedCounter()
        RestoreStub.respond = { _ in
            fetches.increment()
            return .success((200, self.body))
        }

        let appViewModel = AppViewModel(
            storage: defaults, localAgentDefinitions: [],
            historyURLSession: URLSession(configuration: urlConfig),
            historyKeyStore: InMemoryPrivateKeyStore(),
            resolveAgentEndpoint: { _ in endpoint }
        )
        for configuration in appViewModel.configurations {
            await appViewModel.refreshAgentStatusAndWait(for: configuration)
        }

        XCTAssertEqual(appViewModel.configurations.map(\.name), ["Mine"])
        XCTAssertEqual(appViewModel.configurations.map(\.id), [byURL.id])
        XCTAssertEqual(appViewModel.visibleSessions.map(\.title).sorted(), ["First", "Second"], "the deleted chat stays deleted")
        XCTAssertEqual(Set(appViewModel.sessions.map(\.agentConfigId)), [byURL.id])
        XCTAssertEqual(
            appViewModel.sessions.filter(\.isTombstone).map(\.remoteSessionID), [sessionID],
            "an older build's deletion becomes a Tombstone"
        )
        XCTAssertEqual(fetches.value, 1)
    }
}

extension HistoryRestoreTests {
    // A Direct URL agent turns out to be an agent this Mac has by Address: it merges into that one when reached,
    // and nothing is restored twice.
    func testADirectURLAgentForAKnownAddressMergesWhenReached() async throws {
        let (appViewModel, config) = try make()
        let fetches = LockedCounter()
        RestoreStub.respond = { _ in
            fetches.increment()
            return .success((200, self.body))
        }
        guard case .added(let byURL) = appViewModel.addAgent("http://127.0.0.1:8000") else {
            return XCTFail("its Address isn't known until it is reached")
        }
        appViewModel.createNewSession(for: byURL)

        await appViewModel.refreshAgentStatusAndWait(for: byURL)

        XCTAssertEqual(appViewModel.configurations.map(\.id), [config.id])
        XCTAssertEqual(Set(appViewModel.sessions.map(\.agentConfigId)), [config.id])
        XCTAssertEqual(fetches.value, 0, "the merged-away agent restores nothing; the one it joined restores on its own check")
    }
}

// Deleted chats (Tombstones): the row stays, empty and hidden, so History Restore can skip its session.
extension HistoryRestoreTests {
    private func body(updated: Int, reply: String = "Hello") -> String {
        """
        {"sessions":[{"session_id":"\(sessionID)","status":"done","prompt":"Hi","result":"\(reply)",
        "created":1700000000,"session":{"updated":\(updated),"messages":[
        {"role":"user","content":"Hi"},{"role":"assistant","content":"\(reply)"}]}}]}
        """
    }

    func testADeletedChatIsNotRecreatedByALaterRefresh() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tombstone-\(UUID())"))
        let (appViewModel, config) = try make(defaults: defaults)
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        let restored = try XCTUnwrap(appViewModel.visibleSessions.first)

        let bookmarkKey = ConnectOnionRemoteSessionStore.key(for: restored.id)
        defaults.set(Data("{}".utf8), forKey: bookmarkKey)

        appViewModel.deleteSession(restored)
        // A reply still streaming when the chat was deleted.
        appViewModel.addMessage(ChatMessage(sessionId: restored.id, role: .agent, content: "late"))
        appViewModel.updateSessionDate(restored)
        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertNil(defaults.data(forKey: bookmarkKey), "its resume bookmark goes")
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty)
        XCTAssertTrue(appViewModel.messages.isEmpty, "the Tombstone holds no messages")
        XCTAssertEqual(appViewModel.sessions.map(\.remoteSessionID), [sessionID], "the row keeps its session id")
        XCTAssertEqual(appViewModel.sessions.map(\.title), [ChatSession.defaultTitle], "the title was the first message")
    }

    // Equal is not newer; only a greater `updated` means the session was used again elsewhere.
    func testADeletedChatComesBackInFullWhenTheHostReportsANewerUpdate() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        // A local reply first moves the row's own date past the host's, onto the device clock.
        let chat = try XCTUnwrap(appViewModel.visibleSessions.first)
        appViewModel.addMessage(ChatMessage(
            sessionId: chat.id, role: .user, content: "More", timestamp: Date(timeIntervalSince1970: 1_700_000_012)
        ))
        appViewModel.updateSessionDate(chat)
        appViewModel.deleteSession(try XCTUnwrap(appViewModel.visibleSessions.first))

        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty)
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_020, reply: "Again"))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)

        let restored = try XCTUnwrap(appViewModel.visibleSessions.first)
        XCTAssertEqual(appViewModel.sessions.count, 1, "the Tombstone itself comes back")
        XCTAssertFalse(restored.isTombstone)
        XCTAssertEqual(restored.title, "Hi")
        XCTAssertEqual(appViewModel.findMessages(for: restored.id).map(\.content), ["Hi", "Again"])
    }

    func testAMillisecondUpdatedIsComparedWithTheTombstoneInSeconds() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        appViewModel.deleteSession(try XCTUnwrap(appViewModel.visibleSessions.first))

        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_005_000))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty, "an older host time stays deleted")

        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_020_000, reply: "Again"))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        let restored = try XCTUnwrap(appViewModel.visibleSessions.first)
        XCTAssertEqual(restored.updatedAt, Date(timeIntervalSince1970: 1_700_000_020))
    }

    // A reply arrives after the host stamps its turn, so a chat used and deleted before the next restore stays
    // deleted. Opening the chat (its own date) is not a message and is not recorded.
    func testATombstoneRecordsTheLaterOfTheHostUpdatedAndTheLastMessage() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        let restored = try XCTUnwrap(appViewModel.visibleSessions.first)
        appViewModel.addMessage(ChatMessage(
            sessionId: restored.id, role: .agent, content: "More", timestamp: Date(timeIntervalSince1970: 1_700_000_050)
        ))
        appViewModel.updateSessionDate(restored)

        appViewModel.deleteSession(restored)
        // The host stamped that turn just before the reply arrived.
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_049, reply: "More"))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertEqual(appViewModel.sessions.first?.tombstoneUpdatedAt, Date(timeIntervalSince1970: 1_700_000_050))
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty)
    }

    // Each refresh records the host's latest updated, so a chat used after its first restore stays deleted.
    func testARefreshRecordsTheLatestHostUpdatedWithoutTouchingMessages() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        let restored = try XCTUnwrap(appViewModel.visibleSessions.first)
        appViewModel.addMessage(ChatMessage(
            sessionId: restored.id, role: .user, content: "sent during the fetch",
            timestamp: Date(timeIntervalSince1970: 1_700_000_015)
        ))
        appViewModel.updateSessionDate(restored)
        // The host has moved on; its snapshot predates the message above.
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_020))) }

        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertEqual(appViewModel.findMessages(for: restored.id).last?.content, "sent during the fetch")
        appViewModel.deleteSession(try XCTUnwrap(appViewModel.visibleSessions.first))
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty)
    }

    func testAStaleHostUpdatedNeverLowersTheRecordedOne() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_020))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }

        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertEqual(appViewModel.sessions.first?.hostUpdatedAt, Date(timeIntervalSince1970: 1_700_000_020))
    }

    func testARestoreForAnAgentRemovedDuringTheFetchAddsNothing() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in
            // The fetch is in flight with the main actor free: the person removes the agent now.
            DispatchQueue.main.sync { MainActor.assumeIsolated { appViewModel.deleteConfiguration(config) } }
            return .success((200, self.body))
        }

        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertTrue(appViewModel.sessions.isEmpty)
    }

    /// The host's system prompt is not chat and there is no prompt or result, so this session has nothing to show.
    private func emptyBody(updated: Int) -> String {
        """
        {"sessions":[{"session_id":"\(sessionID)","status":"done","prompt":"",
        "created":1700000000,"session":{"updated":\(updated),"messages":[
        {"role":"system","content":"You are helpful."}]}}]}
        """
    }

    func testAHostSessionWithNoVisibleMessagesCreatesNoChat() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.emptyBody(updated: 1_700_000_010))) }

        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertTrue(appViewModel.sessions.isEmpty)
        XCTAssertEqual(appViewModel.historyRestoreStates[config.id], .restored)
    }

    func testAnEmptyHostSessionKeepsATombstoneDeletedButRaisesWhatItRecorded() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        appViewModel.deleteSession(try XCTUnwrap(appViewModel.visibleSessions.first))
        RestoreStub.respond = { _ in .success((200, self.emptyBody(updated: 1_700_000_030))) }

        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty, "nothing to show, so nothing revives")

        // Newer than the deletion but older than the empty session.
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_020, reply: "Again"))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty)
    }

    func testAnEmptyHostSessionLeavesALiveChatsMessagesAndRecordsItsUpdated() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        RestoreStub.respond = { _ in .success((200, self.emptyBody(updated: 1_700_000_030))) }

        await appViewModel.refreshAgentStatusAndWait(for: config)

        let chat = try XCTUnwrap(appViewModel.visibleSessions.first)
        XCTAssertEqual(appViewModel.findMessages(for: chat.id).map(\.content), ["Hi", "Hello"])
        appViewModel.deleteSession(chat)
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_020, reply: "Again"))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty, "the Tombstone recorded the empty session's updated")
    }

    // History Restore never replaces the messages of a live chat that has any; catch-up on open does that.
    func testANewerHostTranscriptLeavesALiveChatsMessagesAndRecordsItsUpdated() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        let chat = try XCTUnwrap(appViewModel.visibleSessions.first)
        appViewModel.addMessage(ChatMessage(
            sessionId: chat.id, role: .agent, content: "local", timestamp: Date(timeIntervalSince1970: 1_700_000_012)
        ))
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_030, reply: "Elsewhere"))) }

        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertEqual(appViewModel.findMessages(for: chat.id).map(\.content), ["Hi", "Hello", "local"])
        appViewModel.deleteSession(try XCTUnwrap(appViewModel.visibleSessions.first))
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_020, reply: "Again"))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty, "the Tombstone recorded the newer updated")
    }

    // A local chat that later matches a host session is linked to it, but keeps its own messages.
    func testALocalChatThatMatchesAHostSessionIsLinkedButNotOverwritten() async throws {
        let (appViewModel, config) = try make()
        let localID = try XCTUnwrap(UUID(uuidString: sessionID))
        appViewModel.sessions = [ChatSession(id: localID, agentConfigId: config.id, title: "Mine", updatedAt: .distantPast)]
        appViewModel.messages = [
            ChatMessage(sessionId: localID, role: .user, content: "Mine"),
            ChatMessage(sessionId: localID, role: .agent, content: "Local reply")
        ]
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }

        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertEqual(appViewModel.sessions.map(\.remoteSessionID), [sessionID])
        XCTAssertEqual(appViewModel.sessions.map(\.title), ["Mine"])
        XCTAssertEqual(appViewModel.findMessages(for: localID).map(\.content), ["Mine", "Local reply"])
    }

    func testAnEmptyLiveChatIsFilledFromItsHostSession() async throws {
        let (appViewModel, config) = try make()
        let localID = try XCTUnwrap(UUID(uuidString: sessionID))
        appViewModel.sessions = [ChatSession(id: localID, agentConfigId: config.id, remoteSessionID: sessionID, title: "New Chat")]
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }

        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertEqual(appViewModel.sessions.map(\.title), ["Hi"])
        XCTAssertEqual(appViewModel.findMessages(for: localID).map(\.content), ["Hi", "Hello"])
    }

    func testADeletedChatStaysDeletedAfterAReloadAndAnIdentityReplace() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tombstone-\(UUID())"))
        let keyStore = InMemoryPrivateKeyStore()
        let (appViewModel, config) = try make(keyStore: keyStore, defaults: defaults)
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        appViewModel.deleteSession(try XCTUnwrap(appViewModel.visibleSessions.first))

        let (reloaded, _) = try make(keyStore: keyStore, defaults: defaults)
        await reloaded.refreshAgentStatusAndWait(for: config)
        XCTAssertTrue(reloaded.visibleSessions.isEmpty, "reloaded from the store")
        XCTAssertEqual(reloaded.sessions.filter(\.isTombstone).count, 1)

        let previousAddress = try OIPSigner(keyStore: keyStore).address()
        try keyStore.replacePrivateKey(with: Curve25519.Signing.PrivateKey().rawRepresentation)
        reloaded.adoptReplacedIdentity(previousAddress: previousAddress)
        await reloaded.refreshAgentStatusAndWait(for: config)

        XCTAssertTrue(reloaded.visibleSessions.isEmpty, "after an Identity replace")
        XCTAssertTrue(reloaded.messages.isEmpty)
    }

    func testRemovingAnAgentRemovesItsTombstones() async throws {
        let (appViewModel, config) = try make()
        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        appViewModel.deleteSession(try XCTUnwrap(appViewModel.visibleSessions.first))

        appViewModel.deleteConfiguration(config)
        XCTAssertTrue(appViewModel.sessions.isEmpty)
        appViewModel.configurations = [config]
        await appViewModel.refreshAgentStatusAndWait(for: config)

        XCTAssertEqual(appViewModel.visibleSessions.count, 1, "nothing remembers the deletion once the agent is gone")
    }

    func testDeletingAPreviousIdentityChatLeavesNoTombstone() throws {
        let (appViewModel, config) = try make()
        let old = ChatSession(
            agentConfigId: config.id,
            remoteSessionID: sessionID,
            identityAddress: "0x" + String(repeating: "cd", count: 32),
            title: "Old"
        )
        appViewModel.sessions = [old]
        appViewModel.messages = [ChatMessage(sessionId: old.id, role: .user, content: "old")]

        appViewModel.deleteSession(old)

        XCTAssertTrue(appViewModel.sessions.isEmpty)
        XCTAssertTrue(appViewModel.messages.isEmpty)
    }

    // A chat that never came from the host records its last message time, so an older host `updated` is skipped.
    func testALocalChatDeletedBeforeAnyRestoreRecordsItsLastMessageTime() async throws {
        let (appViewModel, config) = try make()
        let localID = try XCTUnwrap(UUID(uuidString: sessionID))
        let local = ChatSession(
            id: localID, agentConfigId: config.id, remoteSessionID: sessionID, title: "Hi", updatedAt: .distantPast
        )
        appViewModel.sessions = [local]
        appViewModel.messages = [ChatMessage(
            sessionId: localID, role: .user, content: "Hi", timestamp: Date(timeIntervalSince1970: 1_700_000_015)
        )]
        appViewModel.deleteSession(local)

        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_015))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty)
        XCTAssertTrue(appViewModel.messages.isEmpty)

        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_016))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertEqual(appViewModel.visibleSessions.map(\.id), [localID])
    }

    // With no messages and no host time, the chat's creation time is what it records, never the distant past.
    func testAnEmptyChatDeletedBeforeAnyRestoreRecordsItsCreationTime() async throws {
        let (appViewModel, config) = try make()
        let localID = try XCTUnwrap(UUID(uuidString: sessionID))
        let empty = ChatSession(
            id: localID, agentConfigId: config.id, remoteSessionID: sessionID, title: "New Chat",
            createdAt: Date(timeIntervalSince1970: 1_700_000_015)
        )
        appViewModel.sessions = [empty]
        appViewModel.deleteSession(empty)

        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_010))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertTrue(appViewModel.visibleSessions.isEmpty)
        XCTAssertTrue(appViewModel.messages.isEmpty)

        RestoreStub.respond = { _ in .success((200, self.body(updated: 1_700_000_020))) }
        await appViewModel.refreshAgentStatusAndWait(for: config)
        XCTAssertEqual(appViewModel.visibleSessions.map(\.id), [localID])
    }
}
