import CryptoKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

final class GeneratedArtifactStoreTests: XCTestCase {
    func testRecordPersistsAcrossStoreInstancesWithOwnerOnlyPermissions() throws {
        let fixture = try ArtifactStoreFixture()
        defer { fixture.remove() }
        let payload = makePayload(name: "report.txt", data: Data("hello".utf8))

        let reference = try fixture.store.record(payload)
        let reloaded = GeneratedArtifactStore(
            rootDirectory: fixture.cacheDirectory,
            desktopDirectoryProvider: { fixture.desktopDirectory }
        )

        XCTAssertTrue(reloaded.contains(reference))
        let directoryPermissions = try permissions(at: fixture.cacheDirectory)
        XCTAssertEqual(directoryPermissions & 0o777, 0o700)
        let cachedFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.cacheDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertEqual(try permissions(at: cachedFile) & 0o777, 0o600)
    }

    func testRecordRejectsInvalidSizeHashAndName() throws {
        let fixture = try ArtifactStoreFixture()
        defer { fixture.remove() }
        let valid = makePayload(name: "valid.bin", data: Data([0, 1, 2]))

        var badSize = valid
        badSize.reference.sizeBytes += 1
        XCTAssertThrowsError(try fixture.store.record(badSize)) {
            XCTAssertEqual($0 as? GeneratedArtifactStoreError, .invalidSize)
        }

        var badHash = valid
        badHash.reference.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try fixture.store.record(badHash)) {
            XCTAssertEqual($0 as? GeneratedArtifactStoreError, .invalidHash)
        }

        var badName = valid
        badName.reference.name = "../escape.bin"
        XCTAssertThrowsError(try fixture.store.record(badName)) {
            XCTAssertEqual($0 as? GeneratedArtifactStoreError, .invalidName)
        }
    }

    func testSaveToDesktopAddsSuffixAndNeverOverwrites() throws {
        let fixture = try ArtifactStoreFixture()
        defer { fixture.remove() }
        let data = Data("new".utf8)
        let reference = try fixture.store.record(
            makePayload(name: "result.txt", data: data)
        )
        let original = fixture.desktopDirectory
            .appendingPathComponent("result.txt")
        try Data("existing".utf8).write(to: original)

        let saved = try fixture.store.saveToDesktop(reference)

        XCTAssertEqual(saved.lastPathComponent, "result (2).txt")
        XCTAssertEqual(try Data(contentsOf: original), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: saved), data)
    }

    func testSaveAsRequiresAnExplicitOverwriteDecision() throws {
        let fixture = try ArtifactStoreFixture()
        defer { fixture.remove() }
        let data = Data("replacement".utf8)
        let reference = try fixture.store.record(
            makePayload(name: "result.txt", data: data)
        )
        let destination = fixture.root.appendingPathComponent("chosen.txt")
        try Data("existing".utf8).write(to: destination)

        XCTAssertThrowsError(
            try fixture.store.save(
                reference,
                to: destination,
                replacingExisting: false
            )
        ) {
            XCTAssertEqual(
                $0 as? GeneratedArtifactStoreError,
                .destinationExists
            )
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))

        _ = try fixture.store.save(
            reference,
            to: destination,
            replacingExisting: true
        )
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    @MainActor
    func testDeletingChatRemovesCacheButNotPreviouslySavedCopy() async throws {
        let fixture = try ArtifactStoreFixture()
        defer { fixture.remove() }
        let suiteName = "GeneratedArtifactStoreTests.\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let payload = makePayload(name: "keep.txt", data: Data("copy".utf8))
        let reference = try fixture.store.record(payload)
        let saved = try fixture.store.saveToDesktop(reference)
        let configuration = GeneralAgentConfiguration(
            name: "Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: String(repeating: "0", count: 42)
            )
        )
        let session = ChatSession(
            agentConfigId: configuration.id,
            title: "Artifacts"
        )
        let appViewModel = AppViewModel(
            storage: storage,
            generatedArtifactStore: fixture.store,
            localAgentDefinitions: []
        )
        appViewModel.configurations = [configuration]
        appViewModel.sessions = [session]
        appViewModel.messages = [
            ChatMessage(
                sessionId: session.id,
                role: .agent,
                content: "Done",
                artifacts: [reference]
            )
        ]

        appViewModel.deleteSession(session)

        XCTAssertFalse(fixture.store.contains(reference))
        XCTAssertEqual(try Data(contentsOf: saved), payload.data)
        await Task.yield()
    }

    private func makePayload(
        name: String,
        data: Data
    ) -> GeneratedArtifactPayload {
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return GeneratedArtifactPayload(
            reference: GeneratedArtifactReference(
                artifactID: UUID().uuidString,
                name: name,
                mimeType: "application/octet-stream",
                sizeBytes: data.count,
                sha256: hash
            ),
            data: data
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.posixPermissions] as? NSNumber
        return try XCTUnwrap(value).intValue
    }
}

private final class ArtifactStoreFixture {
    let root: URL
    let cacheDirectory: URL
    let desktopDirectory: URL
    let store: GeneratedArtifactStore

    init(fileManager: FileManager = .default) throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("artifact-store-\(UUID().uuidString)")
        cacheDirectory = root.appendingPathComponent("cache")
        desktopDirectory = root.appendingPathComponent("Desktop")
        try fileManager.createDirectory(
            at: desktopDirectory,
            withIntermediateDirectories: true
        )
        store = GeneratedArtifactStore(
            rootDirectory: cacheDirectory,
            desktopDirectoryProvider: { [desktopDirectory] in
                desktopDirectory
            }
        )
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root)
    }
}
