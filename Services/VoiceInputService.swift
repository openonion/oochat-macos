import AVFoundation
import Combine
import Foundation

enum ConnectOnionTranscriptionError: LocalizedError {
    case agentUnavailable
    case transcriptionFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .agentUnavailable:
            return "Voice transcription needs the local Main Agent. "
                + "Start Docker Desktop, wait for the agent to come online, then try again."
        case .transcriptionFailed(let detail):
            return detail.isEmpty
                ? "ConnectOnion could not transcribe the recording."
                : "ConnectOnion transcription failed: \(detail)"
        case .invalidResponse:
            return "ConnectOnion returned an invalid transcription response."
        }
    }
}

@MainActor
protocol AudioTranscribing {
    func transcribe(audioURL: URL) async throws -> String
}

protocol AudioRecording: AnyObject {
    func prepareToRecord() -> Bool
    func record() -> Bool
    func stop()
}

extension AVAudioRecorder: AudioRecording {}

/// Sends the recorded audio to the Docker-hosted Main Agent, which runs the
/// bundled `transcribe_audio.py` with its packaged ConnectOnion install and
/// the Docker account credentials. The host machine needs no Python
/// environment, no `co auth`, and no host-side credits.
@MainActor
final class DockerAgentTranscriptionService {
    private struct Response: Decodable {
        let text: String
    }

    /// Compose diagnostics that mean the agent container is not up, as
    /// opposed to a transcription failure inside a healthy container.
    private static let agentDownIndicators = [
        "is not running",
        "no container",
        "no such service"
    ]

    private let providerFactory: @MainActor () throws -> any DockerTranscriptionProviding

    init(
        providerFactory: (@MainActor () throws -> any DockerTranscriptionProviding)? = nil
    ) {
        self.providerFactory = providerFactory ?? {
            try DockerRuntimeManager.shared.makeTranscriptionService()
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw ConnectOnionTranscriptionError.transcriptionFailed(
                error.localizedDescription
            )
        }

        let provider = try providerFactory()
        let output: String
        do {
            output = try await provider.transcribeRecording(audioData)
        } catch let error as DockerRuntimeError {
            guard case .commandFailed(_, let detail) = error else {
                throw error
            }
            let lowercased = detail.lowercased()
            if Self.agentDownIndicators.contains(where: { lowercased.contains($0) }) {
                throw ConnectOnionTranscriptionError.agentUnavailable
            }
            throw ConnectOnionTranscriptionError.transcriptionFailed(detail)
        }

        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ConnectOnionTranscriptionError.invalidResponse
        }
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension DockerAgentTranscriptionService: AudioTranscribing {}

@MainActor
final class VoiceInputService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcript = ""
    @Published var errorMessage: String?

    private let transcriber: any AudioTranscribing
    private let permissionRequester: (@escaping @Sendable (Bool) -> Void) -> Void
    private let recorderFactory: (URL, [String: Any]) throws -> any AudioRecording
    private var audioRecorder: (any AudioRecording)?
    private var recordingURL: URL?
    private var transcriptionTask: Task<Void, Never>?

    init(
        transcriber: (any AudioTranscribing)? = nil,
        permissionRequester: @escaping (@escaping @Sendable (Bool) -> Void) -> Void = { callback in
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: callback)
        },
        recorderFactory: @escaping (URL, [String: Any]) throws -> any AudioRecording = {
            try AVAudioRecorder(url: $0, settings: $1)
        }
    ) {
        self.transcriber = transcriber ?? DockerAgentTranscriptionService()
        self.permissionRequester = permissionRequester
        self.recorderFactory = recorderFactory
    }

    func startRecording() {
        guard !isRecording, !isTranscribing else { return }
        errorMessage = nil
        transcript = ""

        permissionRequester { granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    self.beginRecordingSession()
                } else {
                    self.errorMessage = "Microphone access is required for voice input."
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording, let recordingURL else { return }
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        self.recordingURL = nil

        isTranscribing = true
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: recordingURL)
                self.isTranscribing = false
                self.transcriptionTask = nil
            }
            do {
                let text = try await self.transcriber.transcribe(audioURL: recordingURL)
                guard !Task.isCancelled else { return }
                self.transcript = text
                if text.isEmpty {
                    self.errorMessage = "ConnectOnion did not detect any speech."
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func beginRecordingSession() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("connectonion-voice-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            let recorder = try recorderFactory(url, settings)
            guard recorder.prepareToRecord(), recorder.record() else {
                throw CocoaError(.fileWriteUnknown)
            }
            audioRecorder = recorder
            recordingURL = url
            isRecording = true
        } catch {
            try? FileManager.default.removeItem(at: url)
            errorMessage = "Could not start audio capture: \(error.localizedDescription)"
        }
    }
}
