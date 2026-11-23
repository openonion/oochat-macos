import AppKit
import ConnectOnionKit
import Foundation
import SwiftUI

/// "Run Agents on This Mac". Off unless an agent saved on this Mac is served from localhost,
/// where the Docker runtime puts its agents, so a remote-only Mac never needs Docker.
enum LocalAgentsSetting {
    static let storageKey = "runsAgentsOnThisMac"

    /// Until the person chooses, on if a saved agent is on localhost, or if Docker has run on this
    /// Mac before. The second covers local agents that were added by their 0x address.
    static func isOn(
        in storage: UserDefaults = .standard,
        runtimeDirectory: URL? = defaultRuntimeDirectory()
    ) -> Bool {
        if storage.object(forKey: storageKey) != nil {
            return storage.bool(forKey: storageKey)
        }
        return hasLocalAgents(in: storage) || hasRunBefore(in: runtimeDirectory)
    }

    /// The runtime copies its docker-compose.yml here the first time it starts.
    static func hasRunBefore(in runtimeDirectory: URL?) -> Bool {
        guard let runtimeDirectory else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: runtimeDirectory.appendingPathComponent("docker-compose.yml").path
        )
    }

    /// Where the Docker runtime keeps its files, without creating the folder.
    static func defaultRuntimeDirectory() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        .appendingPathComponent("ConnectOnionMacClient", isDirectory: true)
        .appendingPathComponent("DockerRuntime", isDirectory: true)
    }

    static func hasLocalAgents(in storage: UserDefaults) -> Bool {
        guard let data = storage.data(forKey: AppViewModel.configurationsStorageKey),
              let configurations = try? JSONDecoder().decode([GeneralAgentConfiguration].self, from: data) else {
            return false
        }
        return configurations.contains(where: \.isOnThisMac)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var managesDockerRuntime = false
    private let isRunningTests: () -> Bool
    private let runsLocalAgents: () -> Bool
    private let startDockerRuntime: @MainActor () async -> Void
    private let stopDockerRuntime: () -> Void

    override convenience init() {
        self.init(
            isRunningTests: {
                ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            },
            startDockerRuntime: {
                await DockerRuntimeManager.shared.start()
            },
            stopDockerRuntime: {
                DockerRuntimeManager.shared.stopSynchronously()
            }
        )
    }

    init(
        isRunningTests: @escaping () -> Bool,
        runsLocalAgents: @escaping () -> Bool = { LocalAgentsSetting.isOn() },
        startDockerRuntime: @escaping @MainActor () async -> Void,
        stopDockerRuntime: @escaping () -> Void
    ) {
        self.isRunningTests = isRunningTests
        self.runsLocalAgents = runsLocalAgents
        self.startDockerRuntime = startDockerRuntime
        self.stopDockerRuntime = stopDockerRuntime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests(), runsLocalAgents() else {
            return
        }
        managesDockerRuntime = true
        Task { @MainActor in
            await startDockerRuntime()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    /// Also stops a runtime the Docker menu started after launch.
    func applicationWillTerminate(_ notification: Notification) {
        if managesDockerRuntime || (!isRunningTests() && runsLocalAgents()) {
            stopDockerRuntime()
        }
    }
}

@main
struct ConnectOnionMacClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        OOFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            AppCommands()
            DockerRuntimeCommands(dockerRuntime: .shared)
        }
    }
}

/// What the open chat lets the Chat and View menus do. ChatView publishes it.
struct ChatMenuActions {
    let canStop: Bool
    let stop: () -> Void
    let scrollToTop: () -> Void
    let scrollToLatest: () -> Void
    let hasControlCenter: Bool
}

extension FocusedValues {
    @Entry var chatMenu: ChatMenuActions?
}

/// The File, Edit, View and Chat commands. Their shortcuts are bound here only.
struct AppCommands: Commands {
    @FocusedObject private var app: AppViewModel?
    @FocusedValue(\.chatMenu) private var chat: ChatMenuActions?
    @AppStorage("isSidebarVisible") private var isSidebarVisible = true
    @AppStorage("isControlCenterOpen") private var isControlCenterOpen = true
    @AppStorage(ChatFontSize.storageKey) private var fontSize = ChatFontSize.standard

    var body: some Commands {
        // Replacing New Window means ⌘N can never open a second window.
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                app?.startNewChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(app == nil)

            Menu("New Chat With") {
                ForEach(app?.configurations ?? []) { configuration in
                    Button(configuration.name) {
                        app?.createNewSession(for: configuration)
                    }
                }
            }
            .disabled(app?.configurations.isEmpty ?? true)

            Button("Add Agent…") {
                app?.showAddAgent()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(app == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find") {
                // Search lives in the agent pane, so show the pane first.
                isSidebarVisible = true
                // Next turn, so a pane that was hidden is there to hear it.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .agentPaneSearch, object: nil)
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(app == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                // At once, as the toolbar button does: the rail stays, the agent pane goes.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isSidebarVisible.toggle()
                }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

            Button(isControlCenterOpen ? "Hide Control Center" : "Show Control Center") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isControlCenterOpen.toggle()
                }
            }
            .keyboardShortcut("c", modifiers: [.option, .command])
            .disabled(chat?.hasControlCenter != true)

            Divider()

            Button("Bigger") {
                fontSize = ChatFontSize.bigger(fontSize)
            }
            // ⌘=, the key under +. A "+" equivalent only fires with Shift held as well.
            .keyboardShortcut("=", modifiers: .command)
            .disabled(fontSize >= ChatFontSize.range.upperBound)

            Button("Smaller") {
                fontSize = ChatFontSize.smaller(fontSize)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(fontSize <= ChatFontSize.range.lowerBound)

            // No shortcut: ⌘0 is Home on the agent rail, and ⌘1 to ⌘9 pick agents.
            Button("Actual Size") {
                fontSize = ChatFontSize.standard
            }
            .disabled(fontSize == ChatFontSize.standard)

            Divider()
        }

        CommandMenu("Chat") {
            Button("Stop Response") {
                chat?.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(chat?.canStop != true)

            Divider()

            Button("Scroll to Top") {
                chat?.scrollToTop()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(chat == nil)

            Button("Scroll to Latest") {
                chat?.scrollToLatest()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(chat == nil)

            Divider()

            Button("Rename…") {
                app?.requestRenameChat()
            }
            .disabled(app?.selectedSession == nil)

            Button("Delete…") {
                app?.sessionPendingDeletion = app?.selectedSession
            }
            .disabled(app?.selectedSession == nil)
        }
    }
}

struct DockerRuntimeCommands: Commands {
    @ObservedObject var dockerRuntime: DockerRuntimeManager
    /// nil until the toggle below is used; until then local agents on this Mac decide.
    @AppStorage(LocalAgentsSetting.storageKey) private var runsLocalAgents: Bool?

    private var isRunningLocalAgents: Binding<Bool> {
        Binding(
            get: { runsLocalAgents ?? LocalAgentsSetting.isOn() },
            set: { isOn in
                runsLocalAgents = isOn
                if isOn {
                    Task {
                        await dockerRuntime.start()
                    }
                } else {
                    // The same teardown as on quit, but off the main thread so the app doesn't freeze.
                    Task {
                        await dockerRuntime.stop()
                    }
                }
            }
        )
    }

    var body: some Commands {
        CommandMenu("Docker") {
            Toggle("Run Agents on This Mac", isOn: isRunningLocalAgents)

            Divider()

            Button("Reveal Runtime .env in Finder") {
                dockerRuntime.revealConfigurationFile()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Button("Copy .env Path") {
                dockerRuntime.copyConfigurationPath()
            }

            Divider()

            Button("Apply Configuration and Restart Agents…") {
                dockerRuntime.isConfirmingRestart = true
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(dockerRuntime.status.isBusy || !isRunningLocalAgents.wrappedValue)
        }
    }
}
