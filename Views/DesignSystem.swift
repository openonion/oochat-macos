import AppKit
import ConnectOnionKit
import SwiftUI

/// The app's colour roles, pointed at ConnectOnionKit's O Chat v12 tokens so
/// every screen follows the package. Screen owners replace these names with
/// OOColor directly in their N2.3 to N2.6 MRs, and the last of those deletes
/// this enum. The six agent accent colours are gone (story N2 AC4).
enum AppPalette {
    static let brandStart = OOColor.primary
    static let brandEnd = OOColor.primary
    static let brand = OOColor.primary
    /// Flat now: O Chat has no gradients.
    static let brandGradient = LinearGradient(
        colors: [OOColor.primary, OOColor.primary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let background = OOColor.paper
    static let surface = OOColor.paper
    static let surfaceMuted = OOColor.surface
    static let hoverSurface = OOColor.hover
    static let sidebarSurface = OOColor.surface
    static let toolbarSurface = OOColor.paper
    static let divider = OOColor.hairline
    static let brandSoft = OOColor.currentTint
    static let success = OOColor.live
    static let error = OOColor.failureText
    static let warning = OOColor.decisionMark
    static let warningText = OOColor.decisionText
    static let primaryAction = OOColor.primary
    static let primaryActionForeground = OOColor.onPrimary
}

/// Shared type scale. Values match the sizes previously hardcoded across
/// the views, so adopting the tokens is purely mechanical and does not
/// change rendering.
enum AppFontSize {
    /// Page titles (Settings, Connect Agent, welcome heading).
    static let pageTitle: CGFloat = 24
    /// Section titles inside pages.
    static let sectionTitle: CGFloat = 17
    /// Emphasized card titles and prominent labels.
    static let subheadline: CGFloat = 14
    /// Primary body and control text.
    static let body: CGFloat = 13
    /// Secondary text and captions.
    static let caption: CGFloat = 12
    /// Dense metadata, badges, and micro labels.
    static let footnote: CGFloat = 11
}

/// Maps app font weights to bundled monospaced font variants.
enum AppMonoFontWeight {
    case regular
    case medium
    case semibold
}

/// Bundled JetBrains Mono typography for chat content and technical data.
/// Falls back to the system monospaced face if the bundled font cannot load.
enum AppTypography {
    static let monoFamilyName = "JetBrains Mono"
    static var isMonoAvailable: Bool {
        NSFont(name: "JetBrainsMono-Regular", size: AppFontSize.body) != nil
    }

    static func mono(
        size: CGFloat,
        weight: AppMonoFontWeight = .regular
    ) -> Font {
        let (fontName, fallbackWeight): (String, Font.Weight) = switch weight {
        case .regular:
            ("JetBrainsMono-Regular", .regular)
        case .medium:
            ("JetBrainsMono-Medium", .medium)
        case .semibold:
            ("JetBrainsMono-SemiBold", .semibold)
        }

        guard NSFont(name: fontName, size: size) != nil else {
            return .system(size: size, weight: fallbackWeight, design: .monospaced)
        }
        return .custom(fontName, fixedSize: size)
    }
}

/// Three-way appearance preference. `system` resolves to
/// `preferredColorScheme(nil)`, i.e. the app follows macOS.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// App-wide AppKit appearance override; `nil` follows the system.
    /// Applied through `NSApp.appearance` because SwiftUI's
    /// `preferredColorScheme(nil)` does not reliably resume following the
    /// system after a forced value on macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Fills the current scene with the adaptive app background color.
struct AppBackground: View {
    var body: some View {
        AppPalette.background
            .ignoresSafeArea()
    }
}

/// Draws the shared surface, border, and shadow used by card containers.
struct CardBackground: View {
    var cornerRadius: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppPalette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppPalette.divider, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.02), radius: 3, x: 0, y: 1)
    }
}

/// Presents an SF Symbol on a reusable colored badge.
struct IconBadge: View {
    let systemName: String
    var color: Color
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundColor(.white)
            }
            .shadow(color: color.opacity(0.18), radius: 4, x: 0, y: 2)
    }
}

/// Resolves persisted avatar colors and supplies stable fallbacks.
enum AgentAvatarStyle {
    static let defaultTextColorHex = "#FFFFFF"
    static let defaultBackgroundColorHex = "#1F1F1F"

    static func textColor(from hex: String?) -> Color {
        Color(hex: hex ?? defaultTextColorHex) ?? .white
    }

    static func backgroundColor(from hex: String?) -> Color {
        Color(hex: hex ?? defaultBackgroundColorHex)
            ?? Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
    }
}

/// Displays deterministic initials using an agent's configured colors.
struct AgentAvatarView: View {
    let name: String
    let textColorHex: String?
    let backgroundColorHex: String?
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(AgentAvatarStyle.backgroundColor(from: backgroundColorHex))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(AgentAvatarStyle.textColor(from: textColorHex))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(size * 0.12)
            }
            .accessibilityLabel("\(name) avatar")
    }

    private var initials: String {
        let words = name.split { character in
            !character.isLetter && !character.isNumber
        }

        if words.count >= 2 {
            return words.prefix(2)
                .compactMap(\.first)
                .map(String.init)
                .joined()
                .uppercased()
        }

        if let word = words.first {
            return String(word.prefix(2)).uppercased()
        }

        return "?"
    }
}

/// Converts between persisted RGB hex strings and SwiftUI colors.
extension Color {
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let number = UInt64(value, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return AgentAvatarStyle.defaultBackgroundColorHex
        }

        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}

/// Applies the shared card shape and background treatment.
extension View {
    func cardStyle(cornerRadius: CGFloat = 20) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(CardBackground(cornerRadius: cornerRadius))
    }
}

/// Monochrome primary button: near-black in light mode, near-white in dark mode.
/// Replaces `.borderedProminent`, whose label stays white regardless of the
/// tint and becomes unreadable on the near-white dark-mode primaryAction.
struct PrimaryButtonStyle: ButtonStyle {
    var isCompact = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(
                size: isCompact ? AppFontSize.caption : AppFontSize.body,
                weight: .semibold
            ))
            .padding(.horizontal, isCompact ? 10 : 14)
            .frame(height: isCompact ? 26 : 32)
            .foregroundColor(AppPalette.primaryActionForeground)
            .background(AppPalette.primaryAction)
            .clipShape(RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous))
            .contentShape(Rectangle())
            .opacity(opacity(isPressed: configuration.isPressed))
    }

    private func opacity(isPressed: Bool) -> Double {
        if !isEnabled {
            return 0.45
        }
        return isPressed ? 0.78 : 1
    }
}

/// Neutral secondary button matching the primary button's geometry.
/// Destructive-role labels render in the error color.
struct SecondaryButtonStyle: ButtonStyle {
    var isCompact = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous)

        return configuration.label
            .font(.system(
                size: isCompact ? AppFontSize.caption : AppFontSize.body,
                weight: .semibold
            ))
            .padding(.horizontal, isCompact ? 10 : 14)
            .frame(height: isCompact ? 26 : 32)
            .foregroundColor(configuration.role == .destructive ? AppPalette.error : .primary)
            .background(shape.fill(AppPalette.surfaceMuted))
            .overlay(shape.stroke(AppPalette.divider, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(opacity(isPressed: configuration.isPressed))
    }

    private func opacity(isPressed: Bool) -> Double {
        if !isEnabled {
            return 0.45
        }
        return isPressed ? 0.78 : 1
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var appPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var appPrimaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(isCompact: true) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var appSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var appSecondaryCompact: SecondaryButtonStyle { SecondaryButtonStyle(isCompact: true) }
}
