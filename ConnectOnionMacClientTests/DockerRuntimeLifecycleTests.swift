import AppKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

final class DockerRuntimeLifecycleTests: XCTestCase {
    @MainActor
    func testAppDelegateOwnsDockerLifecycleOnlyOutsideTests() async {
        var startCount = 0
        var stopCount = 0
        let launchNotification = Notification(
            name: NSApplication.didFinishLaunchingNotification
        )
        let terminateNotification = Notification(
            name: NSApplication.willTerminateNotification
        )

        let testDelegate = AppDelegate(
            isRunningTests: { true },
            startDockerRuntime: {
                startCount += 1
            },
            stopDockerRuntime: {
                stopCount += 1
            }
        )
        testDelegate.applicationDidFinishLaunching(launchNotification)
        await Task.yield()
        testDelegate.applicationWillTerminate(terminateNotification)

        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(stopCount, 0)
        XCTAssertTrue(
            testDelegate.applicationShouldTerminateAfterLastWindowClosed(.shared)
        )

        let appDelegate = AppDelegate(
            isRunningTests: { false },
            startDockerRuntime: {
                startCount += 1
            },
            stopDockerRuntime: {
                stopCount += 1
            }
        )
        appDelegate.applicationDidFinishLaunching(launchNotification)
        await Task.yield()
        appDelegate.applicationWillTerminate(terminateNotification)

        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testMissingIdentityVolumeReauthenticatesWithoutLosingSettings() async throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("docker-runtime-recovery-\(UUID().uuidString)")
        let sourceDirectory = testDirectory.appendingPathComponent("source")
        let runtimeDirectory = testDirectory.appendingPathComponent("runtime")
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: testDirectory)
        }

        let composeSource = sourceDirectory.appendingPathComponent("docker-compose.yml")
        try "services: {}\n".write(
            to: composeSource,
            atomically: true,
            encoding: .utf8
        )
        try """
        CONNECTONION_TOOLSETS=custom
        AGENT_ADDRESS=0xold
        AGENT_EMAIL=old@example.com
        OPENONION_API_KEY=old-token

        """.write(
            to: runtimeDirectory.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        let executor = RecordingDockerExecutor(identityCheckStatus: 1)
        let service = DockerRuntimeService(
            configuration: DockerRuntimeConfiguration(
                dockerExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
                composeSourceURL: composeSource,
                runtimeDirectoryURL: runtimeDirectory,
                image: "co-agent:test",
                buildContextURL: nil
            ),
            executor: executor,
            fileManager: fileManager
        )

        try await service.start()

        let environment = try String(
            contentsOf: runtimeDirectory.appendingPathComponent(".env"),
            encoding: .utf8
        )
        XCTAssertTrue(environment.contains("CONNECTONION_TOOLSETS=custom"))
        XCTAssertTrue(environment.contains("AGENT_ADDRESS=0xtest"))
        XCTAssertFalse(environment.contains("0xold"))
        XCTAssertTrue(executor.commands.contains {
            $0.contains("--rm") && $0.contains("python")
        })
        XCTAssertTrue(executor.commands.contains {
            $0.contains("--name") && $0.contains("co-agent-bootstrap")
        })
        guard let identityCheck = executor.commands.first(where: {
            $0.contains("--rm") && $0.contains("python")
        }) else {
            return XCTFail("Expected a Docker identity consistency check")
        }
        let identityScript = identityCheck.last ?? ""
        for key in DockerRuntimeConfiguration.requiredCredentialKeys {
            XCTAssertTrue(identityScript.contains(key))
        }
    }

    @MainActor
    func testBootstrapPreservesRuntimeSettingsAndDockerOwnsShutdown() async throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("docker-runtime-test-\(UUID().uuidString)")
        let sourceDirectory = testDirectory.appendingPathComponent("source")
        let runtimeDirectory = testDirectory.appendingPathComponent("runtime")
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: testDirectory)
        }

        let composeSource = sourceDirectory.appendingPathComponent("docker-compose.yml")
        try "services: {}\n".write(
            to: composeSource,
            atomically: true,
            encoding: .utf8
        )
        let executor = RecordingDockerExecutor()
        let service = DockerRuntimeService(
            configuration: DockerRuntimeConfiguration(
                dockerExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
                composeSourceURL: composeSource,
                runtimeDirectoryURL: runtimeDirectory,
                image: "co-agent:test",
                buildContextURL: nil
            ),
            executor: executor,
            fileManager: fileManager
        )

        try await service.start()

        let environment = try String(
            contentsOf: runtimeDirectory.appendingPathComponent(".env"),
            encoding: .utf8
        )
        XCTAssertTrue(environment.contains("CONNECTONION_TOOLSETS=workspace,web,todo"))
        XCTAssertTrue(environment.contains("AGENT_ADDRESS=0xtest"))
        XCTAssertTrue(environment.contains("AGENT_EMAIL=test@example.com"))
        XCTAssertTrue(environment.contains("OPENONION_API_KEY=test-token"))
        XCTAssertTrue(environment.contains("# GEMINI_API_KEY="))
        XCTAssertTrue(environment.contains("# OPENAI_API_KEY="))
        XCTAssertFalse(environment.contains("AGENT_CONFIG_PATH"))
        XCTAssertFalse(environment.contains("IS_EMAIL_ACTIVE"))
        let environmentURL = runtimeDirectory.appendingPathComponent(".env")
        let attributes = try fileManager.attributesOfItem(atPath: environmentURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
        XCTAssertTrue(executor.commands.contains {
            $0.count == 3
                && $0[0] == "cp"
                && $0[1].hasSuffix("/home/appuser/.co/keys.env")
        })
        XCTAssertTrue(executor.commands.contains {
            Array($0.suffix(6)) == [
                "up", "-d", "--no-build", "--wait", "--wait-timeout", "180"
            ]
        })

        try service.stopSynchronously()

        guard let downCommand = executor.commands.first(where: {
            Array($0.suffix(2)) == ["down", "--remove-orphans"]
        }) else {
            return XCTFail("Expected Docker Compose shutdown command")
        }
        XCTAssertFalse(downCommand.contains("-v"))
    }

    @MainActor
    func testApplyConfigurationPreservesBYOKAndForceRecreatesAgents() async throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("docker-runtime-apply-\(UUID().uuidString)")
        let sourceDirectory = testDirectory.appendingPathComponent("source")
        let runtimeDirectory = testDirectory.appendingPathComponent("runtime")
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: testDirectory)
        }

        let composeSource = sourceDirectory.appendingPathComponent("docker-compose.yml")
        try "services: {}\n".write(
            to: composeSource,
            atomically: true,
            encoding: .utf8
        )
        let executor = RecordingDockerExecutor()
        let service = DockerRuntimeService(
            configuration: DockerRuntimeConfiguration(
                dockerExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
                composeSourceURL: composeSource,
                runtimeDirectoryURL: runtimeDirectory,
                image: "co-agent:test",
                buildContextURL: nil
            ),
            executor: executor,
            fileManager: fileManager
        )

        try await service.start()
        let environmentURL = service.configurationFileURL
        var environment = try String(contentsOf: environmentURL, encoding: .utf8)
        environment += "CONNECTONION_MODEL=gemini-2.5-pro\n"
        environment += "GEMINI_API_KEY=test-provider-key\n"
        try environment.write(to: environmentURL, atomically: true, encoding: .utf8)

        let restoredIdentity = try await service.applyConfiguration()

        XCTAssertFalse(restoredIdentity)
        let appliedEnvironment = try String(
            contentsOf: environmentURL,
            encoding: .utf8
        )
        XCTAssertTrue(appliedEnvironment.contains("GEMINI_API_KEY=test-provider-key"))
        guard let restartCommand = executor.commands.last(where: {
            $0.contains("--force-recreate")
        }) else {
            return XCTFail("Expected Docker Compose to force-recreate the Agents")
        }
        XCTAssertTrue(restartCommand.contains("--wait"))
        XCTAssertFalse(restartCommand.contains("-v"))
    }

    @MainActor
    func testApplyConfigurationRejectsMalformedEnvironment() async throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("docker-runtime-invalid-\(UUID().uuidString)")
        let sourceDirectory = testDirectory.appendingPathComponent("source")
        let runtimeDirectory = testDirectory.appendingPathComponent("runtime")
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: testDirectory)
        }

        let composeSource = sourceDirectory.appendingPathComponent("docker-compose.yml")
        try "services: {}\n".write(
            to: composeSource,
            atomically: true,
            encoding: .utf8
        )
        let executor = RecordingDockerExecutor()
        let service = DockerRuntimeService(
            configuration: DockerRuntimeConfiguration(
                dockerExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
                composeSourceURL: composeSource,
                runtimeDirectoryURL: runtimeDirectory,
                image: "co-agent:test",
                buildContextURL: nil
            ),
            executor: executor,
            fileManager: fileManager
        )
        let environmentURL = try service.prepareConfigurationFile()
        try "CONNECTONION_TOOLSETS=workspace\nINVALID LINE\n".write(
            to: environmentURL,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            try service.prepareConfigurationFile(),
            environmentURL,
            "A malformed file must remain revealable so the user can fix it."
        )

        do {
            _ = try await service.applyConfiguration()
            XCTFail("Expected malformed .env syntax to be rejected")
        } catch DockerRuntimeError.invalidEnvironment(let line) {
            XCTAssertEqual(line, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(executor.commands.contains { $0.contains("--force-recreate") })
    }

    @MainActor
    func testFindDockerExecutablePrefersExplicitPath() throws {
        let executableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("docker-\(UUID().uuidString)")
        try "#!/bin/sh\n".write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        defer {
            try? FileManager.default.removeItem(at: executableURL)
        }

        let result = DockerRuntimeManager.findDockerExecutable(
            environment: ["CONNECTONION_DOCKER_CLI": executableURL.path],
            fileManager: .default
        )

        XCTAssertEqual(result, executableURL)
    }

    private func makeBuildContext() throws -> (root: URL, hostAgent: URL) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("docker-image-tag-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let hostAgent = root.appendingPathComponent("host_agent.py")
        try "print('v1')\n".write(to: hostAgent, atomically: true, encoding: .utf8)
        // The Dockerfile's presence is what marks this a local build context.
        try "FROM scratch\n".write(
            to: root.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        return (root, hostAgent)
    }

    @MainActor
    func testLocalImageTagTracksBuildContextContent() throws {
        let (root, hostAgent) = try makeBuildContext()
        defer { try? FileManager.default.removeItem(at: root) }

        func tag() -> String {
            DockerRuntimeManager.resolveImage(
                bundle: .main,
                environment: [:],
                buildContextURL: root,
                fileManager: .default
            )
        }

        let original = tag()
        XCTAssertTrue(original.hasPrefix("co-agent:"))
        XCTAssertEqual(
            original,
            tag(),
            "Identical content must produce a stable tag so the image is reused."
        )

        try "print('v2')\n".write(to: hostAgent, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(
            original,
            tag(),
            "A changed host_agent.py must yield a new tag so a stale image is "
                + "never reused."
        )
    }

    @MainActor
    func testHiddenFileChurnDoesNotChangeTheTag() throws {
        let (root, _) = try makeBuildContext()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = DockerRuntimeManager.resolveImage(
            bundle: .main,
            environment: [:],
            buildContextURL: root,
            fileManager: .default
        )
        try "junk".write(
            to: root.appendingPathComponent(".DS_Store"),
            atomically: true,
            encoding: .utf8
        )
        let after = DockerRuntimeManager.resolveImage(
            bundle: .main,
            environment: [:],
            buildContextURL: root,
            fileManager: .default
        )
        XCTAssertEqual(before, after, "Hidden-file churn must not force a rebuild.")
    }

    @MainActor
    func testExplicitImageOverrideBypassesContentHashing() throws {
        let (root, _) = try makeBuildContext()
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = DockerRuntimeManager.resolveImage(
            bundle: .main,
            environment: ["CONNECTONION_DOCKER_IMAGE": "pinned/agent:9.9"],
            buildContextURL: root,
            fileManager: .default
        )
        XCTAssertEqual(resolved, "pinned/agent:9.9")
    }
}

private final class RecordingDockerExecutor: DockerCommandExecuting, @unchecked Sendable {
    let lock = NSLock()
    private let identityCheckStatus: Int32
    private var recordedCommands: [[String]] = []

    init(identityCheckStatus: Int32 = 0) {
        self.identityCheckStatus = identityCheckStatus
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    func runSynchronously(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?
    ) throws -> DockerCommandResult {
        lock.lock()
        recordedCommands.append(arguments)
        lock.unlock()

        if arguments.contains("--rm"), arguments.contains("python") {
            return DockerCommandResult(
                standardOutput: "",
                standardError: "",
                terminationStatus: identityCheckStatus
            )
        }
        if arguments.starts(with: ["container", "inspect"]) {
            return DockerCommandResult(
                standardOutput: "",
                standardError: "not found",
                terminationStatus: 1
            )
        }
        if arguments.first == "cp", let destination = arguments.last {
            let credentials = """
            AGENT_CONFIG_PATH=/home/appuser/.co
            AGENT_ADDRESS=0xtest
            OPENONION_API_KEY=test-token
            AGENT_EMAIL=test@example.com
            IS_EMAIL_ACTIVE=true

            """
            try credentials.write(
                toFile: destination,
                atomically: true,
                encoding: .utf8
            )
        }
        return DockerCommandResult(
            standardOutput: "",
            standardError: "",
            terminationStatus: 0
        )
    }
}
