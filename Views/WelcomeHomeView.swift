import SwiftUI
import ConnectOnionKit

struct WelcomeHomeView: View {
    let configuration: GeneralAgentConfiguration
    let isConnected: Bool
    let connectionSnapshot: AgentConnectionSnapshot?
    let agentProfile: OIPAgentProfile?
    let onSelectPrompt: (String) -> Void

    @State private var areSkillsExpanded = true
    @State private var hoveredSkillName: String?

    private var skills: [OIPAgentSkill] {
        agentProfile?.skills ?? []
    }

    private var isUnnamed: Bool {
        configuration.name.isEmpty || configuration.name.hasPrefix("0x")
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text(configuration.name)
                    .font(isUnnamed ? OOFont.mono(size: 24) : OOFont.headline(size: 36))
                    .tracking(isUnnamed ? 0 : -0.72) // web: tracking-[-0.02em]
                    .foregroundStyle(OOColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                if agentProfile == nil {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(OOColor.inkTertiary)
                            .frame(width: 6, height: 6)

                        Text("Connecting")
                            .font(.system(size: 14))
                            .foregroundStyle(OOColor.inkSecondary)
                    }
                    .padding(.top, 8)
                } else if !skills.isEmpty {
                    skillsSection
                        .padding(.top, 32)
                }
            }
            .frame(maxWidth: 672, alignment: .topLeading) // web: max-w-[720] minus px-6
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .padding(.bottom, 16)
            // the scroller belongs to the pane, so it sits at the far right
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.visible)
        .background {
            LegacyScrollBarStyle()
        }
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    areSkillsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OOColor.inkSecondary)
                        .rotationEffect(.degrees(areSkillsExpanded ? 90 : 0))

                    OOSectionHeader("Skills", count: skills.count)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(areSkillsExpanded ? "Expanded" : "Collapsed")

            if areSkillsExpanded {
                VStack(spacing: 0) {
                    ForEach(skills, id: \.name) { skill in
                        Rectangle()
                            .fill(OOColor.hairline)
                            .frame(height: 1)

                        skillRow(skill)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func skillRow(_ skill: OIPAgentSkill) -> some View {
        Button {
            onSelectPrompt("/\(skill.name) ")
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(readableTitle(for: skill.name))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OOColor.ink)
                    .fixedSize(horizontal: true, vertical: false)

                Text(firstSentence(of: skill.description ?? ""))
                    .font(.system(size: 14))
                    .foregroundStyle(OOColor.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isConnected {
                    Text("Use →")
                        .font(.system(size: 13))
                        .foregroundStyle(OOColor.inkSecondary)
                        .fixedSize()
                        .opacity(hoveredSkillName == skill.name ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                hoveredSkillName = skill.name
            } else if hoveredSkillName == skill.name {
                hoveredSkillName = nil
            }
        }
        .disabled(!isConnected)
        .opacity(isConnected ? 1 : 0.5)
    }

    private func readableTitle(for name: String) -> String {
        name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                let value = String(word)
                if value.lowercased() == "ai" { return "AI" }
                return value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }

    private func firstSentence(of description: String) -> String {
        guard let range = description.range(
            of: #".+?[.!?。！？](?=\s|$)"#,
            options: .regularExpression
        ) else {
            return description
        }

        return String(description[range])
    }
}

private struct LegacyScrollBarStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            view.enclosingScrollView?.scrollerStyle = .legacy
        }

        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.enclosingScrollView?.scrollerStyle = .legacy
        }
    }
}
