import Foundation
import XCTest
@testable import ConnectOnionMacClient

final class StubDockerAccountProvider: DockerAccountProviding {
    var statusOutput = "Balance: $0.00"
    var credentialValues: [String: String] = [
        "AGENT_ADDRESS": "0x" + String(repeating: "ab", count: 32),
        "OPENONION_API_KEY": "test-token"
    ]
    var words = ["apple", "bridge", "candle"]
    var statusError: Error?
    var credentialError: Error?
    var recoveryError: Error?
    private(set) var statusCallCount = 0

    func accountStatus() async throws -> String {
        statusCallCount += 1
        if let statusError {
            throw statusError
        }
        return statusOutput
    }

    func credentials() throws -> [String: String] {
        if let credentialError {
            throw credentialError
        }
        return credentialValues
    }

    func recoveryWords() throws -> [String] {
        if let recoveryError {
            throw recoveryError
        }
        return words
    }
}

final class StubDockerTranscriptionProvider: DockerTranscriptionProviding {
    var result: Result<String, Error> = .success(#"{"text": "ok"}"#)
    private(set) var audioPayloads: [Data] = []

    func transcribeRecording(_ audioData: Data) async throws -> String {
        audioPayloads.append(audioData)
        return try result.get()
    }
}

@MainActor
final class StubAudioTranscriber: AudioTranscribing {
    var result: Result<String, Error>
    private(set) var audioURLs: [URL] = []

    init(result: Result<String, Error>) {
        self.result = result
    }

    func transcribe(audioURL: URL) async throws -> String {
        audioURLs.append(audioURL)
        return try result.get()
    }
}

final class StubAudioRecorder: AudioRecording {
    var prepareResult = true
    var recordResult = true
    private(set) var stopCallCount = 0

    func prepareToRecord() -> Bool {
        prepareResult
    }

    func record() -> Bool {
        recordResult
    }

    func stop() {
        stopCallCount += 1
    }
}

private enum TestServiceError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test service failure"
    }
}

@MainActor
final class WalletServiceTests: XCTestCase {
    func testWalletErrorsHaveActionableDescriptions() {
        let descriptions = [
            WalletServiceError.commandUnavailable.localizedDescription,
            WalletServiceError.commandFailed.localizedDescription,
            WalletServiceError.balanceMissing.localizedDescription,
            WalletServiceError.recoverySeedMissing.localizedDescription,
            WalletServiceError.credentialMissing.localizedDescription
        ]

        XCTAssertTrue(descriptions.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(descriptions[0].contains("Docker Desktop"))
        XCTAssertTrue(descriptions[3].contains("recovery phrase"))
    }

    func testParsesBalanceFromStatusOutput() {
        let output = """
        ConnectOnion Account Status
        Balance:  $1,234.5678
        """

        XCTAssertEqual(WalletService.parseBalance(from: output), Decimal(string: "1234.5678"))
    }

    func testParsesBalanceFromANSIStyledStatusOutput() {
        let output = "\u{001B}[36mBalance:\u{001B}[0m $5.00"
        XCTAssertEqual(WalletService.parseBalance(from: output), Decimal(string: "5.00"))
    }

    func testBalanceParserSkipsMalformedValuesAndFindsLaterBalance() {
        let output = """
        Balance: unavailable
        Previous Balance: none
        Balance: 42.75 credits
        """

        XCTAssertEqual(WalletService.parseBalance(from: output), Decimal(string: "42.75"))
        XCTAssertNil(WalletService.parseBalance(from: "Status: online"))
    }

    func testFetchBalanceReadsDockerAccountStatus() async throws {
        let provider = StubDockerAccountProvider()
        provider.statusOutput = "Balance:  $4.2250\n"
        let service = WalletService(accountProvider: provider)

        let balance = try await service.fetchBalance()

        XCTAssertEqual(balance, Decimal(string: "4.2250"))
        XCTAssertEqual(provider.statusCallCount, 1)
    }

    func testDockerStatusFailureReturnsCommandError() async {
        let provider = StubDockerAccountProvider()
        provider.statusError = DockerRuntimeError.dockerUnavailable
        let service = WalletService(accountProvider: provider)

        do {
            _ = try await service.fetchBalance()
            XCTFail("Expected command failure")
        } catch let error as WalletServiceError {
            XCTAssertEqual(error, .commandFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingBalanceReturnsSpecificError() async {
        let provider = StubDockerAccountProvider()
        provider.statusOutput = "ConnectOnion Account Status\n"
        let service = WalletService(accountProvider: provider)

        do {
            _ = try await service.fetchBalance()
            XCTFail("Expected missing balance error")
        } catch let error as WalletServiceError {
            XCTAssertEqual(error, .balanceMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCredentialsAndRecoveryComeFromDockerRuntime() async throws {
        let provider = StubDockerAccountProvider()
        let service = WalletService(accountProvider: provider)

        let credentials = try await service.fetchCredentials()

        XCTAssertEqual(credentials.publicKey, provider.credentialValues["AGENT_ADDRESS"])
        XCTAssertEqual(credentials.jwt, provider.credentialValues["OPENONION_API_KEY"])
        XCTAssertEqual(try service.fetchRecoverySeed(), provider.words)
    }

    func testMissingCredentialsAndRecoveryReturnSpecificErrors() async {
        let provider = StubDockerAccountProvider()
        let service = WalletService(accountProvider: provider)

        provider.credentialValues["AGENT_ADDRESS"] = ""
        do {
            _ = try service.parseCredentials()
            XCTFail("Expected missing credential error")
        } catch let error as WalletServiceError {
            XCTAssertEqual(error, .credentialMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        provider.credentialValues["AGENT_ADDRESS"] = "0xtest"
        provider.credentialValues["OPENONION_API_KEY"] = ""
        do {
            _ = try service.parseCredentials()
            XCTFail("Expected missing credential error")
        } catch let error as WalletServiceError {
            XCTAssertEqual(error, .credentialMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        provider.credentialError = TestServiceError.failed
        do {
            _ = try service.parseCredentials()
            XCTFail("Expected missing credential error")
        } catch let error as WalletServiceError {
            XCTAssertEqual(error, .credentialMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        provider.words = []
        do {
            _ = try service.fetchRecoverySeed()
            XCTFail("Expected missing recovery seed error")
        } catch let error as WalletServiceError {
            XCTAssertEqual(error, .recoverySeedMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        provider.recoveryError = TestServiceError.failed
        do {
            _ = try service.fetchRecoverySeed()
            XCTFail("Expected missing recovery seed error")
        } catch let error as WalletServiceError {
            XCTAssertEqual(error, .recoverySeedMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTranscriptionErrorsHaveStableDescriptions() {
        XCTAssertTrue(
            ConnectOnionTranscriptionError.agentUnavailable.localizedDescription
                .contains("Main Agent")
        )
        XCTAssertEqual(
            ConnectOnionTranscriptionError.transcriptionFailed("").localizedDescription,
            "ConnectOnion could not transcribe the recording."
        )
        XCTAssertEqual(
            ConnectOnionTranscriptionError.transcriptionFailed("network").localizedDescription,
            "ConnectOnion transcription failed: network"
        )
        XCTAssertTrue(
            ConnectOnionTranscriptionError.invalidResponse.localizedDescription
                .contains("invalid transcription response")
        )
    }

    func testDockerTranscriptionSendsAudioAndDecodesAgentResponse() async throws {
        let provider = StubDockerTranscriptionProvider()
        provider.result = .success("{\"text\": \"  official transcript \\n\"}")
        let audioURL = try temporaryFile(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try Data("wav-bytes".utf8).write(to: audioURL)
        let service = DockerAgentTranscriptionService(providerFactory: { provider })

        let transcript = try await service.transcribe(audioURL: audioURL)

        XCTAssertEqual(transcript, "official transcript")
        XCTAssertEqual(provider.audioPayloads, [Data("wav-bytes".utf8)])
    }

    func testDockerTranscriptionMapsAgentAndContainerFailures() async throws {
        let audioURL = try temporaryFile(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let downProvider = StubDockerTranscriptionProvider()
        downProvider.result = .failure(DockerRuntimeError.commandFailed(
            command: "Voice transcription",
            detail: "service \"agent\" is not running"
        ))
        let downService = DockerAgentTranscriptionService(
            providerFactory: { downProvider }
        )
        do {
            _ = try await downService.transcribe(audioURL: audioURL)
            XCTFail("Expected the stopped agent to fail transcription")
        } catch let error as ConnectOnionTranscriptionError {
            guard case .agentUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let failingProvider = StubDockerTranscriptionProvider()
        failingProvider.result = .failure(DockerRuntimeError.commandFailed(
            command: "Voice transcription",
            detail: "OpenOnion API key required"
        ))
        let failingService = DockerAgentTranscriptionService(
            providerFactory: { failingProvider }
        )
        do {
            _ = try await failingService.transcribe(audioURL: audioURL)
            XCTFail("Expected the container diagnostic to surface")
        } catch let error as ConnectOnionTranscriptionError {
            XCTAssertEqual(
                error.localizedDescription,
                "ConnectOnion transcription failed: OpenOnion API key required"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let invalidProvider = StubDockerTranscriptionProvider()
        invalidProvider.result = .success("not-json")
        let invalidService = DockerAgentTranscriptionService(
            providerFactory: { invalidProvider }
        )
        do {
            _ = try await invalidService.transcribe(audioURL: audioURL)
            XCTFail("Expected invalid JSON to fail")
        } catch let error as ConnectOnionTranscriptionError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDockerTranscriptionSurfacesRuntimeSetupFailure() async throws {
        let audioURL = try temporaryFile(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let service = DockerAgentTranscriptionService(providerFactory: {
            throw DockerRuntimeError.dockerUnavailable
        })

        do {
            _ = try await service.transcribe(audioURL: audioURL)
            XCTFail("Expected the missing Docker CLI to fail transcription")
        } catch let error as DockerRuntimeError {
            XCTAssertTrue(error.localizedDescription.contains("Docker Desktop"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testVoiceInputHandlesPermissionDenialAndRecorderFailure() async {
        let deniedService = VoiceInputService(
            transcriber: StubAudioTranscriber(result: .success("unused")),
            permissionRequester: { $0(false) }
        )

        deniedService.startRecording()
        await waitUntil {
            deniedService.errorMessage == "Microphone access is required for voice input."
        }
        XCTAssertFalse(deniedService.isRecording)

        let recorder = StubAudioRecorder()
        recorder.prepareResult = false
        let recorderFailureService = VoiceInputService(
            transcriber: StubAudioTranscriber(result: .success("unused")),
            permissionRequester: { $0(true) },
            recorderFactory: { _, _ in recorder }
        )

        recorderFailureService.startRecording()
        await waitUntil {
            recorderFailureService.errorMessage?.contains("Could not start audio capture") == true
        }
        XCTAssertFalse(recorderFailureService.isRecording)
        recorderFailureService.stopRecording()
    }

    func testVoiceInputRecordsTranscribesAndRemovesTemporaryAudio() async {
        let transcriber = StubAudioTranscriber(result: .success("hello world"))
        let recorder = StubAudioRecorder()
        var capturedURL: URL?
        let service = VoiceInputService(
            transcriber: transcriber,
            permissionRequester: { $0(true) },
            recorderFactory: { url, _ in
                capturedURL = url
                try Data("audio".utf8).write(to: url)
                return recorder
            }
        )

        service.startRecording()
        await waitUntil { service.isRecording }
        service.startRecording()
        service.stopRecording()
        await waitUntil { !service.isTranscribing && service.transcript == "hello world" }

        XCTAssertEqual(recorder.stopCallCount, 1)
        XCTAssertEqual(transcriber.audioURLs, capturedURL.map { [$0] } ?? [])
        XCTAssertFalse(
            capturedURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
        )
        XCTAssertNil(service.errorMessage)
    }

    func testVoiceInputReportsEmptyAndFailedTranscriptions() async {
        let emptyService = makeRecordingService(
            transcriber: StubAudioTranscriber(result: .success(""))
        )
        emptyService.startRecording()
        await waitUntil { emptyService.isRecording }
        emptyService.stopRecording()
        await waitUntil {
            emptyService.errorMessage == "ConnectOnion did not detect any speech."
                && !emptyService.isTranscribing
        }

        let failedService = makeRecordingService(
            transcriber: StubAudioTranscriber(result: .failure(TestServiceError.failed))
        )
        failedService.startRecording()
        await waitUntil { failedService.isRecording }
        failedService.stopRecording()
        await waitUntil {
            failedService.errorMessage == "Test service failure"
                && !failedService.isTranscribing
        }
    }

    private func makeRecordingService(
        transcriber: StubAudioTranscriber
    ) -> VoiceInputService {
        VoiceInputService(
            transcriber: transcriber,
            permissionRequester: { $0(true) },
            recorderFactory: { _, _ in StubAudioRecorder() }
        )
    }

    private func temporaryFile(extension pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallet-service-test-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        try Data().write(to: url)
        return url
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
    }
}
