import SwiftUI
import AppKit

struct GeneratedArtifactCard: View {
    let reference: GeneratedArtifactReference
    let store: GeneratedArtifactStore

    @State private var savedURL: URL?
    @State private var errorMessage: String?
    @State private var isAvailable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                fileIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text("GENERATED FILE")
                        .font(
                            .system(
                                size: AppFontSize.caption,
                                weight: .semibold
                            )
                        )
                        .tracking(0.6)
                        .foregroundStyle(.secondary)

                    Text(reference.name)
                        .font(.system(size: AppFontSize.body, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(metadataText)
                        .font(.system(size: AppFontSize.footnote))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                availabilityBadge
            }
            .padding(14)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    saveAsButton
                    saveToDesktopButton
                }

                VStack(spacing: 8) {
                    saveToDesktopButton
                    saveAsButton
                }
            }
            .padding(12)

            if let savedURL {
                savedLocationRow(savedURL)
            }

            if let errorMessage {
                statusRow(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    color: AppPalette.error
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(cornerRadius: 14)
        .onAppear {
            isAvailable = store.contains(reference)
            if !isAvailable {
                errorMessage = GeneratedArtifactStoreError.cacheMissing
                    .localizedDescription
            }
        }
    }

    private var fileIcon: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(AppPalette.brandSoft)
            .frame(width: 42, height: 42)
            .overlay {
                Image(systemName: fileSystemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
            }
    }

    private var availabilityBadge: some View {
        Label(
            isAvailable ? "Ready" : "Unavailable",
            systemImage: isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .font(.system(size: AppFontSize.caption, weight: .semibold))
        .foregroundStyle(isAvailable ? AppPalette.success : AppPalette.error)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            (isAvailable ? AppPalette.success : AppPalette.error)
                .opacity(0.1),
            in: Capsule()
        )
    }

    private var saveAsButton: some View {
        Button(action: saveAs) {
            Label("Save As…", systemImage: "folder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.appSecondary)
        .disabled(!isAvailable)
    }

    private var saveToDesktopButton: some View {
        Button(action: saveToDesktop) {
            Label("Save to Desktop", systemImage: "desktopcomputer")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.appPrimary)
        .disabled(!isAvailable)
    }

    private func statusRow(
        text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label {
            Text(text)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.system(size: AppFontSize.footnote))
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
    }

    private func savedLocationRow(_ url: URL) -> some View {
        Button {
            revealInFinder(url)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved to")
                        .fontWeight(.semibold)
                    Text(url.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .underline()
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.forward.square")
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: AppFontSize.footnote))
        .foregroundStyle(AppPalette.success)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.success.opacity(0.08))
        .help("Show in Finder")
        .accessibilityLabel("Saved to \(url.path). Show in Finder")
        .contextMenu {
            Button("Open File") {
                openSavedFile(url)
            }
            Button("Show in Finder") {
                revealInFinder(url)
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
    }

    private var metadataText: String {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(reference.sizeBytes),
            countStyle: .file
        )
        return "\(reference.mimeType) · \(size)"
    }

    private var fileSystemImage: String {
        if reference.mimeType.hasPrefix("image/") {
            return "photo"
        }
        if reference.mimeType.hasPrefix("audio/") {
            return "waveform"
        }
        if reference.mimeType.hasPrefix("video/") {
            return "film"
        }
        if reference.mimeType == "application/pdf" {
            return "doc.richtext"
        }
        if reference.mimeType.contains("zip")
            || reference.mimeType.contains("archive") {
            return "archivebox"
        }
        if reference.mimeType.hasPrefix("text/") {
            return "doc.text"
        }
        return "doc"
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.title = "Save Generated File"
        panel.nameFieldStringValue = reference.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        do {
            let savedURL = try store.save(
                reference,
                to: destination,
                replacingExisting: true
            )
            self.savedURL = savedURL
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            isAvailable = store.contains(reference)
        }
    }

    private func saveToDesktop() {
        do {
            let savedURL = try store.saveToDesktop(reference)
            self.savedURL = savedURL
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            isAvailable = store.contains(reference)
        }
    }

    private func revealInFinder(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            savedURL = nil
            errorMessage = "The saved file is no longer available at that path."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openSavedFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            savedURL = nil
            errorMessage = "The saved file is no longer available at that path."
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// Loads an agent-provided image with progress and failure fallbacks.

struct AgentRemoteImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(minHeight: 160)

            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 492, maxHeight: 600)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

            case .failure:
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Screenshot could not be loaded",
                        systemImage: "photo.badge.exclamationmark"
                    )
                    .foregroundColor(.secondary)
                    Link("Open image in browser", destination: url)
                }
                .frame(minHeight: 80)

            @unknown default:
                EmptyView()
            }
        }
    }
}

/// Displays the ordered execution trace associated with one user message.
