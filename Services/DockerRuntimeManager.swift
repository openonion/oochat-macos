import AppKit
import Foundation
import Combine
import CryptoKit

/// Captured output and exit status of one finished Docker CLI invocation.
struct DockerCommandResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32
}

/// Runs one CLI command to completion. Injected as a seam so tests can
/// script Docker's behavior without a real daemon or binary.
nonisolated protocol DockerCommandExecuting: Sendable {
    func runSynchronously(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?
    ) throws -> DockerCommandResult
}

/// Convenience for the common case of commands that take no standard input.
extension DockerCommandExecuting {
    func runSynchronously(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> DockerCommandResult {
        try runSynchronously(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardInput: nil
        )
    }
}

/// Production executor backed by `Process`. Output is captured through
/// temporary files and stdin is written from a background queue, so neither
/// stream can stall the child while the caller waits for it to exit.
nonisolated final class ProcessDockerCommandExecutor:
    DockerCommandExecuting,
    @unchecked Sendable {
    func runSynchronously(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?
    ) throws -> DockerCommandResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("connectonion-docker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let standardOutputURL = temporaryDirectory.appendingPathComponent("stdout")
        let standardErrorURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)

        let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
        let standardError = try FileHandle(forWritingTo: standardErrorURL)
        defer {
            try? standardOutput.close()
            try? standardError.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, runtimeValue in runtimeValue }
        )
        process.standardOutput = standardOutput
        process.standardError = standardError

        let inputPipe: Pipe? = standardInput == nil ? nil : Pipe()
        if let inputPipe {
            process.standardInput = inputPipe
        }

        try process.run()
        if let inputPipe, let standardInput {
            let writer = inputPipe.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                // A command that exits before draining stdin closes the pipe;
                // that surfaces through its exit status, not this write.
                try? writer.write(contentsOf: standardInput)
                try? writer.close()
            }
        }
        process.waitUntilExit()
        try standardOutput.synchronize()
        try standardError.synchronize()

        return DockerCommandResult(
            standardOutput: String(
                data: try Data(contentsOf: standardOutputURL),
                encoding: .utf8
            ) ?? "",
            standardError: String(
                data: try Data(contentsOf: standardErrorURL),
                encoding: .utf8
            ) ?? "",
            terminationStatus: process.terminationStatus
        )
    }
}

/// Categorizes a Docker startup failure so the UI can offer the matching
/// remediation instead of a bare Retry button.
enum DockerStartupFailureKind: Equatable, Sendable {
    /// The Docker CLI was not found: Docker Desktop is not installed.
    case dockerNotInstalled
    /// The CLI exists but `docker info` failed: Docker Desktop is not running.
    case dockerNotRunning
    /// `docker compose version` failed: Docker Compose v2 is missing.
    case composeUnavailable
    /// Every other failure (image pull, network, ports, …): show the error.
    case other
}

/// A user-facing startup failure: what happened and how to recover.
struct DockerStartupFailure: Equatable, Sendable {
    let kind: DockerStartupFailureKind
    let message: String

    init(kind: DockerStartupFailureKind, message: String) {
        self.kind = kind
        self.message = message
    }

    init(error: Error) {
        let kind: DockerStartupFailureKind
        switch error as? DockerRuntimeError {
        case .dockerUnavailable:
            kind = .dockerNotInstalled
        case .daemonNotRunning:
            kind = .dockerNotRunning
        case .composeV2Unavailable:
            kind = .composeUnavailable
        default:
            kind = .other
        }
        self.init(kind: kind, message: error.localizedDescription)
    }
}

/// Lifecycle of the Docker runtime, carrying the user-facing text the
/// status UI shows for each phase.
enum DockerRuntimeStatus: Equatable {
    case idle
    case starting(String)
    case ready
    case stopping
    case stopped
    case failed(DockerStartupFailure)

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .starting(let detail):
            return detail
        case .ready:
            return "All Docker agents are online."
        case .stopping:
            return "Stopping Docker agents…"
        case .stopped:
            return "Docker agents are stopped."
        case .failed(let failure):
            return failure.message
        }
    }

    var isError: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .starting, .stopping:
            return true
        default:
            return false
        }
    }
}

/// Failures raised by the runtime layer. Descriptions are written as full
/// user-facing guidance because they surface directly in the status UI.
enum DockerRuntimeError: LocalizedError {
    case dockerUnavailable
    case daemonNotRunning(String)
    case composeV2Unavailable(String)
    case composeResourceMissing
    case imageUnavailable(image: String, detail: String)
    case commandFailed(command: String, detail: String)
    case credentialsMissing
    case invalidEnvironment(line: Int)

    var errorDescription: String? {
        switch self {
        case .dockerUnavailable:
            return "Docker Desktop is not installed: the docker command was not found. "
                + "Install Docker Desktop, then check again."
        case .daemonNotRunning:
            return "Docker Desktop is installed but not running. "
                + "Open Docker Desktop, wait until the engine is running, then retry."
        case .composeV2Unavailable:
            return "Docker Compose v2 is required but unavailable. "
                + "Update Docker Desktop to a current version, then retry."
        case .composeResourceMissing:
            return "The bundled Docker Compose configuration is missing."
        case .imageUnavailable(let image, let detail):
            return "The Docker image \(image) is unavailable: \(detail)"
        case .commandFailed(let command, let detail):
            return "\(command) failed: \(detail)"
        case .credentialsMissing:
            return "Docker account setup did not produce valid credentials."
        case .invalidEnvironment(let line):
            return "The Docker .env file has invalid syntax on line \(line)."
        }
    }
}

/// Resolved inputs for one runtime session: where the Docker CLI lives,
/// where Compose files are staged, and which agent image to run.
struct DockerRuntimeConfiguration: Sendable {
    static let projectName = "connectonion-mac-client"
    static let bootstrapContainerName = "co-agent-bootstrap"
    static let requiredCredentialKeys = [
        "AGENT_ADDRESS",
        "AGENT_EMAIL",
        "OPENONION_API_KEY"
    ]

    let dockerExecutableURL: URL
    let composeSourceURL: URL
    let runtimeDirectoryURL: URL
    let image: String
    let buildContextURL: URL?

    var composeURL: URL {
        runtimeDirectoryURL.appendingPathComponent("docker-compose.yml")
    }

    var environmentURL: URL {
        runtimeDirectoryURL.appendingPathComponent(".env")
    }

    var dockerEnvironment: [String: String] {
        ["CONNECTONION_IMAGE": image]
    }

    var composeArguments: [String] {
        [
            "compose",
            "--project-name", Self.projectName,
            "--project-directory", runtimeDirectoryURL.path,
            "--file", composeURL.path
        ]
    }
}

/// Does the actual Docker work — preflight, image, bootstrap, Compose
/// lifecycle, and in-container commands — with no UI or main-actor state.
final class DockerRuntimeService: @unchecked Sendable {
    private let configuration: DockerRuntimeConfiguration
    private let executor: DockerCommandExecuting
    private let fileManager: FileManager

    init(
        configuration: DockerRuntimeConfiguration,
        executor: DockerCommandExecuting = ProcessDockerCommandExecutor(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.executor = executor
        self.fileManager = fileManager
    }

    /// Brings every agent up end to end, reporting each stage so the UI can
    /// show progress while images pull and containers start.
    func start(
        progress: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws {
        try prepareRuntimeDirectory()
        try validateEnvironmentSyntax()

        // Both preflight checks must pass before any image pull, account
        // bootstrap, or container creation is attempted.
        progress("Checking Docker Desktop…")
        try await ensureDaemonRunning()

        progress("Checking Docker Compose…")
        try await ensureComposeV2Available()

        progress("Preparing the Agent image…")
        try await ensureImage()

        progress("Preparing the Docker account…")
        try await bootstrapAccountIfNeeded()

        progress("Starting all Docker agents…")
        _ = try await runCompose(
            ["up", "-d", "--no-build", "--wait", "--wait-timeout", "180"],
            label: "docker compose up"
        )
    }

    var configurationFileURL: URL {
        configuration.environmentURL
    }

    @discardableResult
    func prepareConfigurationFile() throws -> URL {
        try prepareRuntimeDirectory()
        return configuration.environmentURL
    }

    /// Same pipeline as `start`, but force-recreates the containers so edited
    /// `.env` values actually reach them. Returns whether the bootstrap had to
    /// restore identity credentials.
    func applyConfiguration(
        progress: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> Bool {
        try prepareRuntimeDirectory()
        try validateEnvironmentSyntax()

        progress("Checking Docker Desktop…")
        try await ensureDaemonRunning()

        progress("Checking Docker Compose…")
        try await ensureComposeV2Available()

        progress("Preparing the Agent image…")
        try await ensureImage()

        progress("Validating Docker identity…")
        let restoredIdentity = try await bootstrapAccountIfNeeded()
        try validateEnvironmentSyntax()

        progress("Applying Docker configuration…")
        _ = try await runCompose(
            [
                "up", "-d", "--no-build", "--force-recreate",
                "--wait", "--wait-timeout", "180"
            ],
            label: "docker compose up"
        )
        return restoredIdentity
    }

    /// Blocking teardown. A missing compose file means nothing was ever
    /// started, so it quietly succeeds instead of failing the shutdown.
    func stopSynchronously() throws {
        guard fileManager.fileExists(atPath: configuration.composeURL.path) else {
            return
        }
        let result = try executor.runSynchronously(
            executableURL: configuration.dockerExecutableURL,
            arguments: configuration.composeArguments + ["down", "--remove-orphans"],
            environment: configuration.dockerEnvironment
        )
        guard result.terminationStatus == 0 else {
            throw commandError(label: "docker compose down", result: result)
        }
    }

    func accountStatus() async throws -> String {
        let result = try await runCompose(
            ["exec", "-T", "agent", "co", "status"],
            label: "docker compose exec agent co status"
        )
        return result.standardOutput
    }

    func credentials() throws -> [String: String] {
        let values = try environmentValues(at: configuration.environmentURL)
        guard DockerRuntimeConfiguration.requiredCredentialKeys.allSatisfy({
            !(values[$0] ?? "").isEmpty
        }) else {
            throw DockerRuntimeError.credentialsMissing
        }
        return values
    }

    /// Reads the recovery phrase out of the running container; the words are
    /// held in memory only and never written to the host disk.
    func recoveryWords() throws -> [String] {
        let result = try executor.runSynchronously(
            executableURL: configuration.dockerExecutableURL,
            arguments: configuration.composeArguments + [
                "exec", "-T", "agent", "python", "-c",
                "from pathlib import Path; print(Path('/home/appuser/.co/keys/recovery.txt').read_text())"
            ],
            environment: configuration.dockerEnvironment
        )
        guard result.terminationStatus == 0 else {
            throw commandError(label: "read Docker recovery phrase", result: result)
        }
        let words = result.standardOutput
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else {
            throw DockerRuntimeError.credentialsMissing
        }
        return words
    }

    /// Runs inside the agent container so transcription reuses the packaged
    /// ConnectOnion install, the Docker identity, and its account credits —
    /// nothing is required on the host beyond Docker itself.
    static let transcriptionShellScript = """
    set -eu
    audio="$(mktemp /tmp/co-voice-XXXXXX.wav)"
    transcript="$(mktemp /tmp/co-voice-XXXXXX.json)"
    trap 'rm -f "$audio" "$transcript"' EXIT
    cat > "$audio"
    python /app/transcribe_audio.py "$audio" "$transcript"
    cat "$transcript"
    """

    /// Streams the recorded audio over stdin into the container and returns
    /// the transcription script's JSON output unchanged.
    func transcribeRecording(_ audioData: Data) async throws -> String {
        let result = try await runCompose(
            ["exec", "-T", "agent", "sh", "-c", Self.transcriptionShellScript],
            label: "Voice transcription",
            input: audioData
        )
        return result.standardOutput
    }

    /// Stages the owner-only runtime directory: rewrites the compose file
    /// only when its content changed, seeds a commented `.env` template on
    /// first run, and keeps the `.env` readable by its owner alone.
    private func prepareRuntimeDirectory() throws {
        try fileManager.createDirectory(
            at: configuration.runtimeDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configuration.runtimeDirectoryURL.path
        )

        let composeData = try Data(contentsOf: configuration.composeSourceURL)
        if (try? Data(contentsOf: configuration.composeURL)) != composeData {
            try composeData.write(to: configuration.composeURL, options: .atomic)
        }

        if !fileManager.fileExists(atPath: configuration.environmentURL.path) {
            let defaultEnvironment = """
            # Optional bring-your-own-key model configuration. Keep provider
            # secrets in this runtime file; never add them to the App bundle.
            # CONNECTONION_MODEL=gemini-2.5-pro
            # GEMINI_API_KEY=
            # OPENAI_API_KEY=
            # ANTHROPIC_API_KEY=
            # MISTRAL_API_KEY=

            CONNECTONION_ENABLE_EVAL=0
            CONNECTONION_REFLECTION_MODE=on_failure
            CONNECTONION_TOOLSETS=workspace,web,todo

            """
            try defaultEnvironment.write(
                to: configuration.environmentURL,
                atomically: true,
                encoding: .utf8
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configuration.environmentURL.path
        )
    }

    /// Messages the Docker CLI prints when the daemon itself is unreachable.
    /// Only these become "start Docker Desktop" guidance; any other
    /// `docker info` failure keeps its real diagnostic with plain Retry.
    private static let daemonDownIndicators = [
        "cannot connect to the docker daemon",
        "is the docker daemon running",
        "docker daemon is not running",
        "connection refused",
        "dial unix"
    ]

    /// Preflight: the Docker CLI exists but the daemon may not be running.
    private func ensureDaemonRunning() async throws {
        let result = try await runDockerAllowingFailure(["info"])
        guard result.terminationStatus == 0 else {
            let detail = boundedDetail(from: result)
            let lowercased = detail.lowercased()
            if Self.daemonDownIndicators.contains(where: { lowercased.contains($0) }) {
                throw DockerRuntimeError.daemonNotRunning(detail)
            }
            throw DockerRuntimeError.commandFailed(
                command: "docker info",
                detail: detail
            )
        }
    }

    /// Preflight: Compose v2 must be available as the `docker compose`
    /// subcommand before any image pull, bootstrap, or `compose up` runs.
    private func ensureComposeV2Available() async throws {
        let result = try await runDockerAllowingFailure(["compose", "version"])
        guard result.terminationStatus == 0 else {
            throw DockerRuntimeError.composeV2Unavailable(boundedDetail(from: result))
        }
    }

    /// Keeps an image that is already present, builds from the configured
    /// context when one exists, and only falls back to pulling from the registry.
    private func ensureImage() async throws {
        let inspection = try await runDockerAllowingFailure(
            ["image", "inspect", configuration.image]
        )
        if inspection.terminationStatus == 0 {
            return
        }

        if let buildContextURL = configuration.buildContextURL {
            _ = try await runDocker(
                ["build", "--tag", configuration.image, buildContextURL.path],
                label: "docker build"
            )
            return
        }

        let pull = try await runDockerAllowingFailure(["pull", configuration.image])
        guard pull.terminationStatus == 0 else {
            throw DockerRuntimeError.imageUnavailable(
                image: configuration.image,
                detail: boundedDetail(from: pull)
            )
        }
    }

    /// One-time `co auth` in a throwaway container, skipped when the host
    /// `.env` already holds credentials matching the container-side identity.
    /// Returns true when fresh credentials had to be copied out.
    @discardableResult
    private func bootstrapAccountIfNeeded() async throws -> Bool {
        if let values = try? environmentValues(at: configuration.environmentURL),
           DockerRuntimeConfiguration.requiredCredentialKeys.allSatisfy({
               !(values[$0] ?? "").isEmpty
           }),
           try await persistedIdentityMatchesEnvironment() {
            return false
        }

        let existingBootstrap = try await runDockerAllowingFailure(
            ["container", "inspect", DockerRuntimeConfiguration.bootstrapContainerName]
        )
        if existingBootstrap.terminationStatus == 0 {
            _ = try await runDocker(
                ["rm", "-f", DockerRuntimeConfiguration.bootstrapContainerName],
                label: "remove interrupted bootstrap container"
            )
        }

        _ = try await runCompose(
            [
                "run",
                "--name", DockerRuntimeConfiguration.bootstrapContainerName,
                "--no-deps",
                "agent",
                "co",
                "auth"
            ],
            label: "Docker account setup"
        )

        let temporaryEnvironmentURL = configuration.runtimeDirectoryURL
            .appendingPathComponent(".env.bootstrap-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: temporaryEnvironmentURL)
        }

        _ = try await runDocker(
            [
                "cp",
                "\(DockerRuntimeConfiguration.bootstrapContainerName):/home/appuser/.co/keys.env",
                temporaryEnvironmentURL.path
            ],
            label: "copy Docker account credentials"
        )

        let values = try environmentValues(at: temporaryEnvironmentURL)
        guard DockerRuntimeConfiguration.requiredCredentialKeys.allSatisfy({
            !(values[$0] ?? "").isEmpty
        }) else {
            throw DockerRuntimeError.credentialsMissing
        }

        try mergeCredentials(
            values,
            into: configuration.environmentURL
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configuration.environmentURL.path
        )

        _ = try await runDocker(
            ["rm", DockerRuntimeConfiguration.bootstrapContainerName],
            label: "remove bootstrap container"
        )
        return true
    }

    /// Detects drift between the container-side identity and the host `.env`
    /// so edited or stale credentials trigger a fresh bootstrap.
    private func persistedIdentityMatchesEnvironment() async throws -> Bool {
        let script = """
        import os, pathlib, sys
        path = pathlib.Path('/home/appuser/.co/keys.env')
        values = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line) if path.exists() else {}
        required = ('AGENT_ADDRESS', 'AGENT_EMAIL', 'OPENONION_API_KEY')
        sys.exit(0 if all(values.get(key) == os.environ.get(key) for key in required) else 1)
        """
        let result = try await runDockerAllowingFailure(
            configuration.composeArguments + [
                "run", "--rm", "--no-deps", "agent", "python", "-c", script
            ]
        )
        return result.terminationStatus == 0
    }

    private func validateEnvironmentSyntax() throws {
        let contents = try String(
            contentsOf: configuration.environmentURL,
            encoding: .utf8
        )
        for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw DockerRuntimeError.invalidEnvironment(line: index + 1)
            }
            let key = String(line[..<separator])
            guard let first = key.first,
                  first == "_" || first.isLetter,
                  key.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }) else {
                throw DockerRuntimeError.invalidEnvironment(line: index + 1)
            }
        }
    }

    /// Rewrites only the credential lines in place and appends missing keys,
    /// leaving the user's comments and other settings untouched.
    private func mergeCredentials(
        _ credentials: [String: String],
        into environmentURL: URL
    ) throws {
        let existing = (try? String(contentsOf: environmentURL, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: .newlines)
        var updatedKeys = Set<String>()

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"),
                  let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = String(trimmed[..<separator])
            guard DockerRuntimeConfiguration.requiredCredentialKeys.contains(key),
                  let value = credentials[key] else {
                continue
            }
            lines[index] = "\(key)=\(value)"
            updatedKeys.insert(key)
        }

        for key in DockerRuntimeConfiguration.requiredCredentialKeys
        where !updatedKeys.contains(key) {
            guard let value = credentials[key] else {
                throw DockerRuntimeError.credentialsMissing
            }
            lines.append("\(key)=\(value)")
        }

        var merged = lines.joined(separator: "\n")
        if !merged.hasSuffix("\n") {
            merged.append("\n")
        }
        try merged.write(to: environmentURL, atomically: true, encoding: .utf8)
    }

    private func environmentValues(at url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = String(trimmed[..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
            values[key] = value
        }
        return values
    }

    private func runCompose(
        _ arguments: [String],
        label: String,
        input: Data? = nil
    ) async throws -> DockerCommandResult {
        try await runDocker(
            configuration.composeArguments + arguments,
            label: label,
            input: input
        )
    }

    private func runDocker(
        _ arguments: [String],
        label: String,
        input: Data? = nil
    ) async throws -> DockerCommandResult {
        let result = try await runDockerAllowingFailure(arguments, input: input)
        guard result.terminationStatus == 0 else {
            throw commandError(label: label, result: result)
        }
        return result
    }

    /// Hops to a detached task so the blocking process wait never ties up the
    /// caller's actor; a nonzero exit is returned, not thrown.
    private func runDockerAllowingFailure(
        _ arguments: [String],
        input: Data? = nil
    ) async throws -> DockerCommandResult {
        let executor = executor
        let executableURL = configuration.dockerExecutableURL
        let environment = configuration.dockerEnvironment
        return try await Task.detached {
            try executor.runSynchronously(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                standardInput: input
            )
        }.value
    }

    private func commandError(
        label: String,
        result: DockerCommandResult
    ) -> DockerRuntimeError {
        .commandFailed(command: label, detail: boundedDetail(from: result))
    }

    private func boundedDetail(from result: DockerCommandResult) -> String {
        let rawDetail = result.standardError.isEmpty
            ? result.standardOutput
            : result.standardError
        let detail = String(rawDetail.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).suffix(2_000))
        return detail.isEmpty ? "exit code \(result.terminationStatus)" : detail
    }
}

/// Narrows the runtime service to account reads so identity features never
/// gain the ability to start or stop containers.
protocol DockerAccountProviding {
    func accountStatus() async throws -> String
    func credentials() throws -> [String: String]
    func recoveryWords() throws -> [String]
}

/// The full service is the production account provider.
extension DockerRuntimeService: DockerAccountProviding {}

/// Voice transcription surface, kept separate so audio features need no
/// access to the container lifecycle.
protocol DockerTranscriptionProviding {
    func transcribeRecording(_ audioData: Data) async throws -> String
}

/// The full service is the production transcription provider.
extension DockerRuntimeService: DockerTranscriptionProviding {}

/// Main-actor owner of the runtime: discovers the Docker CLI, compose file,
/// and image, publishes status for SwiftUI, and guards against overlapping
/// start or configuration runs.
@MainActor
final class DockerRuntimeManager: ObservableObject {
    static let shared = DockerRuntimeManager()
    private static let legacyWorkspaceStorageKey = "agentWorkspaceDirectory"

    @Published private(set) var status: DockerRuntimeStatus = .idle
    @Published private(set) var configurationActionMessage: String?

    private let executor: DockerCommandExecuting
    private let fileManager: FileManager
    private let bundle: Bundle
    private let environment: [String: String]
    private let runtimeDirectoryOverride: URL?
    private let composeSourceOverride: URL?
    private var service: DockerRuntimeService?
    private var isStarting = false

    init(
        executor: DockerCommandExecuting = ProcessDockerCommandExecutor(),
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storage: UserDefaults = .standard,
        runtimeDirectory: URL? = nil,
        composeSource: URL? = nil
    ) {
        self.executor = executor
        self.fileManager = fileManager
        self.bundle = bundle
        self.environment = environment
        runtimeDirectoryOverride = runtimeDirectory
        composeSourceOverride = composeSource
        Self.clearLegacyWorkspacePreference(in: storage)
    }

    static func clearLegacyWorkspacePreference(in storage: UserDefaults) {
        storage.removeObject(forKey: Self.legacyWorkspaceStorageKey)
    }

    /// Safe to call repeatedly: re-entry while starting or already ready is
    /// ignored, and any failure is classified for guided remediation.
    func start() async {
        guard !isStarting, status != .ready else {
            return
        }
        isStarting = true
        configurationActionMessage = nil
        defer { isStarting = false }

        do {
            let service = try makeService()
            self.service = service
            try await service.start { [weak self] progress in
                self?.status = .starting(progress)
            }
            status = .ready
        } catch {
            status = .failed(DockerStartupFailure(error: error))
        }
    }

    /// Computed without building the service, so the `.env` path can still be
    /// shown when the Docker CLI has not been found.
    var configurationFileURL: URL? {
        if let runtimeDirectoryOverride {
            return runtimeDirectoryOverride.appendingPathComponent(".env")
        }
        return try? Self.defaultRuntimeDirectory(
            fileManager: fileManager
        ).appendingPathComponent(".env")
    }

    var configurationFilePath: String {
        configurationFileURL?.path ?? "Docker runtime is unavailable"
    }

    func revealConfigurationFile() {
        do {
            let url = try makeAccountService().prepareConfigurationFile()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            configurationActionMessage = "Revealed the Docker .env file in Finder."
        } catch {
            configurationActionMessage = error.localizedDescription
        }
    }

    func copyConfigurationPath() {
        guard let configurationFileURL else {
            configurationActionMessage = "Docker runtime is unavailable."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(configurationFileURL.path, forType: .string)
        configurationActionMessage = "Copied the Docker .env path."
    }

    func applyConfigurationAndRestart() async {
        guard !isStarting else {
            return
        }
        isStarting = true
        configurationActionMessage = nil
        defer { isStarting = false }

        do {
            let candidateService = try makeService()
            let restoredIdentity = try await candidateService
                .applyConfiguration { [weak self] progress in
                    self?.status = .starting(progress)
                }
            service = candidateService
            status = .ready
            configurationActionMessage = restoredIdentity
                ? "Configuration applied. Docker identity credentials were restored."
                : "Configuration applied and all Docker agents restarted."
        } catch {
            status = .failed(DockerStartupFailure(error: error))
            configurationActionMessage = error.localizedDescription
        }
    }

    func stopSynchronously() {
        guard let service else {
            status = .stopped
            return
        }
        status = .stopping
        do {
            try service.stopSynchronously()
            status = .stopped
        } catch {
            status = .failed(DockerStartupFailure(error: error))
        }
    }

    func makeAccountService() throws -> DockerRuntimeService {
        if let service {
            return service
        }
        let created = try makeService()
        service = created
        return created
    }

    func makeTranscriptionService() throws -> DockerRuntimeService {
        try makeAccountService()
    }

    private func makeService() throws -> DockerRuntimeService {
        guard let dockerExecutableURL = Self.findDockerExecutable(
            environment: environment,
            fileManager: fileManager
        ) else {
            throw DockerRuntimeError.dockerUnavailable
        }
        guard let composeSourceURL = composeSourceOverride
            ?? Self.findComposeSource(bundle: bundle, environment: environment)
        else {
            throw DockerRuntimeError.composeResourceMissing
        }

        let runtimeDirectoryURL = try resolvedRuntimeDirectory()
        let sourceDirectory = composeSourceURL.deletingLastPathComponent()
        let dockerfileURL = sourceDirectory.appendingPathComponent("Dockerfile")
        let buildContextURL = fileManager.fileExists(atPath: dockerfileURL.path)
            ? sourceDirectory
            : nil
        let image = Self.resolveImage(
            bundle: bundle,
            environment: environment,
            buildContextURL: buildContextURL,
            fileManager: fileManager
        )

        return DockerRuntimeService(
            configuration: DockerRuntimeConfiguration(
                dockerExecutableURL: dockerExecutableURL,
                composeSourceURL: composeSourceURL,
                runtimeDirectoryURL: runtimeDirectoryURL,
                image: image,
                buildContextURL: buildContextURL
            ),
            executor: executor,
            fileManager: fileManager
        )
    }

    private func resolvedRuntimeDirectory() throws -> URL {
        if let runtimeDirectoryOverride {
            return runtimeDirectoryOverride
        }
        return try Self.defaultRuntimeDirectory(fileManager: fileManager)
    }

    /// Finder-launched apps inherit no shell PATH, so the CLI is probed at an
    /// explicit override followed by the well-known install locations.
    static func findDockerExecutable(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        var candidates: [String] = []
        if let explicit = environment["CONNECTONION_DOCKER_CLI"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        candidates += [
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/usr/bin/docker"
        ]
        if let homeDirectory = environment["HOME"], !homeDirectory.isEmpty {
            candidates.append("\(homeDirectory)/.docker/bin/docker")
        }
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    static func defaultRuntimeDirectory(
        fileManager: FileManager
    ) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("ConnectOnionMacClient", isDirectory: true)
        .appendingPathComponent("DockerRuntime", isDirectory: true)
    }

    /// Resolution order: explicit override, the bundled resource, then the
    /// compose file beside this source file in DEBUG builds only.
    static func findComposeSource(
        bundle: Bundle,
        environment: [String: String]
    ) -> URL? {
        if let explicit = environment["CONNECTONION_DOCKER_COMPOSE_FILE"],
           !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        if let bundled = bundle.url(
            forResource: "docker-compose",
            withExtension: "yml"
        ) {
            return bundled
        }
#if DEBUG
        // This file lives in Services/, so the repository root — where
        // docker-compose.yml and the Dockerfile sit — is two levels up.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceCompose = sourceRoot.appendingPathComponent("docker-compose.yml")
        if FileManager.default.fileExists(atPath: sourceCompose.path) {
            return sourceCompose
        }
#endif
        return nil
    }

    /// The image tag for this runtime.
    ///
    /// An explicit override — the `CONNECTONION_DOCKER_IMAGE` env var, or a
    /// bundled `ConnectOnionDockerImage` Info.plist value — is honored verbatim
    /// so a pinned registry image is respected. Otherwise, when a local build
    /// context exists, the tag carries a hash of everything docker copies into
    /// the image. Any change to host_agent.py or the rest of the context yields
    /// a new tag, so `ensureImage` can never reuse a stale image that predates
    /// the change — the failure mode where a teammate keeps running an old agent
    /// after pulling new source. With no build context the default registry tag
    /// is pulled as-is.
    static func resolveImage(
        bundle: Bundle,
        environment: [String: String],
        buildContextURL: URL?,
        fileManager: FileManager
    ) -> String {
        if let explicit = environment["CONNECTONION_DOCKER_IMAGE"],
           !explicit.isEmpty {
            return explicit
        }
#if !DEBUG
        if let configured = bundle.object(
            forInfoDictionaryKey: "ConnectOnionDockerImage"
        ) as? String, !configured.isEmpty {
            return configured
        }
#endif
        let repository = "co-agent"
        if let buildContextURL,
           let digest = buildContextDigest(
               at: buildContextURL,
               fileManager: fileManager
           ) {
            return "\(repository):\(digest)"
        }
        return "\(repository):1.0"
    }

    /// A stable 12-hex-character digest of every regular file docker would copy
    /// out of `directoryURL`, so a locally built image can be tagged by its
    /// content. Hidden files (`.DS_Store`, …) are skipped so editor/OS churn
    /// never forces a needless rebuild. Returns nil when the context cannot be
    /// read, letting the caller fall back to the default tag.
    static func buildContextDigest(
        at directoryURL: URL,
        fileManager: FileManager
    ) -> String? {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let base = directoryURL.standardizedFileURL.path + "/"
        var relativePaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard
                let isRegularFile = try? fileURL.resourceValues(
                    forKeys: Set(keys)
                ).isRegularFile,
                isRegularFile
            else {
                continue
            }
            relativePaths.append(
                fileURL.standardizedFileURL.path.replacingOccurrences(
                    of: base,
                    with: ""
                )
            )
        }
        relativePaths.sort()

        var hasher = SHA256()
        for relativePath in relativePaths {
            hasher.update(data: Data(relativePath.utf8))
            let fileURL = directoryURL.appendingPathComponent(relativePath)
            guard let contents = try? Data(contentsOf: fileURL) else {
                return nil
            }
            hasher.update(data: contents)
        }
        let hexDigest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return String(hexDigest.prefix(12))
    }
}
