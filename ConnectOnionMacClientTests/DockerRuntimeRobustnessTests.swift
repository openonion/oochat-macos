import Foundation
import XCTest
@testable import ConnectOnionMacClient

final class DockerRuntimeRobustnessTests: XCTestCase {

    // MARK: - Preflight failures map to actionable guidance

    func testStartStopsAfterDockerDaemonFailureAndBoundsDiagnosticOutput() async throws {
        let fixture = try DockerRuntimeRobustnessFixture()
        defer { fixture.remove() }
        let executor = FaultInjectingDockerExecutor(mode: .dockerUnavailable)
        let service = fixture.makeService(executor: executor)

        do {
            try await service.start()
            XCTFail("Expected Docker startup to fail")
        } catch DockerRuntimeError.daemonNotRunning(let detail) {
            XCTAssertTrue(detail.contains("Is the docker daemon running"))
            XCTAssertLessThanOrEqual(detail.count, 2_000)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(executor.commands, [["info"]])
    }

    func testNonDaemonInfoFailureKeepsRealDiagnosticInsteadOfStartGuidance() async throws {
        let fixture = try DockerRuntimeRobustnessFixture()
        defer { fixture.remove() }
        let executor = FaultInjectingDockerExecutor(mode: .infoNonDaemonFailure)
        let service = fixture.makeService(executor: executor)

        do {
            try await service.start()
            XCTFail("Expected docker info to fail")
        } catch DockerRuntimeError.commandFailed(let command, let detail) {
            XCTAssertEqual(command, "docker info")
            XCTAssertTrue(detail.contains("Maximum supported API version"))
            // An API/context problem is not "Docker Desktop is stopped".
            XCTAssertEqual(
                DockerStartupFailure(
                    error: DockerRuntimeError.commandFailed(
                        command: command,
                        detail: detail
                    )
                ).kind,
                .other
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(executor.commands, [["info"]])
    }

    func testComposePreflightFailureStopsBeforeImagePullBootstrapAndUp() async throws {
        let fixture = try DockerRuntimeRobustnessFixture()
        defer { fixture.remove() }
        let executor = FaultInjectingDockerExecutor(mode: .composeUnavailable)
        let service = fixture.makeService(executor: executor)

        do {
            try await service.start()
            XCTFail("Expected the Compose v2 preflight to fail")
        } catch DockerRuntimeError.composeV2Unavailable(let detail) {
            XCTAssertTrue(detail.contains("not a docker command"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Exactly the two preflight commands ran, in order. No image
        // inspection, pull, build, account bootstrap, or `compose up`.
        XCTAssertEqual(executor.commands, [["info"], ["compose", "version"]])
    }

    func testImagePullFailureKeepsGenericGuidanceAndStopsBeforeCompose() async throws {
        let fixture = try DockerRuntimeRobustnessFixture()
        defer { fixture.remove() }
        let executor = FaultInjectingDockerExecutor(mode: .imagePullFailure)
        let service = fixture.makeService(executor: executor)

        do {
            try await service.start()
            XCTFail("Expected the image pull to fail")
        } catch DockerRuntimeError.imageUnavailable(let image, let detail) {
            XCTAssertEqual(image, "co-agent:test")
            // The real pull diagnostic must survive into the error.
            XCTAssertTrue(detail.contains("no such host"))
            // A network or registry error must never be presented as
            // "install Docker Desktop" guidance.
            XCTAssertEqual(
                DockerStartupFailure(
                    error: DockerRuntimeError.imageUnavailable(
                        image: image,
                        detail: detail
                    )
                ).kind,
                .other
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(executor.commands.contains { $0.contains("up") })
        XCTAssertFalse(executor.commands.contains { $0.contains("auth") })
    }

    func testStartupFailureMapsEveryErrorToTheMatchingKind() {
        XCTAssertEqual(
            DockerStartupFailure(error: DockerRuntimeError.dockerUnavailable).kind,
            .dockerNotInstalled
        )
        XCTAssertEqual(
            DockerStartupFailure(
                error: DockerRuntimeError.daemonNotRunning("connect failed")
            ).kind,
            .dockerNotRunning
        )
        XCTAssertEqual(
            DockerStartupFailure(
                error: DockerRuntimeError.composeV2Unavailable("no compose")
            ).kind,
            .composeUnavailable
        )
        XCTAssertEqual(
            DockerStartupFailure(
                error: DockerRuntimeError.commandFailed(
                    command: "docker pull",
                    detail: "network timeout"
                )
            ).kind,
            .other
        )
        XCTAssertEqual(
            DockerStartupFailure(error: URLError(.notConnectedToInternet)).kind,
            .other
        )
    }

    // MARK: - Executor stdin plumbing

    func testProcessExecutorPipesStandardInputToTheCommand() throws {
        let result = try ProcessDockerCommandExecutor().runSynchronously(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat"],
            environment: [:],
            standardInput: Data("voice-input-bytes".utf8)
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, "voice-input-bytes")
    }

    func testProcessExecutorWithoutStandardInputStillRuns() throws {
        let result = try ProcessDockerCommandExecutor().runSynchronously(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf ok"],
            environment: [:]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, "ok")
    }

    // MARK: - In-container voice transcription

    func testTranscriptionPipesAudioThroughComposeExecAndReturnsStdout() async throws {
        let fixture = try DockerRuntimeRobustnessFixture()
        defer { fixture.remove() }
        let executor = TranscriptionDockerExecutor(
            result: DockerCommandResult(
                standardOutput: #"{"text": "hello"}"#,
                standardError: "",
                terminationStatus: 0
            )
        )
        let service = fixture.makeService(executor: executor)
        let audio = Data("wav-bytes".utf8)

        let output = try await service.transcribeRecording(audio)

        XCTAssertEqual(output, #"{"text": "hello"}"#)
        XCTAssertEqual(executor.standardInputs, [audio])
        let arguments = try XCTUnwrap(executor.commands.first)
        XCTAssertEqual(arguments.first, "compose")
        let execIndex = try XCTUnwrap(arguments.firstIndex(of: "exec"))
        XCTAssertEqual(
            Array(arguments[execIndex...].prefix(5)),
            ["exec", "-T", "agent", "sh", "-c"]
        )
        let script = try XCTUnwrap(arguments.last)
        XCTAssertTrue(script.contains("transcribe_audio.py"))
        XCTAssertTrue(script.contains("mktemp"))
        XCTAssertTrue(script.contains("trap"))
    }

    func testTranscriptionFailurePropagatesTheContainerDiagnostic() async throws {
        let fixture = try DockerRuntimeRobustnessFixture()
        defer { fixture.remove() }
        let executor = TranscriptionDockerExecutor(
            result: DockerCommandResult(
                standardOutput: "",
                standardError: "OpenOnion API key required for co/ models.",
                terminationStatus: 1
            )
        )
        let service = fixture.makeService(executor: executor)

        do {
            _ = try await service.transcribeRecording(Data("wav".utf8))
            XCTFail("Expected transcription to fail")
        } catch DockerRuntimeError.commandFailed(let command, let detail) {
            XCTAssertEqual(command, "Voice transcription")
            XCTAssertTrue(detail.contains("OpenOnion API key required"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Manager surfaces structured guidance to the UI

    @MainActor
    func testManagerReportsInstallGuidanceWhenDockerCLIIsMissing() async throws {
        let fixture = try DockerRuntimeRobustnessFixture()
        defer { fixture.remove() }
        let suiteName = "DockerRuntimeRobustnessTests.\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let executor = FaultInjectingDockerExecutor(mode: .dockerUnavailable)
        let manager = DockerRuntimeManager(
            executor: executor,
            fileManager: NoExecutablesFileManager(),
            environment: ["HOME": "/nonexistent-home"],
            storage: storage,
            runtimeDirectory: fixture.runtimeDirectory,
            composeSource: fixture.composeSourceURL
        )

        await manager.start()

        guard case .failed(let failure) = manager.status else {
            return XCTFail("Expected a failed status, got \(manager.status)")
        }
        XCTAssertEqual(failure.kind, .dockerNotInstalled)
        XCTAssertTrue(failure.message.contains("Install Docker Desktop"))
        // Without a CLI no Docker command may ever be attempted.
        XCTAssertTrue(executor.commands.isEmpty)
    }

    @MainActor
    func testManagerReportsStartGuidanceWhenDockerEngineIsDown() async throws {
        let fixture = try DockerRuntimeRobustnessFixture()
        defer { fixture.remove() }
        let suiteName = "DockerRuntimeRobustnessTests.\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let executor = FaultInjectingDockerExecutor(mode: .dockerUnavailable)
        let manager = DockerRuntimeManager(
            executor: executor,
            environment: ["CONNECTONION_DOCKER_CLI": "/usr/bin/true"],
            storage: storage,
            runtimeDirectory: fixture.runtimeDirectory,
            composeSource: fixture.composeSourceURL
        )

        await manager.start()

        guard case .failed(let failure) = manager.status else {
            return XCTFail("Expected a failed status, got \(manager.status)")
        }
        XCTAssertEqual(failure.kind, .dockerNotRunning)
        XCTAssertTrue(failure.message.contains("Open Docker Desktop"))
        XCTAssertEqual(executor.commands, [["info"]])
    }

    // MARK: - Existing invariants

    func testBootstrapRejectsIncompleteCredentialsBeforeComposeStartup() async throws {
        let fixture = try DockerRuntimeRobustnessFixture()
        defer { fixture.remove() }
        let executor = FaultInjectingDockerExecutor(mode: .incompleteCredentials)
        let service = fixture.makeService(executor: executor)

        do {
            try await service.start()
            XCTFail("Expected incomplete credentials to be rejected")
        } catch DockerRuntimeError.credentialsMissing {
            // Expected: the runtime must not start with a partial identity.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(executor.commands.contains { $0.contains("up") })
        let runtimeContents = try FileManager.default.contentsOfDirectory(
            atPath: fixture.runtimeDirectory.path
        )
        XCTAssertFalse(runtimeContents.contains {
            $0.hasPrefix(".env.bootstrap-")
        })
        let environment = try String(
            contentsOf: fixture.runtimeDirectory.appendingPathComponent(".env"),
            encoding: .utf8
        )
        XCTAssertFalse(environment.contains("AGENT_ADDRESS=0xincomplete"))
    }

    @MainActor
    func testManagerClearsLegacyWorkspacePreferenceWithoutDeletingFolder() async throws {
        let suiteName = "DockerRuntimeRobustnessTests.\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let legacyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        storage.set(
            legacyDirectory.path,
            forKey: "agentWorkspaceDirectory"
        )

        DockerRuntimeManager.clearLegacyWorkspacePreference(in: storage)

        XCTAssertNil(storage.string(forKey: "agentWorkspaceDirectory"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyDirectory.path)
        )
        await Task.yield()
    }
}

// MARK: - Fixtures

private final class DockerRuntimeRobustnessFixture {
    let root: URL
    let runtimeDirectory: URL
    let composeSourceURL: URL

    init(fileManager: FileManager = .default) throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("docker-robustness-\(UUID().uuidString)")
        runtimeDirectory = root.appendingPathComponent("runtime")
        let sourceDirectory = root.appendingPathComponent("source")
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        composeSourceURL = sourceDirectory.appendingPathComponent("docker-compose.yml")
        try "services: {}\n".write(
            to: composeSourceURL,
            atomically: true,
            encoding: .utf8
        )
    }

    func makeService(
        executor: DockerCommandExecuting
    ) -> DockerRuntimeService {
        DockerRuntimeService(
            configuration: DockerRuntimeConfiguration(
                dockerExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
                composeSourceURL: composeSourceURL,
                runtimeDirectoryURL: runtimeDirectory,
                image: "co-agent:test",
                buildContextURL: nil
            ),
            executor: executor
        )
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root)
    }
}

/// Reports every path as non-executable so the Docker CLI lookup fails the
/// way it does on a machine without Docker Desktop.
private final class NoExecutablesFileManager: FileManager, @unchecked Sendable {
    override func isExecutableFile(atPath path: String) -> Bool {
        false
    }
}

private final class TranscriptionDockerExecutor:
    DockerCommandExecuting,
    @unchecked Sendable {
    private let result: DockerCommandResult
    private let lock = NSLock()
    private var recordedCommands: [[String]] = []
    private var recordedInputs: [Data] = []

    init(result: DockerCommandResult) {
        self.result = result
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    var standardInputs: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInputs
    }

    func runSynchronously(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?
    ) throws -> DockerCommandResult {
        lock.lock()
        defer { lock.unlock() }
        recordedCommands.append(arguments)
        if let standardInput {
            recordedInputs.append(standardInput)
        }
        return result
    }
}

private final class FaultInjectingDockerExecutor:
    DockerCommandExecuting,
    @unchecked Sendable {
    enum Mode {
        case dockerUnavailable
        case infoNonDaemonFailure
        case composeUnavailable
        case imagePullFailure
        case incompleteCredentials
    }

    private let mode: Mode
    private let lock = NSLock()
    private var recordedCommands: [[String]] = []

    init(mode: Mode) {
        self.mode = mode
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

        if mode == .dockerUnavailable, arguments == ["info"] {
            return failure(
                String(repeating: "x", count: 2_100)
                    + " Cannot connect to the Docker daemon at "
                    + "unix:///var/run/docker.sock. Is the docker daemon running?"
            )
        }
        if mode == .infoNonDaemonFailure, arguments == ["info"] {
            return failure(
                "client version 1.52 is too new. "
                    + "Maximum supported API version is 1.47"
            )
        }
        if mode == .composeUnavailable, arguments == ["compose", "version"] {
            return failure(
                "docker: 'compose' is not a docker command.\nSee 'docker --help'"
            )
        }
        if mode == .imagePullFailure {
            if arguments.starts(with: ["image", "inspect"]) {
                return failure("Error: No such image: co-agent:test")
            }
            if arguments.first == "pull" {
                return failure(
                    "Error response from daemon: "
                        + "Get \"https://registry-1.docker.io/v2/\": "
                        + "dial tcp: lookup registry-1.docker.io: no such host"
                )
            }
        }
        if arguments.starts(with: ["image", "inspect"]) {
            return success
        }
        if arguments.starts(with: ["container", "inspect"]) {
            return failure("not found")
        }
        if arguments.first == "cp", let destination = arguments.last {
            try """
            AGENT_ADDRESS=0xincomplete
            AGENT_EMAIL=incomplete@example.com

            """.write(
                toFile: destination,
                atomically: true,
                encoding: .utf8
            )
        }
        return success
    }

    private var success: DockerCommandResult {
        DockerCommandResult(
            standardOutput: "",
            standardError: "",
            terminationStatus: 0
        )
    }

    private func failure(_ standardError: String) -> DockerCommandResult {
        DockerCommandResult(
            standardOutput: "",
            standardError: standardError,
            terminationStatus: 1
        )
    }
}
