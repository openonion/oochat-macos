//
//  SettingsView.swift
//  ConnectOnionMacClient
//
//  Created by hym on 30/6/2026.
//

import ConnectOnionKit
import SwiftUI

/// Composes account, identity, Docker, appearance, and agent management settings.
struct SettingsView: View {
    @Binding var appearanceMode: AppearanceMode
    @ObservedObject var appViewModel: AppViewModel
    @State private var hoveredUsage = false
    @State private var hoveredBalance = false
    @State private var hoveredIdentity = false
    @State private var hoveredAgent = false

    let onBack: () -> Void

    var body: some View {
        ZStack {
            AppBackground()

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 12) {
                            Button(action: onBack) {
                                Image(systemName: "arrow.left")
                                    .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 28, height: 28)
                                    .background(AppPalette.surfaceMuted)
                                    .clipShape(Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back")
                            .help("Back")

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Settings")
                                    .font(.system(size: AppFontSize.pageTitle, weight: .semibold))

                                Text("Manage your account, appearance, wallet, and agents.")
                                    .font(.system(size: AppFontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        usageButton

                        balanceButton

                        identityButton

                        // BalanceView(appViewModel: appViewModel)

                        agentButton

                        // AgentControlPanel(appViewModel: appViewModel)
                        //     .frame(maxWidth: .infinity)

                        AppearanceSettingsView(appearanceMode: $appearanceMode)
                    }
                    .frame(maxWidth: 920, alignment: .leading)
                    .padding(.horizontal, geometry.size.width < 760 ? 20 : 32)
                    .padding(.top, 32)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle("Settings")
    }

    private var usageButton: some View {
        Button {
            guard appViewModel.selection != .usage else { return }
            appViewModel.previousSelection = appViewModel.selection
            appViewModel.selection = .usage
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: AppFontSize.subheadline, weight: .medium))
                Text("Usage")
                    .font(.system(size: AppFontSize.body, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        appViewModel.selection == .usage
                            ? OOColor.hover
                            : (hoveredUsage ? OOColor.surface : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredUsage = isHovering
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Usage")
        .help("View local model usage")
    }

    private var balanceButton: some View {
        Button {
            guard appViewModel.selection != .balance else { return }
            appViewModel.previousSelection = appViewModel.selection
            appViewModel.selection = .balance
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wallet.pass")
                    .font(.system(size: AppFontSize.subheadline, weight: .medium))
                Text("Wallet and Docker")
                    .font(.system(size: AppFontSize.body, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        appViewModel.selection == .balance
                            ? OOColor.hover
                            : (hoveredBalance ? OOColor.surface : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredBalance = isHovering
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Usage")
        .help("View local model usage")
    }

    private var identityButton: some View {
        Button {
            guard appViewModel.selection != .identity else { return }
            appViewModel.previousSelection = appViewModel.selection
            appViewModel.selection = .identity
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: AppFontSize.subheadline, weight: .medium))
                Text("Identity")
                    .font(.system(size: AppFontSize.body, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        appViewModel.selection == .identity
                            ? OOColor.hover
                            : (hoveredIdentity ? OOColor.surface : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredIdentity = isHovering
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Identity")
        .help("View your Address and link devices")
    }

    private var agentButton: some View {
        Button {
            guard appViewModel.selection != .chooseAgent else { return }
            appViewModel.previousSelection = appViewModel.selection
            appViewModel.selection = .chooseAgent
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person")
                    .font(.system(size: AppFontSize.subheadline, weight: .medium))
                Text("Manage Agents")
                    .font(.system(size: AppFontSize.body, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        appViewModel.selection == .chooseAgent
                            ? OOColor.hover
                            : (hoveredAgent ? OOColor.surface : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredAgent = isHovering
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Agents")
        .help("View and manage agents")
    }
}

/// Settings sub-page holding the Identity section, laid out like the Wallet and Usage pages.
struct IdentityView: View {
    @ObservedObject var appViewModel: AppViewModel
    var identityStore: ConnectOnionIdentityStore = .shared
    let onBack: () -> Void

    var body: some View {
        ZStack {
            AppBackground()

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 12) {
                            Button(action: onBack) {
                                Image(systemName: "arrow.left")
                                    .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 28, height: 28)
                                    .background(AppPalette.surfaceMuted)
                                    .clipShape(Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back")
                            .help("Back")

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Settings")
                                    .font(.system(size: AppFontSize.pageTitle, weight: .semibold))

                                Text("Manage your Address and linked devices")
                                    .font(.system(size: AppFontSize.body))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        IdentitySettingsView(
                            identityStore: identityStore,
                            handlers: appViewModel.deviceLinkHandlers
                        )
                    }
                    .frame(maxWidth: 920, alignment: .leading)
                    .padding(.horizontal, geometry.size.width < 760 ? 20 : 32)
                    .padding(.top, 32)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle("Identity")
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

/// Lets the user follow macOS appearance or force a light or dark theme.
struct AppearanceSettingsView: View {
    @Binding var appearanceMode: AppearanceMode

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Appearance")
                    .font(.system(size: AppFontSize.subheadline, weight: .semibold))

                Text("Follow the system, or always use light or dark")
                    .font(.system(size: AppFontSize.body))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Picker("Appearance", selection: $appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
        .padding(18)
        .cardStyle(cornerRadius: 12)
    }
}

/// Adds, edits, removes, and monitors address-based agent configurations.
struct AgentControlPanel: View {
    @ObservedObject var appViewModel: AppViewModel

    @State private var newAgentAddress = ""
    @State private var inputError: String?
    @State private var agentPendingDeletion: GeneralAgentConfiguration?

    private var addressAgents: [GeneralAgentConfiguration] {
        appViewModel.configurations.filter { configuration in
            configuration.connectionType == .byAddress
                && configuration.addressConfiguration != nil
        }
    }

    private var trimmedNewAgentAddress: String {
        newAgentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddAgent: Bool {
        guard let normalizedTarget = ConnectOnionAgentTarget.normalized(
            trimmedNewAgentAddress
        ) else {
            return false
        }

        return !addressAgents.contains { configuration in
            guard let target = configuration.addressConfiguration?.agentAddress else {
                return false
            }
            return ConnectOnionAgentTarget.normalized(target) == normalizedTarget
        }
    }

    private var addressInputMessage: String? {
        if let inputError {
            return inputError
        }
        guard !trimmedNewAgentAddress.isEmpty else {
            return nil
        }
        guard let normalizedTarget = ConnectOnionAgentTarget.normalized(
            trimmedNewAgentAddress
        ) else {
            return "Enter a valid 0x address or HTTP(S) Direct URL."
        }
        let isDuplicate = addressAgents.contains { configuration in
            guard let target = configuration.addressConfiguration?.agentAddress else {
                return false
            }
            return ConnectOnionAgentTarget.normalized(target) == normalizedTarget
        }
        return isDuplicate ? "This agent is already connected." : nil
    }

    private var addButtonColor: Color {
        if canAddAgent {
            return AppPalette.primaryAction
        } else {
            return Color.secondary.opacity(0.35)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if addressAgents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text("No agents yet")
                        .font(.system(size: 16, weight: .semibold))

                    Text("Paste a 0x address or HTTP(S) Direct URL below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(addressAgents) { configuration in
                        agentRow(configuration)

                        if configuration.id != addressAgents.last?.id {
                            Divider()
                                .padding(.leading, 98)
                                .opacity(0.5)
                        }
                    }
                }
            }

            Divider()
                .opacity(0.5)

            HStack(spacing: 16) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(width: 32)

                TextField(
                    "0x address or https://…",
                    text: $newAgentAddress
                )
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Agent address or Direct URL")
                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                    .padding(.horizontal, 22)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(AppPalette.divider, lineWidth: 1)
                            )
                    )

                Button("Add") {
                    addAgent()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppPalette.primaryActionForeground)
                .frame(width: 86, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(addButtonColor)
                )
                .buttonStyle(.plain)
                .disabled(!canAddAgent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            if let addressInputMessage {
                Text(addressInputMessage)
                    .font(.caption)
                    .foregroundStyle(AppPalette.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 88)
                    .padding(.bottom, 14)
            }
        }
        .cardStyle(cornerRadius: 12)
        .onChange(of: newAgentAddress) {
            inputError = nil
        }
        .task {
            appViewModel.refreshAgentStatuses(trigger: .poll)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                appViewModel.refreshAgentStatuses(trigger: .poll)
            }
        }
        .alert(
            "Remove agent?",
            isPresented: Binding(
                get: { agentPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        agentPendingDeletion = nil
                    }
                }
            ),
            presenting: agentPendingDeletion
        ) { configuration in
            Button("Cancel", role: .cancel) {
                agentPendingDeletion = nil
            }
            Button("Remove", role: .destructive) {
                appViewModel.deleteConfiguration(configuration)
                agentPendingDeletion = nil
            }
        } message: { configuration in
            Text("Removing \(configuration.name) also deletes its chats and messages.")
        }
    }

    private func agentRow(_ configuration: GeneralAgentConfiguration) -> some View {
        let address = configuration.addressConfiguration?.agentAddress ?? ""
        let snapshot = appViewModel.agentConnectionSnapshots[configuration.id]

        return HStack(alignment: .top, spacing: 24) {
            OOAvatarTile(
                name: configuration.name,
                address: address,
                size: .large
            )
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(statusColor(for: snapshot))
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle()
                            .stroke(AppPalette.surface, lineWidth: 2)
                    }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(configuration.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(statusLabel(for: snapshot))
                        .font(.system(size: AppFontSize.footnote, weight: .semibold))
                        .foregroundStyle(
                            snapshot?.state == .invalid ? AppPalette.warningText : statusColor(for: snapshot)
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(statusColor(for: snapshot).opacity(0.1))
                        )
                }

                HStack(spacing: 10) {
                    Text(address)
                        .font(.system(size: AppFontSize.subheadline, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: AppFontSize.body, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(OOColor.inkSecondary)
                    .accessibilityLabel("Copy agent address")
                    .help("Copy agent address")
                }

                capabilitySummary(for: snapshot)

                if let detail = snapshot?.detail,
                   snapshot?.state == .offline || snapshot?.state == .invalid {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 16)

            agentActionButtons(for: configuration)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func agentActionButtons(
        for configuration: GeneralAgentConfiguration
    ) -> some View {
        Button {
            appViewModel.refreshAgentStatus(for: configuration)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: AppFontSize.subheadline, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(OOColor.inkSecondary)
        .accessibilityLabel("Refresh agent status")
        .help("Refresh status")

        Button {
            agentPendingDeletion = configuration
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(OOColor.inkSecondary)
        .accessibilityLabel("Remove agent")
        .help("Remove agent")
    }

    @ViewBuilder
    private func capabilitySummary(for snapshot: AgentConnectionSnapshot?) -> some View {
        let tools = snapshot?.tools ?? []

        if !tools.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(tools.prefix(5)), id: \.self) { tool in
                        Text(tool)
                            .font(.system(size: AppFontSize.caption, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.secondary.opacity(0.07))
                            )
                    }

                    if tools.count > 5 {
                        Text("+\(tools.count - 5) more")
                            .font(.system(size: AppFontSize.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if snapshot?.state == .online && snapshot?.route == .relay {
            Text("Capabilities unavailable through relay")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusLabel(for snapshot: AgentConnectionSnapshot?) -> String {
        switch snapshot?.state {
        case .online:
            return snapshot?.route == .direct ? "Online · Direct" : "Online · Relay"
        case .offline:
            return "Offline"
        case .invalid:
            return "Invalid"
        case .checking, .none:
            return "Checking"
        }
    }

    private func statusColor(for snapshot: AgentConnectionSnapshot?) -> Color {
        switch snapshot?.state {
        case .online:
            return AppPalette.success
        case .invalid:
            return AppPalette.warning
        case .offline:
            return AppPalette.error
        case .checking, .none:
            return .secondary
        }
    }

    private func addAgent() {
        switch appViewModel.addAgent(trimmedNewAgentAddress) {
        case .added:
            newAgentAddress = ""
            inputError = nil
        case .duplicate:
            inputError = "This agent is already connected."
        case .invalid:
            inputError = "Enter a valid 0x address or HTTP(S) Direct URL."
        }
    }
}

#Preview {
    ContentView()
}
