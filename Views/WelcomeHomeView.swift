import SwiftUI
import ConnectOnionKit

struct WelcomeHomeView: View {
    let configuration: GeneralAgentConfiguration
    let isConnected: Bool
    let connectionSnapshot: AgentConnectionSnapshot?
    let agentProfile: OIPAgentProfile?
    /// The agent's Control Center page. Skills its buttons run come first among the chips.
    var dashboard: OIPDashboard?
    /// Puts text in the composer for the person to finish and send.
    let onSelectPrompt: (String) -> Void

    /// Chips on screen. With more skills than this, the last place opens the full list instead.
    static let starterSlots = 4

    @State private var hoveredChip: String?

    private var skills: [OIPAgentSkill] {
        StarterSkills.ordered(agentProfile?.skills ?? [], dashboard: dashboard)
    }

    private var starterSkills: [OIPAgentSkill] {
        skills.count > Self.starterSlots
            ? Array(skills.prefix(Self.starterSlots - 1))
            : skills
    }

    /// Tool tags shown for an agent without skills; the rest are counted as "+N more".
    static let toolTagLimit = 8

    /// The agent's tool names, from its profile or, before that arrives, its /info.
    private var tools: [String] {
        let profileTools = agentProfile?.tools ?? []
        return profileTools.isEmpty ? (connectionSnapshot?.tools ?? []) : profileTools
    }

    private var hint: String {
        guard agentProfile != nil else {
            return "Connecting…"
        }
        guard skills.isEmpty else {
            return "Pick a skill or type a message."
        }
        return Self.capabilitySentence(tools: tools) ?? "Type a message to start."
    }

    /// One plain line from the agent's tools, e.g. "Can read and edit files and run commands."
    /// Nil when no tool is a known kind, so the screen never guesses what an agent does.
    static func capabilitySentence(tools: [String]) -> String? {
        let kinds: [(phrase: String, words: [String])] = [
            ("read files", ["read", "glob", "grep", "list"]),
            ("edit files", ["write", "edit", "patch", "create_file", "delete"]),
            ("run commands", ["bash", "shell", "command", "exec", "run"]),
            ("browse the web", ["web", "fetch", "browser", "http"]),
            ("send email", ["mail"])
        ]
        let names = tools.map { $0.lowercased() }
        var phrases = kinds
            .filter { kind in names.contains { name in kind.words.contains { name.contains($0) } } }
            .map(\.phrase)

        if let read = phrases.firstIndex(of: "read files"), phrases.contains("edit files") {
            phrases[read] = "read and edit files"
            phrases.removeAll { $0 == "edit files" }
        }
        guard let last = phrases.last else {
            return nil
        }
        let list = phrases.count == 1
            ? last
            : phrases.dropLast().joined(separator: ", ") + " and " + last
        return "Can \(list)."
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

                Text(hint)
                    .font(.system(size: 14))
                    .foregroundStyle(OOColor.inkSecondary)
                    .padding(.top, 8)

                if !skills.isEmpty {
                    starterChips
                        .padding(.top, 24)
                } else if agentProfile != nil {
                    // No skills: show what the agent has to work with, and how starters get here.
                    if !tools.isEmpty {
                        toolTags
                            .padding(.top, 20)
                    }

                    Text("Skills you add in .co/skills show up here as one-click starters.")
                        .font(.system(size: 12))
                        .foregroundStyle(OOColor.inkTertiary)
                        .padding(.top, 16)
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

    /// The agent's tools as quiet tags: real names, not buttons.
    private var toolTags: some View {
        let shown = Array(tools.prefix(Self.toolTagLimit))
        let hidden = tools.count - shown.count

        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(shown, id: \.self) { tool in
                toolTag(tool)
            }
            if hidden > 0 {
                toolTag("+\(hidden) more")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tools: \(tools.joined(separator: ", "))")
    }

    private func toolTag(_ text: String) -> some View {
        Text(text)
            .font(OOFont.mono(size: 12))
            .foregroundStyle(OOColor.inkSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: OORadius.medium, style: .continuous)
                    .stroke(OOColor.hairline, lineWidth: 1)
            )
    }

    /// Up to four cards in two fixed columns: the skill name, then its first sentence on one line.
    /// The full description is the hover tooltip, for skills whose first sentence is cut off.
    private var starterChips: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: OOSpace.small, alignment: .leading),
                GridItem(.flexible(), alignment: .leading)
            ],
            alignment: .leading,
            spacing: OOSpace.small
        ) {
            ForEach(starterSkills, id: \.name) { skill in
                card(
                    "/\(skill.name)",
                    summary: firstSentence(of: skill.description ?? ""),
                    leadingSymbol: "command",
                    help: skill.description ?? "/\(skill.name)"
                ) {
                    onSelectPrompt("/\(skill.name) ")
                }
            }

            if skills.count > starterSkills.count {
                // A lone "/" opens the composer's skill palette with every skill.
                card(
                    "All \(skills.count) skills",
                    trailingSymbol: "chevron.right",
                    help: "Show every skill this agent has"
                ) {
                    onSelectPrompt("/")
                }
            }
        }
    }

    private func card(
        _ title: String,
        summary: String = "",
        leadingSymbol: String? = nil,
        trailingSymbol: String? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
        let isHovered = hoveredChip == title

        return Button(action: action) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        if let leadingSymbol {
                            chipSymbol(leadingSymbol)
                        }

                        Text(title)
                            .font(.system(size: 14))
                            .foregroundStyle(OOColor.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(OOColor.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // lines up under the name, past the glyph
                            .padding(.leading, leadingSymbol == nil ? 0 : 22)
                    }
                }

                Spacer(minLength: 0)

                if let trailingSymbol {
                    chipSymbol(trailingSymbol)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(isHovered ? OOColor.hover : OOColor.paper, in: shape)
            // The border brightens with the fill, so the card reads as clickable on the dark pane.
            .overlay(shape.stroke(isHovered ? OOColor.inkTertiary : OOColor.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                hoveredChip = title
            } else if hoveredChip == title {
                hoveredChip = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(help)
        .disabled(!isConnected)
        .opacity(isConnected ? 1 : 0.5)
    }

    /// The description's first sentence, so a card stays to one short line.
    private func firstSentence(of description: String) -> String {
        guard let range = description.range(
            of: #".+?[.!?。！？](?=\s|$)"#,
            options: .regularExpression
        ) else {
            return description
        }

        return String(description[range])
    }

    // The same green command glyph as the composer's skill palette, so the chips read as skills.
    private func chipSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(OOColor.primary)
            .frame(width: 15, height: 15)
            .accessibilityHidden(true)
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
