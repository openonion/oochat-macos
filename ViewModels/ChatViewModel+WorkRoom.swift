import ConnectOnionKit
import Foundation

/// The chat's Work Rooms: feeding the store, the Claude Station pane, and dictation into a Work Room composer.
extension ChatViewModel {
    /// Revision-gated Work Room state, not transcript output, so it lands even while an interrupted run is discarded.
    func handleWorkRoomEvent(_ event: ConnectOnionTransportEvent) {
        switch event {
        case .workRoomFrame(let frame):
            workRooms.receive(frame)
            if workRooms.isStationHost { appViewModel.markClaudeStation(configuration.id) }
        case .workRoomSnapshot(let connected):
            workRooms.receiveSnapshot(connected)
        case .workRoomTransport(let frames, let send):
            workRooms.transport = WorkRoomTransport(frames: frames, sendReportingFailure: { frame, failed in
                Task {
                    if await !send(frame) { failed() }
                }
            })
        case .workRoomConnectionDropped:
            workRooms.connectionDidDrop()
        default:
            break
        }
    }

    /// The agent is a Claude Station: an outer INPUT or EXEC is never sent to it.
    var isStation: Bool {
        workRooms.isStationHost || agentProfile?.isClaudeStation == true || configuration.isClaudeStation
    }

    /// The Station's host asked for onboarding and none is in progress.
    var isStationAwaitingCode: Bool {
        if case .onboarding? = pendingInteraction { return true }
        return false
    }

    /// The Station pane's one field: the code is the invite code now and the pairing code once connected.
    func submitStationCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingInteraction = nil
        interactionError = nil
        stationInviteCode = trimmed
        stationOnboardingAttempt += 1
        workRooms.rememberOnboardingCode(trimmed)
    }

    /// Starts or stops dictating into a Work Room's draft. The transcript is appended to that
    /// draft and never sent. Ignored while the main composer is using the microphone.
    func toggleDictation(in roomID: String) {
        if dictatingRoomID == roomID {
            voiceInputService.stopRecording()
            return
        }
        guard dictatingRoomID == nil, !voiceInputService.isRecording, !voiceInputService.isTranscribing else { return }
        dictationGuidance = nil
        dictatingRoomID = roomID
        voiceInputService.startRecording()
    }

    /// Drops the Work Room's dictation without appending anything.
    func cancelDictation(in roomID: String) {
        dictationGuidance = nil
        guard dictatingRoomID == roomID else { return }
        dictatingRoomID = nil
        voiceInputService.cancel()
    }

    func workRoomMic(for roomID: String) -> OOWorkRoomMic {
        let state: OOWorkRoomMic.State
        if dictatingRoomID != roomID {
            state = .idle
        } else {
            state = voiceInputService.isTranscribing ? .transcribing : .recording
        }
        return OOWorkRoomMic(
            state: state,
            guidance: dictatingRoomID == nil || dictatingRoomID == roomID ? dictationGuidance : nil
        ) { [weak self] in self?.toggleDictation(in: roomID) }
    }
}
