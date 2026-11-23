import SwiftUI
import ConnectOnionKit
import AppKit

/// Owns app-level navigation, layout, appearance, and Docker runtime feedback.
struct ContentView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var usageStore: UsageStore
    @ObservedObject private var dockerRuntime = DockerRuntimeManager.shared

    @AppStorage("isDarkMode") private var isDarkMode = false
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage(LayoutStorageKey.sidebarVisible) private var isSidebarVisible = true
    @AppStorage("agentPaneWidth") private var agentPaneWidth = AgentPaneWidth.initial
    /// The Docker failure that was closed. A different failure shows again.
    @State private var dismissedDockerFailure: DockerStartupFailure?
    /// A link from the home screen adds the giver's agents before its sheet is done, so home stays up until then.
    @State private var isHomeLinking = false

    private let conversationMaxWidth: CGFloat = 768
    private let conversationHorizontalPadding: CGFloat = 24

    init(appViewModel: AppViewModel, usageStore: UsageStore) {
        self.appViewModel = appViewModel
        self.usageStore = usageStore

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
        // Laid out as Discord is: the agent rail, the agent pane (resizable 220–360 pt, hidden with
        // the toolbar button or ⌃⌘S), then the chat. Three neutral layers, darkest at the rail.
        HStack(spacing: 0) {
            AgentRail(appViewModel: appViewModel)
            if isSidebarVisible && !appViewModel.configurations.isEmpty {
                SidebarView(appViewModel: appViewModel)
                    .frame(width: CGFloat(AgentPaneWidth.clamped(agentPaneWidth)))
                AgentPaneResizeHandle(width: $agentPaneWidth)
                    .zIndex(1)
            }
            GeometryReader { detailGeometry in
                ZStack {
                    AppBackground()
                    detailView(conversationWidth: conversationWidth(detailWidth: detailGeometry.size.width))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // A top inset, so the chat starts below the banner.
            .safeAreaInset(edge: .top, spacing: 0) {
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
        .chatToolbar(breadcrumb: breadcrumb)
        // Pinned beside the traffic lights, so it doesn't move as the sidebar opens and closes.
        .background(SidebarToggleAccessory(action: toggleSidebar))
        // The menu bar's commands act on this window's chats.
        .focusedSceneObject(appViewModel)
        .restartAgentsConfirmation(
            isPresented: $dockerRuntime.isConfirmingRestart,
            dockerRuntime: dockerRuntime,
            appViewModel: appViewModel
        )
        .alert(
            "Delete chat?",
            isPresented: Binding(
                get: { appViewModel.sessionPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        appViewModel.sessionPendingDeletion = nil
                    }
                }
            ),
            presenting: appViewModel.sessionPendingDeletion
        ) { session in
            Button("Cancel", role: .cancel) {
                appViewModel.sessionPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                appViewModel.deleteSession(session)
                appViewModel.sessionPendingDeletion = nil
            }
        } message: { session in
            Text("\u{201C}\(session.title)\u{201D} and its messages will be removed from this Mac. Nothing is deleted where the agent runs.")
        }
    }

    @ViewBuilder
    private var breadcrumb: some View {
        if let chat = selectedChat {
            ChatBreadcrumb(appViewModel: appViewModel, session: chat.session, agent: chat.agent)
        }
    }

    /// Shows or hides the agent pane at once; the rail stays, as Discord's server list does.
    /// View ▸ Hide Sidebar (⌃⌘S) does the same through its own copy of `isSidebarVisible`.
    private func toggleSidebar() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isSidebarVisible.toggle()
        }
    }

    /// The open chat and its agent, for the toolbar's "agent / chat".
    private var selectedChat: (session: ChatSession, agent: GeneralAgentConfiguration)? {
        guard case .session(let sessionID) = appViewModel.selection,
              let session = appViewModel.sessions.first(where: { $0.id == sessionID }),
              let agent = appViewModel.configuration(for: session) else {
            return nil
        }
        return (session, agent)
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

        case .failed(let failure) where failure != dismissedDockerFailure:
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppPalette.error)
                Text(failure.message)
                    .font(.system(size: AppFontSize.footnote, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                failureActions(for: failure)
                Button {
                    dismissedDockerFailure = failure
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppFontSize.footnote, weight: .semibold))
                        .foregroundStyle(OOColor.inkSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close")
                .accessibilityLabel("Close Docker message")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
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
                .controlSize(.regular)
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
        .controlSize(.regular)
    }

    private func retryButton(title: String) -> some View {
        Button(title) {
            Task {
                await dockerRuntime.start()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
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

    @ViewBuilder
    private func detailView(conversationWidth: CGFloat) -> some View {
        if appViewModel.configurations.isEmpty || isHomeLinking {
            AgentConnectHomeView(appViewModel: appViewModel, isLinking: $isHomeLinking)
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
                let chatViewModel = appViewModel.chatViewModel(
                    for: session,
                    configuration: config,
                    usageRecorder: usageStore
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

        case .chooseAgent:
            ChooseAgentView(appViewModel: appViewModel)

        case .none:
            // Home, the logo at the top of the rail: the start screen, to talk to any agent.
            AgentConnectHomeView(appViewModel: appViewModel, isLinking: $isHomeLinking)
        }
    }

    private func conversationWidth(detailWidth: CGFloat) -> CGFloat {
        let safeWidth = max(0, detailWidth - conversationHorizontalPadding * 2)
        return min(conversationMaxWidth, safeWidth)
    }

}

/// Provides the first-run entry point: connect an agent by address as this device's own new
/// Identity, or take the Identity from another of the person's devices first.
struct AgentConnectHomeView: View {
    @ObservedObject var appViewModel: AppViewModel
    var identityStore: ConnectOnionIdentityStore = .shared
    /// Owned by ContentView, which keeps this view up while a link runs.
    var isLinking: Binding<Bool> = .constant(false)

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
                    .accessibilityLabel("oo-chat")

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
                    linkButton
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
        .sheet(isPresented: isLinking) {
            DeviceLinkSheet(role: .receiving, keyStore: identityStore, handlers: appViewModel.deviceLinkHandlers)
        }
    }

    /// The receive sheet from Settings, so a second device starts as the person its agents already know.
    private var linkButton: some View {
        VStack(spacing: 6) {
            Button {
                isLinking.wrappedValue = true
            } label: {
                Text(DeviceLinkRole.receiving.settingsTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.ooSecondary)

            Text(DeviceLinkRole.receiving.settingsDetail)
                .font(.system(size: 13))
                .foregroundStyle(OOColor.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
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
                    .accessibilityLabel("oo-chat")

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
                Text(appViewModel.configurations.isEmpty ? "Add an agent" : "Add another agent")
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
            if let existingAgent = appViewModel.existingAgent(for: trimmedTarget) {
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
    ContentView(appViewModel: AppViewModel(), usageStore: UsageStore())
}

private extension View {
    /// "agent / chat" as plain text, as Claude and Xcode show a title. On macOS 26 toolbar items
    /// otherwise sit in a glass capsule.
    @ViewBuilder
    func chatToolbar<Crumb: View>(breadcrumb: Crumb) -> some View {
        if #available(macOS 26.0, *) {
            toolbar {
                ToolbarItem(placement: .navigation) {
                    breadcrumb
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            toolbar {
                ToolbarItem(placement: .navigation) {
                    breadcrumb
                }
            }
        }
    }
}

/// The sidebar toggle as a titlebar accessory right after the traffic lights, as in Claude. A
/// toolbar item would ride along with the split view's columns and jump when the sidebar hides.
struct SidebarToggleAccessory: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.install(in: view.window, action: action)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private var accessory: NSTitlebarAccessoryViewController?

        func install(in window: NSWindow?, action: @escaping () -> Void) {
            guard accessory == nil, let window else {
                return
            }
            let host = NSHostingView(rootView: SidebarToggleButton(action: action))
            host.frame = NSRect(x: 0, y: 0, width: 44, height: 32)
            let controller = NSTitlebarAccessoryViewController()
            controller.view = host
            controller.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(controller)
            accessory = controller
        }
    }
}

/// A quiet square that lights on hover, like Claude's, not a glass bubble.
private struct SidebarToggleButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(OOColor.inkSecondary)
                .frame(width: 32, height: 28)
                .background(
                    isHovered ? OOColor.hover : Color.clear,
                    in: RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Toggle Sidebar (⌃⌘S)")
        .accessibilityLabel("Toggle Sidebar")
        .padding(.leading, OOSpace.small)
    }
}

/// "my-agent / Hello" in the toolbar, as in Claude. Click either name to rename it in place:
/// Return saves; Esc or clicking anywhere else puts the old name back.
struct ChatBreadcrumb: View {
    @ObservedObject var appViewModel: AppViewModel
    let session: ChatSession
    let agent: GeneralAgentConfiguration

    private enum Part: Hashable {
        case agent
        case chat
    }

    @State private var editing: Part?
    @State private var draft = ""
    @State private var hovered: Part?
    @FocusState private var focused: Part?
    @State private var clickMonitor: Any?

    var body: some View {
        HStack(spacing: OOSpace.tiny) {
            name(agent.name, part: .agent, color: OOColor.inkSecondary, weight: .regular)
            Text("/")
                .foregroundStyle(OOColor.inkTertiary)
                .accessibilityHidden(true)
            name(session.title, part: .chat, color: OOColor.ink, weight: .medium)
        }
        .font(OOSidebarMetrics.titleFont)
        .frame(maxWidth: 480, alignment: .leading)
        .onChange(of: focused) { _, newValue in
            // Focus moving to another field (the composer, search) cancels too.
            if editing != nil && newValue == nil {
                cancel()
            }
        }
        .onChange(of: session.id) {
            cancel()
        }
        .onChange(of: appViewModel.renameChatRequests) {
            startEditing(.chat, from: session.title)
        }
        .onDisappear {
            stopWatchingClicks()
        }
    }

    @ViewBuilder
    private func name(_ text: String, part: Part, color: Color, weight: Font.Weight) -> some View {
        if editing == part {
            TextField(part == .agent ? "Agent name" : "Chat name", text: $draft)
                .textFieldStyle(.plain)
                .fontWeight(weight)
                .foregroundStyle(OOColor.ink)
                .focused($focused, equals: part)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
                .padding(.horizontal, OOSpace.tiny + 2)
                .frame(minWidth: 120, maxWidth: 320, minHeight: 24)
                .background(OOColor.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(OOColor.primary, lineWidth: 1)
                }
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Button {
                startEditing(part, from: text)
            } label: {
                Text(text)
                    .fontWeight(weight)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, OOSpace.tiny + 2)
                    .frame(minHeight: 24)
                    // A quiet hover says it can be clicked, without looking like a button at rest.
                    .background(
                        hovered == part ? OOColor.hover : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                hovered = isHovering ? part : (hovered == part ? nil : hovered)
            }
            .help(part == .agent ? "Rename agent" : "Rename chat")
            .accessibilityLabel(text)
            .accessibilityHint(part == .agent ? "Renames the agent" : "Renames the chat")
        }
    }

    private func startEditing(_ part: Part, from text: String) {
        draft = text
        editing = part
        DispatchQueue.main.async {
            focused = part
        }
        watchClicks()
    }

    /// A click on the chat or sidebar doesn't take focus on the Mac, so the field would never
    /// lose it. Watch the window's clicks while editing: anything outside the field cancels.
    private func watchClicks() {
        stopWatchingClicks()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if !Self.isInsideEditedField(event) {
                DispatchQueue.main.async {
                    cancel()
                }
            }
            return event
        }
    }

    private func stopWatchingClicks() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    /// True when the click lands on the text being edited (the window's field editor).
    static func isInsideEditedField(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              let frameView = window.contentView?.superview,
              let hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil)) else {
            return false
        }
        if let textView = hit as? NSTextView {
            return textView.isFieldEditor && window.firstResponder === textView
        }
        return false
    }

    private func commit() {
        guard let part = editing else {
            return
        }
        editing = nil
        stopWatchingClicks()
        switch part {
        case .agent:
            let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && name != agent.name {
                appViewModel.renameAgent(agent, to: name)
            }
        case .chat:
            if draft != session.title {
                appViewModel.renameSession(session, to: draft)
            }
        }
    }

    private func cancel() {
        guard editing != nil else {
            return
        }
        editing = nil
        focused = nil
        stopWatchingClicks()
    }
}
