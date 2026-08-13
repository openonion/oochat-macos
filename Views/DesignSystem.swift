import SwiftUI
import AppKit

/// Centralizes adaptive colors and deterministic agent accent colors.
enum AppPalette {
    static let accents: [Color] = [
        Color(red: 0.85, green: 0.47, blue: 0.34),
        Color(red: 0.42, green: 0.56, blue: 0.70),
        Color(red: 0.55, green: 0.62, blue: 0.41),
        Color(red: 0.78, green: 0.45, blue: 0.44),
        Color(red: 0.40, green: 0.62, blue: 0.59),
        Color(red: 0.83, green: 0.65, blue: 0.36)
    ]

    static func accent(for seed: Int) -> Color {
        let normalizedIndex = ((seed % accents.count) + accents.count) % accents.count
        return accents[normalizedIndex]
    }

    static func accent(forName name: String) -> Color {
        var hash = 0
        for scalar in name.unicodeScalars {
            hash = hash &+ Int(scalar.value)
        }
        return accent(for: hash)
    }

    static let brandStart = adaptive(
        light: NSColor(srgbRed: 0.722, green: 0.337, blue: 0.231, alpha: 1),
        dark: NSColor(srgbRed: 0.878, green: 0.478, blue: 0.373, alpha: 1)
    )
    static let brandEnd = adaptive(
        light: NSColor(srgbRed: 0.663, green: 0.306, blue: 0.200, alpha: 1),
        dark: NSColor(srgbRed: 0.788, green: 0.396, blue: 0.302, alpha: 1)
    )
    static let brand = brandStart
    static let brandGradient = LinearGradient(
        colors: [brandStart, brandEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let background = adaptive(
        light: NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        dark: NSColor(srgbRed: 0.090, green: 0.090, blue: 0.090, alpha: 1)
    )

    static let surface = adaptive(
        light: NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        dark: NSColor(srgbRed: 0.129, green: 0.129, blue: 0.129, alpha: 1)
    )

    static let surfaceMuted = adaptive(
        light: NSColor(srgbRed: 0.957, green: 0.957, blue: 0.957, alpha: 1),
        dark: NSColor(srgbRed: 0.188, green: 0.188, blue: 0.188, alpha: 1)
    )

    static let hoverSurface = adaptive(
        light: NSColor(srgbRed: 0.925, green: 0.925, blue: 0.925, alpha: 1),
        dark: NSColor(srgbRed: 0.220, green: 0.220, blue: 0.220, alpha: 1)
    )

    static let sidebarSurface = adaptive(
        light: NSColor(srgbRed: 0.969, green: 0.969, blue: 0.973, alpha: 1),
        dark: NSColor(srgbRed: 0.051, green: 0.051, blue: 0.051, alpha: 1)
    )

    static let toolbarSurface = adaptive(
        light: NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        dark: NSColor(srgbRed: 0.090, green: 0.090, blue: 0.090, alpha: 1)
    )

    static let divider = adaptive(
        light: NSColor(srgbRed: 0.898, green: 0.898, blue: 0.898, alpha: 1),
        dark: NSColor(srgbRed: 0.247, green: 0.247, blue: 0.247, alpha: 1)
    )

    static let brandSoft = adaptive(
        light: NSColor(srgbRed: 0.969, green: 0.906, blue: 0.882, alpha: 1),
        dark: NSColor(srgbRed: 0.227, green: 0.141, blue: 0.118, alpha: 1)
    )

    static let success = adaptive(
        light: NSColor(srgbRed: 0.063, green: 0.639, blue: 0.498, alpha: 1),
        dark: NSColor(srgbRed: 0.098, green: 0.765, blue: 0.490, alpha: 1)
    )

    static let error = adaptive(
        light: NSColor(srgbRed: 0.863, green: 0.149, blue: 0.149, alpha: 1),
        dark: NSColor(srgbRed: 0.937, green: 0.267, blue: 0.267, alpha: 1)
    )

    static let warning = adaptive(
        light: NSColor(srgbRed: 0.651, green: 0.380, blue: 0.078, alpha: 1),
        dark: NSColor(srgbRed: 0.918, green: 0.635, blue: 0.255, alpha: 1)
    )

    static let primaryAction = adaptive(
        light: NSColor(srgbRed: 0.090, green: 0.090, blue: 0.090, alpha: 1),
        dark: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.949, alpha: 1)
    )

    static let primaryActionForeground = adaptive(
        light: NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        dark: NSColor(srgbRed: 0.090, green: 0.090, blue: 0.090, alpha: 1)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }
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
