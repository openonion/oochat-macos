//
//  SettingsView.swift
//  ConnectOnionMacClient
//
//  Created by hym on 30/6/2026.
//

import ConnectOnionKit
import SwiftUI

/// The Settings window, opened with ⌘, or the gear at the foot of the agent rail. One tab for
/// each part of the app, as a Mac app's settings are laid out.
struct SettingsView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var usageStore: UsageStore
    var identityStore: ConnectOnionIdentityStore = .shared

    var body: some View {
        TabView {
            GeneralSettingsView()
                .frame(height: SettingsWindow.generalHeight)
                .tabItem { Label("General", systemImage: "gearshape") }

            SettingsScrollPage {
                IdentitySettingsView(identityStore: identityStore, handlers: appViewModel.deviceLinkHandlers)
            }
            .frame(height: SettingsWindow.identityHeight)
            .tabItem { Label("Identity", systemImage: "person.badge.key") }

            AgentsSettingsView(appViewModel: appViewModel)
                .frame(height: SettingsWindow.agentsHeight)
                .tabItem { Label("Agents", systemImage: "person.2") }

            BalanceView(appViewModel: appViewModel)
                .frame(height: SettingsWindow.walletHeight)
                .tabItem { Label("Wallet", systemImage: "wallet.pass") }

            LocalAgentsSettingsView(dockerRuntime: .shared, appViewModel: appViewModel)
                .frame(height: SettingsWindow.localAgentsHeight)
                .tabItem { Label("Local Agents", systemImage: "shippingbox") }

            UsageView(store: usageStore)
                .frame(height: SettingsWindow.usageHeight)
                .tabItem { Label("Usage", systemImage: "chart.bar.xaxis") }
        }
        .frame(width: SettingsWindow.width)
        .tint(OOColor.primary)
    }
}

/// The Settings window's size. Grouped forms scroll and have no height of their own, so each tab
/// names one; the window takes it, as the system's own Settings does per pane.
enum SettingsWindow {
    static let width: CGFloat = 700
    static let generalHeight: CGFloat = 300
    /// Tall enough for the device link sheet (560 pt), which opens over this tab.
    static let identityHeight: CGFloat = 600
    static let agentsHeight: CGFloat = 420
    static let walletHeight: CGFloat = 500
    static let localAgentsHeight: CGFloat = 320
    static let usageHeight: CGFloat = 620
}

/// A tab whose content is taller than the window: it scrolls, on the app's background.
struct SettingsScrollPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .padding(OOSpace.xLarge)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AppBackground())
    }
}

/// Appearance and the size of chat text.
struct GeneralSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage(ChatFontSize.storageKey) private var fontSize = ChatFontSize.standard

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Follow the system, or always use light or dark.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Slider(value: $fontSize, in: ChatFontSize.range, step: 1) {
                    Text("Chat text size")
                } minimumValueLabel: {
                    Text("A")
                        .font(.system(size: 11))
                        .accessibilityHidden(true)
                } maximumValueLabel: {
                    Text("A")
                        .font(.system(size: 17))
                        .accessibilityHidden(true)
                }
                .accessibilityValue("\(Int(fontSize)) points")

                Text("The quick brown fox replies in \(Int(fontSize)) pt.")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } footer: {
                HStack {
                    Text("View \u{25B8} Bigger (\u{2318}=) and Smaller (\u{2318}\u{2212}) change it too.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        fontSize = ChatFontSize.standard
                    }
                    .disabled(fontSize == ChatFontSize.standard)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// What a Device Link does to this Mac's agents and chats. `AppViewModel.deviceLinkHandlers` builds the
/// real set; the defaults do nothing, for previews and tests.
struct DeviceLinkHandlers {
    /// Giving: this Mac's Agent Name list, sent with the Identity.
    var agentNames: @MainActor () -> [DeviceLinkAgentName] = { [] }
    /// Receiving: the giver's Agent Name list, right after the key is replaced.
    var applyAgentNames: @MainActor ([DeviceLinkAgentName]) -> Void = { _ in }
    /// Receiving: the key was replaced; gets the Address it replaced so old chats can be stamped.
    var replaced: @MainActor (_ previousAddress: String) -> Void = { _ in }
    /// Giving: this Mac marked itself linked.
    var linked: @MainActor () -> Void = {}
}

/// This device's Address, and the two ways to link it with another of the person's devices.
struct IdentitySettingsView: View {
    let identityStore: ConnectOnionIdentityStore
    let handlers: DeviceLinkHandlers
    @State private var address: String?
    @State private var linkRole: DeviceLinkRole?

    init(identityStore: ConnectOnionIdentityStore, handlers: DeviceLinkHandlers = DeviceLinkHandlers()) {
        self.identityStore = identityStore
        self.handlers = handlers
        _address = State(initialValue: try? identityStore.loadOrCreateIdentity().address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Identity")
                    .font(.system(size: AppFontSize.sectionTitle, weight: .semibold))

                Text("The Address your agents know you by, shared by every device you link")
                    .font(.system(size: AppFontSize.body))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("This device")
                        .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                    Spacer()
                    if let address {
                        OOAddressLabel(address, name: "Your address")
                    }
                }
                .padding(18)

                ForEach([DeviceLinkRole.giving, .receiving], id: \.self) { role in
                    Divider()
                        .opacity(0.5)
                    linkRow(role)
                }
            }
            .cardStyle(cornerRadius: 12)
        }
        .sheet(
            isPresented: Binding(
                get: { linkRole != nil },
                set: { isPresented in
                    if !isPresented {
                        linkRole = nil
                    }
                }
            )
        ) {
            if let linkRole {
                DeviceLinkSheet(role: linkRole, keyStore: identityStore, handlers: handlersRefreshingAddress)
            }
        }
    }

    private func linkRow(_ role: DeviceLinkRole) -> some View {
        Button {
            linkRole = role
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(role.settingsTitle)
                        .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(role.settingsDetail)
                        .font(.system(size: AppFontSize.body))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: AppFontSize.body, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The same handlers, plus showing the new Address here once the key is replaced.
    private var handlersRefreshingAddress: DeviceLinkHandlers {
        var handlers = handlers
        let replaced = handlers.replaced
        handlers.replaced = { previousAddress in
            replaced(previousAddress)
            refreshAddress()
        }
        return handlers
    }

    private func refreshAddress() {
        address = try? identityStore.loadOrCreateIdentity().address
    }
}

/// Mac sheet chrome around the Kit's link view. Each presentation makes its own flow; closing the
/// sheet (Cancel, Escape, or a "no" inside the flow) cancels the link. Both roles open on this Mac's
/// own code, since a Mac never scans; "Type a code instead" is there for linking two Macs.
struct DeviceLinkSheet: View {
    let role: DeviceLinkRole
    @State private var flow: DeviceLinkFlow
    @Environment(\.dismiss) private var dismiss

    init(
        role: DeviceLinkRole,
        keyStore: any DeviceLinkKeyStore,
        displaysCode: Bool = true,
        handlers: DeviceLinkHandlers
    ) {
        self.role = role
        _flow = State(initialValue: DeviceLinkFlow(
            role: role,
            keyStore: keyStore,
            displaysCode: displaysCode,
            onReplaced: handlers.replaced,
            onLinked: handlers.linked,
            agentNames: handlers.agentNames,
            onAgentNames: handlers.applyAgentNames
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(role.settingsTitle)
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            DeviceLinkView(flow: flow)
        }
        .frame(width: 460, height: 560)
    }
}

/// Every saved agent: its name, address, how it's reached, and Rename, Refresh and Remove.
/// Rename and Remove do what the agent pane's header does.
struct AgentsSettingsView: View {
    @ObservedObject var appViewModel: AppViewModel

    @State private var agentPendingRemoval: GeneralAgentConfiguration?
    @State private var agentBeingRenamed: GeneralAgentConfiguration?
    @State private var draftName = ""

    var body: some View {
        Form {
            if appViewModel.configurations.isEmpty {
                Section {
                    Text("No agents yet. Use Add agent on the rail (\u{21E7}\u{2318}N) to connect one.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(appViewModel.configurations) { configuration in
                        AgentSettingsRow(
                            configuration: configuration,
                            snapshot: appViewModel.agentConnectionSnapshots[configuration.id],
                            rename: {
                                draftName = configuration.name
                                agentBeingRenamed = configuration
                            },
                            refresh: {
                                appViewModel.refreshAgentStatus(for: configuration)
                            },
                            remove: {
                                agentPendingRemoval = configuration
                            }
                        )
                    }
                } footer: {
                    Text("Statuses refresh every 30 seconds while this tab is open.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            appViewModel.refreshAgentStatuses(trigger: .poll)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                appViewModel.refreshAgentStatuses(trigger: .poll)
            }
        }
        .removeAgentConfirmation($agentPendingRemoval, appViewModel: appViewModel)
        .alert(
            "Rename agent",
            isPresented: Binding(
                get: { agentBeingRenamed != nil },
                set: { isPresented in
                    if !isPresented {
                        agentBeingRenamed = nil
                    }
                }
            ),
            presenting: agentBeingRenamed
        ) { configuration in
            TextField("Agent name", text: $draftName)
            Button("Rename") {
                appViewModel.renameAgent(configuration, to: draftName)
                agentBeingRenamed = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                agentBeingRenamed = nil
            }
        }
    }
}

/// One agent in the Agents tab.
struct AgentSettingsRow: View {
    let configuration: GeneralAgentConfiguration
    let snapshot: AgentConnectionSnapshot?
    let rename: () -> Void
    let refresh: () -> Void
    let remove: () -> Void

    @State private var didCopy = false

    private var address: String? {
        configuration.addressConfiguration?.agentAddress
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(configuration.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Self.statusColor(for: snapshot))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(Self.statusLabel(for: snapshot))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let address, !address.isEmpty {
                    HStack(spacing: 6) {
                        Text(address)
                            .font(AppTypography.mono(size: AppFontSize.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button(didCopy ? "Copied" : "Copy") {
                            copy(address)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .frame(minWidth: macMinimumTarget, minHeight: macMinimumTarget)
                        .contentShape(Rectangle())
                        .accessibilityLabel(didCopy ? "Address copied" : "Copy \(configuration.name)'s address")
                    }
                }

                if let detail = snapshot?.detail, snapshot?.state == .offline || snapshot?.state == .invalid {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            Button("Rename", action: rename)
                .accessibilityLabel("Rename \(configuration.name)")

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh status")
            .accessibilityLabel("Refresh \(configuration.name)'s status")

            Menu {
                Button("Remove agent\u{2026}", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More for \(configuration.name)")
        }
        .padding(.vertical, 4)
    }

    private func copy(_ address: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }

    static func statusLabel(for snapshot: AgentConnectionSnapshot?) -> String {
        switch snapshot?.state {
        case .online:
            return snapshot?.route == .direct ? "Online \u{00B7} Direct" : "Online \u{00B7} Relay"
        case .offline:
            return "Offline"
        case .invalid:
            return "Invalid"
        case .checking, .none:
            return "Checking"
        }
    }

    static func statusColor(for snapshot: AgentConnectionSnapshot?) -> Color {
        switch snapshot?.state {
        case .online:
            return OOColor.live
        case .invalid:
            return OOColor.decisionMark
        case .offline:
            return OOColor.failureText
        case .checking, .none:
            return .secondary
        }
    }
}

/// Docker on this Mac: whether it runs agents here, and the runtime .env they read.
struct LocalAgentsSettingsView: View {
    @ObservedObject var dockerRuntime: DockerRuntimeManager
    @ObservedObject var appViewModel: AppViewModel
    /// nil until the toggle is used; until then local agents on this Mac decide, as in the Docker menu.
    @AppStorage(LocalAgentsSetting.storageKey) private var runsLocalAgents: Bool?
    /// This window's own: the Docker menu's restart asks in the chat window instead.
    @State private var isConfirmingRestart = false

    private var isOn: Binding<Bool> {
        LocalAgentsSetting.binding(runsLocalAgents, runtime: dockerRuntime)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: isOn) {
                    Text("Run agents on this Mac")
                    Text("Starts Docker when you first open a chat, and stops it when oo-chat quits.")
                }
                .toggleStyle(.switch)
            }

            Section {
                LabeledContent("Runtime .env") {
                    Text(dockerRuntime.configurationFilePath)
                        .font(AppTypography.mono(size: AppFontSize.footnote))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        dockerRuntime.revealConfigurationFile()
                    }
                    Button("Copy Path") {
                        dockerRuntime.copyConfigurationPath()
                    }
                    Spacer()
                    if dockerRuntime.status.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Apply and Restart\u{2026}") {
                        isConfirmingRestart = true
                    }
                    .disabled(dockerRuntime.status.isBusy || !isOn.wrappedValue)
                }

                if let message = dockerRuntime.configurationActionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(dockerRuntime.status.isError ? OOColor.failureText : .secondary)
                }
            } header: {
                Text("Docker configuration")
            } footer: {
                Text("Add provider API keys to the runtime .env, then apply it to restart every local agent.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .restartAgentsConfirmation(
            isPresented: $isConfirmingRestart,
            dockerRuntime: dockerRuntime,
            appViewModel: appViewModel
        )
    }
}

/// What the restart prompt says: how many agents, and whether a reply is running right now.
enum RestartAgentsWording {
    static func title(agentCount: Int) -> String {
        switch agentCount {
        case 0: return "Restart local agents?"
        case 1: return "Restart 1 agent?"
        default: return "Restart \(agentCount) agents?"
        }
    }

    static func message(isRunActive: Bool) -> String {
        isRunActive
            ? "A reply is running right now and will stop, along with any other running chats."
            : "Running chats will stop."
    }
}

extension View {
    /// "Restart 2 agents?", from the Docker menu or the Local Agents tab.
    func restartAgentsConfirmation(
        isPresented: Binding<Bool>,
        dockerRuntime: DockerRuntimeManager,
        appViewModel: AppViewModel
    ) -> some View {
        alert(
            RestartAgentsWording.title(agentCount: appViewModel.configurations.filter(\.isOnThisMac).count),
            isPresented: isPresented
        ) {
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Restart", role: .destructive) {
                Task {
                    await dockerRuntime.applyConfigurationAndRestart()
                }
            }
        } message: {
            Text(RestartAgentsWording.message(isRunActive: appViewModel.liveActivity.values.contains(.working)))
        }
    }
}
