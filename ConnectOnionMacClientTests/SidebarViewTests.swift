import AppKit
import SwiftUI
import XCTest
import ConnectOnionKit
@testable import ConnectOnionMacClient

final class SidebarViewTests: XCTestCase {
    func testAgentChatExpansionTracksAgentsIndependently() {
        let firstAgentID = UUID()
        let secondAgentID = UUID()
        var state = SidebarAgentChatExpansionState()

        XCTAssertTrue(state.isExpanded(firstAgentID))
        XCTAssertTrue(state.isExpanded(secondAgentID))

        state.toggle(firstAgentID)
        XCTAssertFalse(state.isExpanded(firstAgentID))
        XCTAssertTrue(state.isExpanded(secondAgentID))

        state.toggle(firstAgentID)
        XCTAssertTrue(state.isExpanded(firstAgentID))

        state.toggle(secondAgentID)
        state.remove(secondAgentID)
        XCTAssertTrue(state.isExpanded(secondAgentID))
    }

    @MainActor
    func testSidebarRendersAgentsWithAndWithoutChatHistory() {
        let suiteName = "SidebarViewTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create isolated UserDefaults suite")
        }
        storage.removePersistentDomain(forName: suiteName)
        defer { storage.removePersistentDomain(forName: suiteName) }

        let appViewModel = AppViewModel(
            storage: storage,
            localAgentDefinitions: [],
            resolveAgentEndpoint: { _ in
                throw ConnectOnionRemoteError.agentOffline
            }
        )
        let agentWithChats = makeAgent(name: "Agent with chats", suffix: "ab")
        let agentWithoutChats = makeAgent(name: "Empty agent", suffix: "cd")
        appViewModel.configurations = [agentWithChats, agentWithoutChats]
        appViewModel.sessions = [
            ChatSession(
                agentConfigId: agentWithChats.id,
                title: "First conversation"
            ),
            ChatSession(
                agentConfigId: agentWithChats.id,
                title: "Second conversation",
                createdAt: Date().addingTimeInterval(-86_400),
                updatedAt: Date().addingTimeInterval(-86_400)
            )
        ]

        let hostingView = NSHostingView(
            rootView: SidebarView(appViewModel: appViewModel)
                .frame(width: 280, height: 720)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 720)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    @MainActor
    func testSidebarStatusSaysNotSentUntilTheLastMessageGoesThroughAndTheOpenChatsLiveStatusWins() {
        let suiteName = "SidebarViewTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create isolated UserDefaults suite")
        }
        defer { storage.removePersistentDomain(forName: suiteName) }
        let appViewModel = AppViewModel(
            storage: storage,
            localAgentDefinitions: [],
            resolveAgentEndpoint: { _ in throw ConnectOnionRemoteError.agentOffline }
        )
        let agent = makeAgent(name: "Agent", suffix: "ab")
        let failed = ChatSession(agentConfigId: agent.id, title: "Failed")
        let open = ChatSession(agentConfigId: agent.id, title: "Open")
        appViewModel.configurations = [agent]
        appViewModel.sessions = [failed, open]
        appViewModel.messages = [
            ChatMessage(sessionId: failed.id, role: .user, content: "first", status: .sent),
            ChatMessage(sessionId: failed.id, role: .user, content: "second", status: .error),
            ChatMessage(sessionId: open.id, role: .user, content: "hi", status: .error),
            ChatMessage(sessionId: open.id, role: .user, content: "again", status: .sent)
        ]

        XCTAssertEqual(appViewModel.sidebarStatuses[failed.id], .notSent)
        XCTAssertNil(appViewModel.sidebarStatuses[open.id], "a later message went through")

        appViewModel.selection = .session(open.id)
        appViewModel.setLiveActivity(.approval, for: open.id)
        XCTAssertEqual(appViewModel.sidebarStatuses[open.id], .approval)

        appViewModel.selection = .session(failed.id)
        XCTAssertNil(appViewModel.sidebarStatuses[open.id], "leaving a chat drops its live status")
        XCTAssertEqual(appViewModel.sidebarStatuses[failed.id], .notSent)
    }

    @MainActor
    func testArrowKeysStepThroughChatsAndHoldAtTheEnds() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertEqual(SidebarView.chat(after: ids[0], in: ids, step: 1), ids[1])
        XCTAssertEqual(SidebarView.chat(after: ids[2], in: ids, step: 1), ids[2], "held at the bottom")
        XCTAssertEqual(SidebarView.chat(after: ids[0], in: ids, step: -1), ids[0], "held at the top")
        XCTAssertEqual(SidebarView.chat(after: nil, in: ids, step: 1), ids[0])
        XCTAssertEqual(SidebarView.chat(after: nil, in: ids, step: -1), ids[2])
        XCTAssertEqual(SidebarView.chat(after: UUID(), in: ids, step: 1), ids[0], "a chat that's not listed")
        XCTAssertNil(SidebarView.chat(after: nil, in: [], step: 1))
    }

    // Search finds a chat by its title or by anything said in it, ignoring case and accents.
    @MainActor
    func testSearchMatchesTitlesAndMessageText() {
        let agentID = UUID()
        let byTitle = ChatSession(agentConfigId: agentID, title: "Café plans")
        let byMessage = ChatSession(agentConfigId: agentID, title: "Hello")
        let neither = ChatSession(agentConfigId: agentID, title: "Other")
        let messages = [
            ChatMessage(sessionId: byMessage.id, role: .agent, content: "The CAFE opens at 9."),
            ChatMessage(sessionId: neither.id, role: .user, content: "Nothing here")
        ]

        let matches = SidebarView.sessionsMatching("cafe", sessions: [byTitle, byMessage, neither], messages: messages)

        XCTAssertEqual(matches, [byTitle.id, byMessage.id])
    }

    // The rail opens an agent where you left it: its latest chat, or a new one if it has none.
    @MainActor
    func testPickingAnAgentOnTheRailOpensItsLatestChat() {
        let suiteName = "SidebarViewTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create isolated UserDefaults suite")
        }
        defer { storage.removePersistentDomain(forName: suiteName) }
        let appViewModel = AppViewModel(
            storage: storage,
            localAgentDefinitions: [],
            resolveAgentEndpoint: { _ in throw ConnectOnionRemoteError.agentOffline }
        )
        let busy = makeAgent(name: "Busy", suffix: "ab")
        let quiet = makeAgent(name: "Quiet", suffix: "cd")
        let older = ChatSession(agentConfigId: busy.id, title: "Older", updatedAt: Date().addingTimeInterval(-600))
        let newer = ChatSession(agentConfigId: busy.id, title: "Newer", updatedAt: Date())
        appViewModel.configurations = [busy, quiet]
        appViewModel.sessions = [older, newer]
        appViewModel.messages = [
            ChatMessage(sessionId: older.id, role: .user, content: "a"),
            ChatMessage(sessionId: newer.id, role: .user, content: "b")
        ]

        appViewModel.openAgent(busy)
        XCTAssertEqual(appViewModel.selection, .session(newer.id))
        XCTAssertEqual(appViewModel.paneAgent?.id, busy.id)

        appViewModel.selectHistoricalSession(older.id)
        appViewModel.openAgent(busy)
        XCTAssertEqual(appViewModel.selection, .session(older.id), "picking the agent you're in changes nothing")

        appViewModel.openAgent(quiet)
        XCTAssertEqual(appViewModel.paneAgent?.id, quiet.id)
        guard case .session(let draftID) = appViewModel.selection else {
            return XCTFail("an agent with no chats starts one")
        }
        XCTAssertNotEqual(draftID, older.id)
    }

    func testRailDropFindsTheTileUnderThePointer() {
        // 8 pt top padding, then 48 pt slots 4 pt apart.
        XCTAssertEqual(AgentRailDropDelegate.index(atY: 0, count: 3), 0)
        XCTAssertEqual(AgentRailDropDelegate.index(atY: 70, count: 3), 1)
        XCTAssertEqual(AgentRailDropDelegate.index(atY: 500, count: 3), 2)
        XCTAssertNil(AgentRailDropDelegate.index(atY: 30, count: 0))
    }

    // Reordering the rail moves the saved agent list, so the order lasts and ⌘1 to ⌘9 follow it.
    @MainActor
    func testRailReorderMovesTheSavedAgentList() {
        let suiteName = "SidebarViewTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create isolated UserDefaults suite")
        }
        defer { storage.removePersistentDomain(forName: suiteName) }
        let appViewModel = AppViewModel(
            storage: storage,
            localAgentDefinitions: [],
            resolveAgentEndpoint: { _ in throw ConnectOnionRemoteError.agentOffline }
        )
        let first = makeAgent(name: "First", suffix: "ab")
        let second = makeAgent(name: "Second", suffix: "cd")
        let third = makeAgent(name: "Third", suffix: "ef")
        appViewModel.configurations = [first, second, third]

        appViewModel.moveAgent(third.id, to: first.id)
        XCTAssertEqual(appViewModel.configurations.map(\.name), ["Third", "First", "Second"])

        appViewModel.moveAgent(third.id, to: second.id)
        XCTAssertEqual(appViewModel.configurations.map(\.name), ["First", "Second", "Third"])

        appViewModel.moveAgent(second.id, by: -1)
        XCTAssertEqual(appViewModel.configurations.map(\.name), ["Second", "First", "Third"])
        appViewModel.moveAgent(second.id, by: -1)
        XCTAssertEqual(appViewModel.configurations.map(\.name), ["Second", "First", "Third"], "held at the top")
    }

    @MainActor
    private func makeAgent(
        name: String,
        suffix: String
    ) -> GeneralAgentConfiguration {
        GeneralAgentConfiguration(
            name: name,
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: suffix, count: 32)
            )
        )
    }
}
