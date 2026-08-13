import SwiftUI

struct WelcomeHomeView: View {
    let configuration: GeneralAgentConfiguration
    let isConnected: Bool
    let connectionSnapshot: AgentConnectionSnapshot?
    let onSelectPrompt: (String) -> Void

    @State private var areToolsExpanded: Bool

    private struct Suggestion {
        let icon: String
        let title: String
        let description: String
        let prompt: String
    }

    private let suggestions: [Suggestion]

    init(
        configuration: GeneralAgentConfiguration,
        isConnected: Bool,
        connectionSnapshot: AgentConnectionSnapshot?,
        areToolsExpanded: Bool = false,
        onSelectPrompt: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.isConnected = isConnected
        self.connectionSnapshot = connectionSnapshot
        self.onSelectPrompt = onSelectPrompt
        _areToolsExpanded = State(initialValue: areToolsExpanded)
        suggestions = [
            Suggestion(
                icon: "questionmark.circle.fill",
                title: "Ask a question",
                description: "Get quick answers on anything",
                prompt: "Can you help me understand "
            ),
            Suggestion(
                icon: "doc.text.fill",
                title: "Summarize text",
                description: "Condense long text into key points",
                prompt: "Please summarize the following: "
            ),
            Suggestion(
                icon: "lightbulb.fill",
                title: "Brainstorm ideas",
                description: "Explore ideas and possibilities",
                prompt: "Help me brainstorm ideas for "
            )
        ]
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)

            AgentAvatarView(
                name: configuration.name,
                textColorHex: configuration.avatarTextColorHex,
                backgroundColorHex: configuration.avatarBackgroundColorHex,
                size: 56
            )

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(configuration.name)
                        .font(.system(size: AppFontSize.pageTitle, weight: .semibold))
                        .foregroundColor(.primary)

                    Circle()
                        .fill(isConnected ? AppPalette.success : AppPalette.error)
                        .frame(width: 7, height: 7)

                    Text(isConnected ? "online" : "offline")
                        .font(AppTypography.mono(size: AppFontSize.caption, weight: .medium))
                        .foregroundColor(isConnected ? AppPalette.success : AppPalette.error)
                }

                Text(metadataText)
                    .font(AppTypography.mono(size: AppFontSize.caption))
                    .foregroundColor(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
                spacing: 10
            ) {
                ForEach(suggestions, id: \.title) { suggestion in
                    Button {
                        onSelectPrompt(suggestion.prompt)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: suggestion.icon)
                                .font(.system(size: AppFontSize.subheadline, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(suggestion.title)
                                    .font(.system(size: AppFontSize.body, weight: .medium))
                                    .foregroundColor(.primary)

                                Text(suggestion.description)
                                    .font(.system(size: AppFontSize.footnote))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(AppPalette.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 560)

            if !tools.isEmpty {
                VStack(spacing: 10) {
                    Button {
                        areToolsExpanded.toggle()
                    } label: {
                        HStack(spacing: 7) {
                            Text("\(tools.count) tools")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(areToolsExpanded ? 180 : 0))
                        }
                        .font(AppTypography.mono(size: AppFontSize.caption, weight: .medium))
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(areToolsExpanded ? "Hide agent tools" : "Show agent tools")
                    .help(areToolsExpanded ? "Hide agent tools" : "Show agent tools")

                    if areToolsExpanded {
                        ScrollView {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                                alignment: .leading,
                                spacing: 8
                            ) {
                                ForEach(tools, id: \.self) { tool in
                                    Text(tool)
                                        .font(AppTypography.mono(size: AppFontSize.footnote))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .frame(height: 32)
                                        .background(AppPalette.surfaceMuted)
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                            }
                        }
                        .frame(maxWidth: 560, maxHeight: 180)
                    }
                }
            }

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tools: [String] {
        connectionSnapshot?.tools ?? []
    }

    private var metadataText: String {
        var parts: [String] = []

        if let model = displayedModel {
            parts.append(model)
        }

        if let trust = connectionSnapshot?.trust?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trust.isEmpty {
            parts.append(trust)
        }

        if let version = connectionSnapshot?.version?.trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            parts.append(version.hasPrefix("v") ? version : "v\(version)")
        }

        return parts.isEmpty ? "Hosted agent" : parts.joined(separator: " · ")
    }

    private var displayedModel: String? {
        let model = connectionSnapshot?.model
        guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.hasPrefix("co/") ? String(trimmed.dropFirst(3)) : trimmed
    }
}

#Preview {
    ContentView()
}
