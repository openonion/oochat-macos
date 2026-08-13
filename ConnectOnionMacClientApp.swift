import AppKit
import Foundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var managesDockerRuntime = false
    private let isRunningTests: () -> Bool
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
        startDockerRuntime: @escaping @MainActor () async -> Void,
        stopDockerRuntime: @escaping () -> Void
    ) {
        self.isRunningTests = isRunningTests
        self.startDockerRuntime = startDockerRuntime
        self.stopDockerRuntime = stopDockerRuntime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests() else {
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

    func applicationWillTerminate(_ notification: Notification) {
        if managesDockerRuntime {
            stopDockerRuntime()
        }
    }
}

@main
struct ConnectOnionMacClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            DockerRuntimeCommands(dockerRuntime: .shared)
        }
    }
}

struct DockerRuntimeCommands: Commands {
    @ObservedObject var dockerRuntime: DockerRuntimeManager

    var body: some Commands {
        CommandMenu("Docker") {
            Button("Reveal Runtime .env in Finder") {
                dockerRuntime.revealConfigurationFile()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Button("Copy .env Path") {
                dockerRuntime.copyConfigurationPath()
            }

            Divider()

            Button("Apply Configuration and Restart Agents") {
                Task {
                    await dockerRuntime.applyConfigurationAndRestart()
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(dockerRuntime.status.isBusy)
        }
    }
}
