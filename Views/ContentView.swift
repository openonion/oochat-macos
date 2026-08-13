import SwiftUI
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
                                    .fill(AppPalette.divider)
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

        case .usage:
            UsageView(store: usageStore) {
                appViewModel.selection = appViewModel.previousSelection
            }

        case .settings:
            SettingsView(appearanceMode: $appearanceMode, appViewModel: appViewModel) {
                appViewModel.selection = appViewModel.previousSelection
            }

        case .none:
            EmptyDetailView(systemImage: "sparkles", message: "Select a session or connect an agent to begin.")
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
            AppBackground()

            VStack(spacing: 0) {
                Spacer(minLength: 32)

                onionMark

                Text("Talk to any agent.")
                    .font(.system(size: 38, weight: .semibold, design: .serif))
                    .foregroundColor(.primary)
                    .padding(.top, 22)

                Text("Paste its 0x address or Direct URL — the conversation starts live.")
                    .font(.system(size: AppFontSize.body))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)

                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .font(.system(size: AppFontSize.subheadline, weight: .medium))
                            .foregroundColor(.secondary)

                        TextField(
                            "0x address or https://…",
                            text: $agentTarget
                        )
                            .textFieldStyle(.plain)
                            .font(AppTypography.mono(size: AppFontSize.body))
                            .focused($isAddressFocused)
                            .onSubmit(connectAgent)

                        Button(action: pasteAddress) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: AppFontSize.subheadline))
                                .foregroundColor(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Paste agent address or Direct URL")
                        .help("Paste agent address or Direct URL")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(AppPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(inputError == nil ? AppPalette.divider : AppPalette.error, lineWidth: 1)
                    }

                    if let inputError {
                        Text(inputError)
                            .font(.system(size: AppFontSize.footnote))
                            .foregroundColor(AppPalette.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: connectAgent) {
                        Text("Connect")
                            .font(.system(size: AppFontSize.body, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(
                        canConnect
                            ? AppPalette.primaryActionForeground
                            : .secondary.opacity(0.65)
                    )
                    .background(
                        canConnect
                            ? AppPalette.primaryAction
                            : AppPalette.surfaceMuted
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(!canConnect)
                }
                .frame(maxWidth: 480)
                .padding(.top, 28)

                Spacer(minLength: 32)
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            isAddressFocused = true
        }
        .onChange(of: agentTarget) {
            inputError = nil
        }
    }

    private var onionMark: some View {
        Image("Onion")
            .resizable()
            .scaledToFit()
            .frame(width: 76, height: 76)
    }

    private func pasteAddress() {
        if let value = NSPasteboard.general.string(forType: .string) {
            agentTarget = value
        }
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
