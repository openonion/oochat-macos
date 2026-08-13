import AppKit
import SwiftUI
import XCTest
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
