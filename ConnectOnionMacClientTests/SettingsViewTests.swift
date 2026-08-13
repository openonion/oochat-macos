import AppKit
import SwiftUI
import XCTest
@testable import ConnectOnionMacClient

final class SettingsViewTests: XCTestCase {
    @MainActor
    func testSettingsViewRendersEmptyAgentStateAtDifferentWidths() async {
        let appViewModel = makeAppViewModel()
        renderSettings(appViewModel: appViewModel, width: 680)
        renderSettings(appViewModel: appViewModel, width: 1_100)
    }

    @MainActor
    func testSettingsViewRendersAgentConnectionStatesAndCapabilities() async {
        let appViewModel = makeAppViewModel()
        let direct = addressAgent(name: "Direct", suffix: "ab")
        let relay = addressAgent(name: "Relay", suffix: "bc")
        let offline = addressAgent(name: "Offline", suffix: "cd")
        let invalid = addressAgent(name: "Invalid", suffix: "de")
        appViewModel.configurations = [direct, relay, offline, invalid]
        appViewModel.agentConnectionSnapshots = [
            direct.id: AgentConnectionSnapshot(
                state: .online,
                route: .direct,
                remoteName: "Remote Direct Agent",
                tools: ["read_file", "glob", "grep", "edit", "write", "bash"],
                detail: "Direct endpoint"
            ),
            relay.id: AgentConnectionSnapshot(
                state: .online,
                route: .relay,
                remoteName: nil,
                tools: [],
                detail: "ConnectOnion relay"
            ),
            offline.id: AgentConnectionSnapshot(
                state: .offline,
                route: nil,
                remoteName: nil,
                tools: [],
                detail: "Agent is offline"
            ),
            invalid.id: AgentConnectionSnapshot(
                state: .invalid,
                route: nil,
                remoteName: nil,
                tools: [],
                detail: "Invalid address"
            )
        ]
        renderSettings(appViewModel: appViewModel, width: 1_100)
    }

    @MainActor
    func testAppearanceSettingsRendersEveryMode() async {
        for mode in AppearanceMode.allCases {
            var selectedMode = mode
            let view = AppearanceSettingsView(
                appearanceMode: Binding(
                    get: { selectedMode },
                    set: { selectedMode = $0 }
                )
            )
            render(view, width: 600, height: 100)
            XCTAssertEqual(selectedMode, mode)
        }
    }

    @MainActor
    func testAgentConnectHomeViewRendersAtDifferentWidths() {
        let appViewModel = makeAppViewModel()
        render(AgentConnectHomeView(appViewModel: appViewModel), width: 560, height: 720)
        render(AgentConnectHomeView(appViewModel: appViewModel), width: 1_100, height: 760)
    }

    @MainActor
    func testSidebarRendersEmptySearchHoverEditingAndDateStates() {
        let emptyViewModel = makeAppViewModel()
        render(
            SidebarView(appViewModel: emptyViewModel),
            width: 300,
            height: 760
        )

        let appViewModel = makeAppViewModel()
        let primaryAgent = addressAgent(name: "Primary Agent", suffix: "ab")
        let offlineAgent = addressAgent(name: "Offline Agent", suffix: "bc")
        let calendar = Calendar.current
        let today = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let older = calendar.date(byAdding: .day, value: -8, to: today) ?? today
        let currentSession = ChatSession(
            agentConfigId: primaryAgent.id,
            title: "Current chat",
            updatedAt: today
        )
        let yesterdaySession = ChatSession(
            agentConfigId: primaryAgent.id,
            title: "Yesterday chat",
            updatedAt: yesterday
        )
        let olderSession = ChatSession(
            agentConfigId: primaryAgent.id,
            title: "Older chat",
            updatedAt: older
        )
        appViewModel.configurations = [primaryAgent, offlineAgent]
        appViewModel.sessions = [olderSession, yesterdaySession, currentSession]
        appViewModel.selection = .session(currentSession.id)
        appViewModel.connectedConfigurationIds.insert(primaryAgent.id)

        var hoveredState = SidebarViewInitialState()
        hoveredState.hoveredConfigId = primaryAgent.id
        hoveredState.hoveredSessionId = currentSession.id
        hoveredState.hoveredNewChat = true
        hoveredState.hoveredSettings = true
        var editingAgentState = SidebarViewInitialState()
        editingAgentState.editingAgentId = primaryAgent.id
        editingAgentState.editingAgentName = "Renamed Agent"
        var editingSessionState = SidebarViewInitialState()
        editingSessionState.editingSessionId = currentSession.id
        editingSessionState.editingSessionTitle = "Renamed Chat"
        var searchState = SidebarViewInitialState()
        searchState.searchText = "missing agent"
        var collapsedState = SidebarViewInitialState()
        collapsedState.isAgentsSectionExpanded = false
        let states = [
            hoveredState,
            editingAgentState,
            editingSessionState,
            searchState,
            collapsedState
        ]

        for state in states {
            render(
                SidebarView(
                    appViewModel: appViewModel,
                    initialState: state
                ),
                width: 300,
                height: 760
            )
        }
    }

    @MainActor
    private func renderSettings(appViewModel: AppViewModel, width: CGFloat) {
        var appearanceMode = AppearanceMode.system
        let view = SettingsView(
            appearanceMode: Binding(
                get: { appearanceMode },
                set: { appearanceMode = $0 }
            ),
            appViewModel: appViewModel,
            onBack: {}
        )
        render(view, width: width, height: 760)
    }

    @MainActor
    private func makeAppViewModel() -> AppViewModel {
        let suiteName = "SettingsViewTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to create isolated UserDefaults suite")
        }
        storage.removePersistentDomain(forName: suiteName)
        return AppViewModel(
            storage: storage,
            resolveAgentEndpoint: { _ in
                throw ConnectOnionRemoteError.agentOffline
            }
        )
    }

    @MainActor
    private func addressAgent(name: String, suffix: String) -> GeneralAgentConfiguration {
        GeneralAgentConfiguration(
            name: name,
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: suffix, count: 32)
            )
        )
    }

    @MainActor
    private func render<V: View>(
        _ view: V,
        width: CGFloat,
        height: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hostingView = NSHostingView(
            rootView: view.frame(width: width, height: height)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.width, 0, file: file, line: line)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0, file: file, line: line)
    }
}
