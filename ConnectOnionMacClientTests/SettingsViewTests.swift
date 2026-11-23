import AppKit
import ConnectOnionKit
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
                detail: "Relay"
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
    func testIdentitySettingsRendersThisDevicesAddressAndBothLinkRows() async throws {
        let store = makeIdentityStore()
        _ = try store.loadOrCreateIdentity()
        render(IdentitySettingsView(identityStore: store), width: 680, height: 260)
        render(IdentitySettingsView(identityStore: makeIdentityStore()), width: 1_100, height: 260)
        XCTAssertEqual(DeviceLinkRole.giving.settingsTitle, "Link a new device")
        XCTAssertEqual(DeviceLinkRole.receiving.settingsTitle, "Link from another device")
    }

    // The typed-code entry a Mac switches to; it waits for a Link Code, so rendering it opens no listener.
    @MainActor
    func testDeviceLinkSheetRendersTheTypedCodeEntry() async {
        render(
            DeviceLinkSheet(
                role: .giving,
                keyStore: InMemoryPrivateKeyStore(),
                displaysCode: false,
                handlers: DeviceLinkHandlers()
            ),
            width: 460,
            height: 560
        )
    }

    @MainActor
    func testEachSettingsTabRenders() async {
        render(GeneralSettingsView(), width: 700, height: 580)
        render(LocalAgentsSettingsView(dockerRuntime: .shared, appViewModel: makeAppViewModel()), width: 700, height: 580)
        render(AgentsSettingsView(appViewModel: makeAppViewModel()), width: 700, height: 580)
    }

    func testAgentRowStatusSaysHowTheAgentIsReached() {
        let direct = AgentConnectionSnapshot(state: .online, route: .direct, remoteName: nil, tools: [], detail: nil)
        let relay = AgentConnectionSnapshot(state: .online, route: .relay, remoteName: nil, tools: [], detail: nil)
        XCTAssertEqual(AgentSettingsRow.statusLabel(for: direct), "Online \u{00B7} Direct")
        XCTAssertEqual(AgentSettingsRow.statusLabel(for: relay), "Online \u{00B7} Relay")
        XCTAssertEqual(AgentSettingsRow.statusLabel(for: nil), "Checking")
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
        var editingAgentState = SidebarViewInitialState()
        editingAgentState.editingAgentId = primaryAgent.id
        editingAgentState.editingAgentName = "Renamed Agent"
        var editingSessionState = SidebarViewInitialState()
        editingSessionState.editingSessionId = currentSession.id
        editingSessionState.editingSessionTitle = "Renamed Chat"
        var searchState = SidebarViewInitialState()
        searchState.searchText = "missing agent"
        let states = [
            hoveredState,
            editingAgentState,
            editingSessionState,
            searchState
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
        let view = SettingsView(
            appViewModel: appViewModel,
            usageStore: UsageStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
            ),
            identityStore: makeIdentityStore()
        )
        render(view, width: width, height: 760)
    }

    private func makeIdentityStore() -> ConnectOnionIdentityStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsViewTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ConnectOnionIdentityStore(identityFileURL: directory.appendingPathComponent("identity"))
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
