import SwiftUI

/// Validates and builds address-based agent configurations for the connection form.
@MainActor
enum AgentSettingsForm {
    static func validationMessage(name: String, address: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Display name is required."
        }

        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAddress.isEmpty {
            return "Agent address or Direct URL is required."
        }
        if ConnectOnionAgentTarget.normalized(trimmedAddress) == nil {
            return "Enter a valid 0x address or HTTP(S) URL."
        }
        return nil
    }

    static func configuration(name: String, address: String) -> GeneralAgentConfiguration {
        GeneralAgentConfiguration(
            name: name,
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: ConnectOnionAgentTarget.normalized(address)
                    ?? address.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }
}

/// Collects the display name and address needed to connect a hosted agent.
struct AgentSettingsView: View {
    @State private var agentName = "New Agent"
    @State private var addressConfiguration = AgentAddressConfiguration(agentAddress: "")
    @ObservedObject var appViewModel: AppViewModel

    init(
        appViewModel: AppViewModel,
        initialAgentName: String = "New Agent",
        initialAddress: String = ""
    ) {
        self.appViewModel = appViewModel
        _agentName = State(initialValue: initialAgentName)
        _addressConfiguration = State(
            initialValue: AgentAddressConfiguration(agentAddress: initialAddress)
        )
    }

    var body: some View {
        ZStack {
            AppBackground()

            content
        }
        .navigationTitle("Connect Agent")
    }

    private var content: some View {
        GeometryReader { geometry in
            let isFullscreen = geometry.size.height > 700

            ScrollView {
                innerContent
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: isFullscreen ? geometry.size.height : 0,
                        alignment: .center
                    )
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private var innerContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Display name")
                        styledTextField("New Agent", text: $agentName)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Agent address or Direct URL")
                        styledTextField(
                            "0x address or https://…",
                            text: $addressConfiguration.agentAddress
                        )

                        Text("Use the 0x address shown by `co host`, or an HTTP(S) Direct URL.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AppPalette.error)
                }

                Button {
                    appViewModel.saveAgent(makeAgentConfig())
                } label: {
                    Text("Connect Agent")
                        .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .foregroundColor(AppPalette.primaryActionForeground)
                        .background(AppPalette.primaryAction)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            }
            .padding(20)
            .cardStyle(cornerRadius: 12)
        }
        .frame(maxWidth: 540, alignment: .leading)
        .padding(24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button {
                    appViewModel.selection = appViewModel.previousSelection
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(AppPalette.surfaceMuted)
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .help("Back")

                Text("Connect Agent")
                    .font(.system(size: AppFontSize.pageTitle, weight: .semibold))
            }

            Text("Connect with a 0x address or HTTP(S) Direct URL")
                .font(.system(size: AppFontSize.body))
                .foregroundColor(.secondary)
                .padding(.leading, 38)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: AppFontSize.footnote, weight: .semibold))
            .tracking(1.0)
            .foregroundColor(.secondary)
    }

    private func styledTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(10)
            .background(fieldBackground)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.secondary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
    }

    private func makeAgentConfig() -> GeneralAgentConfiguration {
        AgentSettingsForm.configuration(
            name: agentName,
            address: addressConfiguration.agentAddress
        )
    }

    private var canSave: Bool {
        validationMessage == nil
    }

    private var validationMessage: String? {
        AgentSettingsForm.validationMessage(
            name: agentName,
            address: addressConfiguration.agentAddress
        )
    }
}
