import SwiftUI
import ConnectOnionKit
import AppKit

/// Owns app-level navigation, layout, appearance, and Docker runtime feedback.
struct ContentView: View {
    @StateObject private var appViewModel = AppViewModel()
    @StateObject private var usageStore: UsageStore
    @ObservedObject private var dockerRuntime = DockerRuntimeManager.shared

    @AppStorage("isDarkMode") private var isDarkMode = false
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("isSidebarVisible") private var isSidebarVisible = true

    @State private var showsOrphanAlert = false

    private let sidebarWidth: CGFloat = 300
    private let conversationMaxWidth: CGFloat = 768
    private let conversationHorizontalPadding: CGFloat = 24

    init() {
        _usageStore = StateObject(wrappedValue: UsageStore())

        // One-time migration from the legacy Dark Mode toggle: an explicit
        // choice (the key only exists once the toggle was used) is kept;
        // users who never touched it follow the system. Idempotent.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "appearanceMode") == nil,
           let legacyIsDarkMode = defaults.object(forKey: "isDarkMode") as? Bool {
            defaults.set(
                (legacyIsDarkMode ? AppearanceMode.dark : AppearanceMode.light).rawValue,
                forKey: "appearanceMode"
            )
        }
    }

    var body: some View {
        GeometryReader { windowGeometry in
            let centeredConversationWidth = conversationWidth(
                windowWidth: windowGeometry.size.width
            )

            ZStack {
                AppBackground()

                HStack(spacing: 0) {
                    if isSidebarVisible {
                        SidebarView(appViewModel: appViewModel)
                            .frame(width: sidebarWidth)
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(OOColor.hairline)
                                    .frame(width: 1)
                            }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    detailView(conversationWidth: centeredConversationWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .top) {
                dockerRuntimeBanner
            }
        }
        .tint(AppPalette.primaryAction)
        .onChange(of: appearanceMode, initial: true) { _, mode in
            NSApplication.shared.appearance = mode.nsAppearance
        }
        .task {
#if DEBUG
            await appViewModel.monitorLocalAgents()
#endif
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
        }
        .onChange(of: appViewModel.orphanedSessions) { _, sessions in
            if !sessions.isEmpty {
                showsOrphanAlert = true
            }
        }
        .alert(
            "Unresolved chats",
            isPresented: $showsOrphanAlert
        ) {
            Button("Keep Chats", role: .cancel) {}
            Button("Discard Chats", role: .destructive) {
                appViewModel.discardOrphanedSessions()
            }
        } message: {
            Text("\(appViewModel.orphanedSessions.count) chat(s) could not be matched to a current agent and are hidden. Reconnect the agent to restore them, or discard them.")
        }
    }

    @ViewBuilder
    private var dockerRuntimeBanner: some View {
        switch dockerRuntime.status {
        case .starting(let message):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.system(size: AppFontSize.footnote, weight: .medium))
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.top, 10)

        case .failed(let failure):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppPalette.error)
                Text(failure.message)
                    .font(.system(size: AppFontSize.footnote, weight: .medium))
                    .lineLimit(3)
                failureActions(for: failure)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 10)

        default:
            EmptyView()
        }
    }

    /// Offers the remediation that matches the failure: install Docker
    /// Desktop, start it, or update it. Every other error keeps plain Retry.
    @ViewBuilder
    private func failureActions(for failure: DockerStartupFailure) -> some View {
        switch failure.kind {
        case .dockerNotInstalled:
            dockerDownloadButton(title: "Get Docker Desktop")
            retryButton(title: "Check Again")

        case .dockerNotRunning:
            if let dockerDesktopURL {
                Button("Open Docker Desktop") {
                    NSWorkspace.shared.open(dockerDesktopURL)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            retryButton(title: "Retry")

        case .composeUnavailable:
            dockerDownloadButton(title: "Update Docker Desktop")
            retryButton(title: "Retry")

        case .other:
            retryButton(title: "Retry")
        }
    }

    private func dockerDownloadButton(title: String) -> some View {
        Button(title) {
            if let url = URL(string: Self.dockerDesktopDownloadAddress) {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private func retryButton(title: String) -> some View {
        Button(title) {
            Task {
                await dockerRuntime.start()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Resolves Docker Desktop wherever it is installed, not only
    /// /Applications, by asking Launch Services for its bundle identifier.
    private var dockerDesktopURL: URL? {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.docker.docker"
        )
    }

    private static let dockerDesktopDownloadAddress =
        "https://www.docker.com/products/docker-desktop/"

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSidebarVisible.toggle()
        }
    }

    @ViewBuilder
    private func detailView(conversationWidth: CGFloat) -> some View {
        if appViewModel.configurations.isEmpty,
           appViewModel.selection != .settings,
           appViewModel.selection != .usage {
            AgentConnectHomeView(appViewModel: appViewModel)
        } else {
            selectedDetailView(conversationWidth: conversationWidth)
        }
    }

    @ViewBuilder
    private func selectedDetailView(conversationWidth: CGFloat) -> some View {
        switch appViewModel.selection {
        case .session(let sessionId):
            if let session = appViewModel.sessions.first(where: { $0.id == sessionId }),
               let config = appViewModel.configuration(for: session) {
                let service = ConnectOnionService(
                    conversationID: session.id,
                    initialRemoteSessionID: session.remoteSessionID,
                    usageRecorder: usageStore
                )
                let chatViewModel = ChatViewModel(
                    session: session,
                    configuration: config,
                    service: service,
                    appViewModel: appViewModel
                )
                ChatView(
                    viewModel: chatViewModel,
                    conversationWidth: conversationWidth,
                    historySelectionRevision: appViewModel.sessionSelectionRevision
                )
                .id(session.id)
            } else {
                EmptyDetailView(systemImage: "questionmark.circle", message: "Session not found")
            }

        case .newConfiguration:
            AgentSettingsView(appViewModel: appViewModel)

        case .chooseAgent:
            ChooseAgentView(appViewModel: appViewModel)

        case .usage:
            UsageView(store: usageStore) {
                appViewModel.selection = appViewModel.previousSelection
            }

        case .settings:
            SettingsView(appearanceMode: $appearanceMode, appViewModel: appViewModel) {
                appViewModel.selection = appViewModel.previousSelection
            }

        case .none:
            ChooseAgentView(appViewModel: appViewModel)
        }
    }

    private func conversationWidth(windowWidth: CGFloat) -> CGFloat {
        // Match Codex's centered reading column: keep a stable 768pt width
        // whenever possible and shrink only when the detail pane is narrower.
        let sidebarLayoutWidth = isSidebarVisible ? sidebarWidth : 0
        let detailWidth = windowWidth - sidebarLayoutWidth
        let safeWidth = max(
            0,
            detailWidth - conversationHorizontalPadding * 2
        )
        return min(conversationMaxWidth, safeWidth)
    }

}

/// Provides the first-run entry point for connecting an agent by address.
struct AgentConnectHomeView: View {
    @ObservedObject var appViewModel: AppViewModel

    @State private var agentTarget = ""
    @State private var inputError: String?
    @FocusState private var isAddressFocused: Bool

    private var trimmedTarget: String {
        agentTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConnect: Bool {
        ConnectOnionAgentTarget.normalized(trimmedTarget) != nil
    }

    var body: some View {
        ZStack {
            OOColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: OOSpace.xxLarge)

                OOLogo.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .accessibilityLabel("OpenOnion")

                Text("Talk to any agent.")
                    .font(OOFont.headline(size: 48))
                    .tracking(-0.96) // web: tracking-[-0.02em] at 48 pt
                    .foregroundStyle(OOColor.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)

                Text("Paste its address — the conversation starts live.")
                    .font(.system(size: 15))
                    .foregroundStyle(OOColor.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .padding(.bottom, 28)

                VStack(spacing: 0) {
                    addressField
                    errorSlot
                    connectButton
                }
                .frame(maxWidth: 448) // web: max-w-md

                Spacer(minLength: OOSpace.xxLarge)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            isAddressFocused = true
        }
        .onChange(of: agentTarget) {
            inputError = nil
        }
    }

    private var addressField: some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
        let hasError = inputError != nil
        let border: Color = hasError
            ? OOColor.failureLine
            : (isAddressFocused ? OOColor.primary : OOColor.hairline)
        let ring: Color = isAddressFocused
            ? (hasError ? OOColor.failureFill : OOColor.currentTint)
            : .clear

        return TextField(
            "",
            text: $agentTarget,
            prompt: Text("Paste agent address (0x...)")
                .foregroundStyle(OOColor.inkSecondary)
        )
        .textFieldStyle(.plain)
        .font(OOFont.mono(size: 14))
        .foregroundStyle(OOColor.ink)
        .focused($isAddressFocused)
        .onSubmit(connectAgent)
        .padding(.horizontal, OOSpace.large)
        .frame(height: 50)
        .background(OOColor.paper, in: shape)
        .overlay(shape.stroke(border, lineWidth: 1))
        // web: focus:ring-[3px], drawn outside the border
        .background(shape.inset(by: -1.5).stroke(ring, lineWidth: 3))
        .accessibilityLabel("Agent address")
    }

    /// Fixed-height slot so the column doesn't jump when the error appears.
    private var errorSlot: some View {
        Text(inputError ?? "")
            .font(.system(size: 14))
            .foregroundStyle(OOColor.failureText)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
            .padding(.top, 4)
            .accessibilityHidden(inputError == nil)
    }

    private var connectButton: some View {
        Button(action: connectAgent) {
            Text("Connect")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.ooPrimary)
        .disabled(trimmedTarget.isEmpty)
        .padding(.top, 4)
    }

    private func connectAgent() {
        guard canConnect else {
            inputError = "Enter a valid 0x address or HTTP(S) Direct URL."
            return
        }

        switch appViewModel.addAgent(trimmedTarget) {
        case .added(let configuration):
            appViewModel.createNewSession(for: configuration)
        case .duplicate:
            inputError = "This agent has already been added."
        case .invalid:
            inputError = "Enter a valid 0x address or HTTP(S) Direct URL."
        }
    }
}

/// Lets users select a saved agent or add another one.
struct ChooseAgentView: View {
    @ObservedObject var appViewModel: AppViewModel

    @State private var isAddingAgent = false
    @State private var agentTarget = ""
    @State private var inputError: String?
    @State private var isHoveringAddAnother = false

    @FocusState private var isAddressFieldFocused: Bool

    private var trimmedTarget: String {
        agentTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddAgent: Bool {
        ConnectOnionAgentTarget.normalized(trimmedTarget) != nil
    }

    var body: some View {
        ZStack {
            OOColor.surface.ignoresSafeArea()

            // Clicking the empty area outside the form leaves it open if it has text,
            // as on the web: the form only closes when the field is empty.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isAddingAgent else { return }

                    isAddressFieldFocused = false
                    guard trimmedTarget.isEmpty else { return }

                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAddingAgent = false
                        inputError = nil
                    }
                }

            VStack(spacing: 0) {
                Spacer(minLength: OOSpace.xxLarge)

                OOLogo.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .accessibilityLabel("OpenOnion")

                Text("Choose an agent")
                    .font(OOFont.headline(size: 36))
                    .tracking(-0.72) // web: tracking-[-0.02em] at 36 pt
                    .foregroundStyle(OOColor.ink)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        ForEach(appViewModel.configurations) { configuration in
                            AgentPickerRow(
                                configuration: configuration,
                                isOnline: appViewModel.isAgentConnected(configuration)
                            ) {
                                selectAgent(configuration)
                            }
                        }
                    }

                    if isAddingAgent {
                        addAgentForm
                            .padding(.top, 16)
                    } else {
                        addAnotherButton
                            .padding(.top, 16)
                    }
                }
                .frame(maxWidth: 512) // web: max-w-lg

                Spacer(minLength: OOSpace.xxLarge)
            }
            .padding(.horizontal, 24)
        }
    }

    private var addAnotherButton: some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isAddingAgent = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14))
                Text("Add another agent")
                    .font(.system(size: 14))
            }
            .foregroundStyle(isHoveringAddAnother ? OOColor.ink : OOColor.inkSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: ooMinimumTarget)
            .background(isHoveringAddAnother ? OOColor.hover : Color.clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringAddAnother = $0 }
    }

    private var addAgentForm: some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
        let hasError = inputError != nil
        let border: Color = hasError
            ? OOColor.failureLine
            : (isAddressFieldFocused ? OOColor.primary : OOColor.hairline)
        let ring: Color = isAddressFieldFocused
            ? (hasError ? OOColor.failureFill : OOColor.currentTint)
            : .clear

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $agentTarget,
                    prompt: Text("0x...").foregroundStyle(OOColor.inkSecondary)
                )
                .textFieldStyle(.plain)
                .font(OOFont.mono(size: 14))
                .foregroundStyle(OOColor.ink)
                .focused($isAddressFieldFocused)
                .onSubmit(addAgent)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(OOColor.paper, in: shape)
                .overlay(shape.stroke(border, lineWidth: 1))
                .background(shape.inset(by: -1.5).stroke(ring, lineWidth: 3))
                .accessibilityLabel("Agent address")

                Button(action: addAgent) {
                    Text("Add")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.ooPrimary)
                .disabled(trimmedTarget.isEmpty)
            }

            // Fixed-height slot so the column doesn't jump when the error appears.
            Text(inputError ?? "")
                .font(.system(size: 14))
                .foregroundStyle(OOColor.failureText)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
                .padding(.top, 4)
                .accessibilityHidden(inputError == nil)
        }
        .onAppear {
            isAddressFieldFocused = true
        }
        .onChange(of: agentTarget) {
            inputError = nil
        }
        .onChange(of: isAddressFieldFocused) {
            // web: onBlur closes the form only when the field is empty
            if !isAddressFieldFocused && trimmedTarget.isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAddingAgent = false
                    inputError = nil
                }
            }
        }
    }
    private func selectAgent(_ configuration: GeneralAgentConfiguration) {
        appViewModel.createNewSession(for: configuration)
    }

    private func addAgent() {
        guard canAddAgent else {
            inputError = "Enter a valid 0x address or HTTP(S) Direct URL."
            return
        }

        switch appViewModel.addAgent(trimmedTarget) {
        case .added(let configuration):
            appViewModel.createNewSession(for: configuration)

        case .duplicate:
            let normalizedTarget = ConnectOnionAgentTarget.normalized(trimmedTarget)

            if let existingAgent = appViewModel.configurations.first(where: {
                ConnectOnionAgentTarget.normalized(
                    $0.addressConfiguration?.agentAddress ?? ""
                ) == normalizedTarget
            }) {
                selectAgent(existingAgent)
            } else {
                inputError = "This agent has already been added."
            }

        case .invalid:
            inputError = "Enter a valid 0x address or HTTP(S) Direct URL."
        }
    }
}

/// One saved agent in the picker: soft tile with live dot, name, short address, status.
/// From oo-chat app/page.tsx, the "Has agents" branch.
private struct AgentPickerRow: View {
    let configuration: GeneralAgentConfiguration
    let isOnline: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var address: String? {
        configuration.addressConfiguration?.agentAddress
    }

    private var shortAddress: String? {
        address.map(Self.short)
    }

    private var title: String {
        configuration.name.isEmpty ? (shortAddress ?? "Agent") : configuration.name
    }

    /// An unnamed agent is labelled by its short address, so the second line would repeat it.
    private var isUnnamed: Bool {
        title == shortAddress
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                OOAvatarTile(name: title, address: address, isOnline: isOnline)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(isUnnamed
                            ? OOFont.monoMedium(size: 14)
                            : .system(size: 16, weight: .semibold))
                        .foregroundStyle(OOColor.ink)
                        .lineLimit(1)

                    if !isUnnamed, let shortAddress {
                        Text(shortAddress)
                            .font(OOFont.mono(size: 12))
                            .foregroundStyle(OOColor.inkSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(isOnline ? "Online" : "Offline")
                    .font(.system(size: 12))
                    .foregroundStyle(isOnline ? OOColor.tintText : OOColor.inkSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? OOColor.surface : OOColor.paper, in: shape)
            .overlay(shape.stroke(OOColor.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1) // web: shadow-sm
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    /// web shortAddress in hooks/use-agent-info.ts: first 8, three dots, last 4
    private static func short(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return "\(address.prefix(8))...\(address.suffix(4))"
    }
}

/// Shows a lightweight placeholder when no detail content can be resolved.
private struct EmptyDetailView: View {
    let systemImage: String
    let message: String

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(AppPalette.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(message)
                    .font(.system(size: AppFontSize.body, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
    }
}

#Preview {
    ContentView()
}
