//
//  SettingsView.swift
//  ConnectOnionMacClient
//
//  Created by hym on 30/6/2026.
//

import SwiftUI

/// Composes account, Docker, appearance, and agent management settings.
struct SettingsView: View {
    @Binding var appearanceMode: AppearanceMode
    @ObservedObject var appViewModel: AppViewModel

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

                        AccountTitleView()
                            .padding(.top, 12)

                        BalanceAndAddressView()

                        DockerConfigurationView(
                            dockerRuntime: DockerRuntimeManager.shared
                        )

                        AppearanceSettingsView(appearanceMode: $appearanceMode)

                        AgentsTitleView()
                            .padding(.top, 8)

                        AgentControlPanel(appViewModel: appViewModel)
                            .frame(maxWidth: .infinity)
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
}

/// Exposes the runtime `.env` and restarts Docker-managed agents after edits.
struct DockerConfigurationView: View {
    @ObservedObject var dockerRuntime: DockerRuntimeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Docker configuration")
                        .font(.system(size: AppFontSize.subheadline, weight: .semibold))

                    Text(
                        "Add provider API keys to the runtime .env, "
                            + "then apply the configuration to restart every Agent."
                    )
                    .font(.system(size: AppFontSize.body))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if dockerRuntime.status.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(dockerRuntime.configurationFilePath)
                .font(AppTypography.mono(size: AppFontSize.footnote))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button("Reveal .env") {
                    dockerRuntime.revealConfigurationFile()
                }
                .buttonStyle(.bordered)

                Button("Copy Path") {
                    dockerRuntime.copyConfigurationPath()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Apply & Restart") {
                    Task {
                        await dockerRuntime.applyConfigurationAndRestart()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(dockerRuntime.status.isBusy)
            }

            if let message = dockerRuntime.configurationActionMessage {
                Text(message)
                    .font(.system(size: AppFontSize.footnote))
                    .foregroundStyle(
                        dockerRuntime.status.isError ? AppPalette.error : .secondary
                    )
            }
        }
        .padding(18)
        .cardStyle(cornerRadius: 12)
    }
}

/// Labels the account and wallet settings section.
struct AccountTitleView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Account & Wallet")
                .font(.system(size: AppFontSize.sectionTitle, weight: .semibold))

            Text("Manage your ConnectOnion identity, credentials, and credits")
                .font(.system(size: AppFontSize.body))
                .foregroundColor(.secondary)
        }
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

/// Labels the connected-agent management section.
struct AgentsTitleView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agents")
                .font(.system(size: AppFontSize.sectionTitle, weight: .semibold))

            Text("Add and manage 0x addresses or Direct URLs")
                .font(.system(size: AppFontSize.body))
                .foregroundColor(.secondary)
        }
    }
}

/// Adds, edits, removes, and monitors address-based agent configurations.
struct AgentControlPanel: View {
    @ObservedObject var appViewModel: AppViewModel

    @State private var newAgentAddress = ""
    @State private var inputError: String?
    @State private var agentPendingDeletion: GeneralAgentConfiguration?
    @State private var avatarEditorConfigID: UUID?

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
            appViewModel.refreshAgentStatuses()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                appViewModel.refreshAgentStatuses()
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
            AgentAvatarView(
                name: configuration.name,
                textColorHex: configuration.avatarTextColorHex,
                backgroundColorHex: configuration.avatarBackgroundColorHex,
                size: 40
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
                    Text(displayName(for: configuration, snapshot: snapshot))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(statusLabel(for: snapshot))
                        .font(.system(size: AppFontSize.footnote, weight: .semibold))
                        .foregroundStyle(statusColor(for: snapshot))
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
                    .foregroundColor(.secondary.opacity(0.7))
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
            avatarEditorConfigID = configuration.id
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary.opacity(0.7))
        .accessibilityLabel("Edit agent avatar colors")
        .help("Edit avatar colors")
        .popover(
            isPresented: Binding(
                get: { avatarEditorConfigID == configuration.id },
                set: { isPresented in
                    if !isPresented {
                        avatarEditorConfigID = nil
                    }
                }
            )
        ) {
            avatarEditor(for: configuration)
        }

        Button {
            appViewModel.refreshAgentStatus(for: configuration)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: AppFontSize.subheadline, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary.opacity(0.7))
        .accessibilityLabel("Refresh agent status")
        .help("Refresh status")

        Button {
            agentPendingDeletion = configuration
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary.opacity(0.7))
        .accessibilityLabel("Remove agent")
        .help("Remove agent")
    }

    private func avatarEditor(for configuration: GeneralAgentConfiguration) -> some View {
        let current = currentConfiguration(for: configuration)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AgentAvatarView(
                    name: current.name,
                    textColorHex: current.avatarTextColorHex,
                    backgroundColorHex: current.avatarBackgroundColorHex,
                    size: 48
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent avatar")
                        .font(.headline)
                    Text("\(current.name) initials")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ColorPicker(
                "Initial color",
                selection: avatarTextColorBinding(for: configuration),
                supportsOpacity: false
            )

            ColorPicker(
                "Background color",
                selection: avatarBackgroundColorBinding(for: configuration),
                supportsOpacity: false
            )

            Button("Reset to black and white") {
                appViewModel.updateAgentAvatar(
                    current,
                    textColorHex: nil,
                    backgroundColorHex: nil
                )
            }
            .buttonStyle(.borderless)
        }
        .padding(18)
        .frame(width: 260)
    }

    private func avatarTextColorBinding(
        for configuration: GeneralAgentConfiguration
    ) -> Binding<Color> {
        Binding(
            get: {
                let current = currentConfiguration(for: configuration)
                return AgentAvatarStyle.textColor(from: current.avatarTextColorHex)
            },
            set: { color in
                let current = currentConfiguration(for: configuration)
                appViewModel.updateAgentAvatar(
                    current,
                    textColorHex: color.hexString,
                    backgroundColorHex: current.avatarBackgroundColorHex
                )
            }
        )
    }

    private func avatarBackgroundColorBinding(
        for configuration: GeneralAgentConfiguration
    ) -> Binding<Color> {
        Binding(
            get: {
                let current = currentConfiguration(for: configuration)
                return AgentAvatarStyle.backgroundColor(from: current.avatarBackgroundColorHex)
            },
            set: { color in
                let current = currentConfiguration(for: configuration)
                appViewModel.updateAgentAvatar(
                    current,
                    textColorHex: current.avatarTextColorHex,
                    backgroundColorHex: color.hexString
                )
            }
        )
    }

    private func currentConfiguration(
        for configuration: GeneralAgentConfiguration
    ) -> GeneralAgentConfiguration {
        appViewModel.configurations.first { $0.id == configuration.id } ?? configuration
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

    private func displayName(
        for configuration: GeneralAgentConfiguration,
        snapshot: AgentConnectionSnapshot?
    ) -> String {
        if let remoteName = snapshot?.remoteName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteName.isEmpty {
            return remoteName
        }
        return configuration.name
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
