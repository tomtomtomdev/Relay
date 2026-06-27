//
//  DesignComponents.swift
//  Relay
//
//  Slice 10 — the SwiftUI bridge over the pure `RelayTheme` core, plus the small,
//  reusable components later slices compose (status cards, dots, the green toggle, pills,
//  the terminal text style). Views stay thin: every colour comes from `RelayPalette` via
//  `Color(_:_: )`, resolved against the live `@Environment(\.colorScheme)` so both
//  appearances are supported automatically.
//

import SwiftUI

// MARK: - Bridge

extension Appearance {
    /// Map SwiftUI's `ColorScheme` onto the Foundation-only `Appearance`.
    init(_ scheme: ColorScheme) { self = (scheme == .dark) ? .dark : .light }
}

extension Color {
    /// Resolve a semantic design token to a SwiftUI `Color` for the given scheme.
    init(_ token: PaletteToken, _ scheme: ColorScheme) {
        self.init(RelayPalette.resolve(token, Appearance(scheme)))
    }

    /// Build a SwiftUI `Color` from a parsed `RGBA` — for one-off design values that sit
    /// outside the semantic palette (e.g. the app-mark's steel gradient stops).
    init(_ rgba: RGBA) {
        self.init(
            .sRGB,
            red: Double(rgba.r) / 255,
            green: Double(rgba.g) / 255,
            blue: Double(rgba.b) / 255,
            opacity: Double(rgba.a) / 255
        )
    }
}

// MARK: - Shape / spacing / type tokens

enum RelayRadius {
    static let window: CGFloat = 12
    static let card: CGFloat = 10
    static let control: CGFloat = 8
    static let field: CGFloat = 7
    static let chip: CGFloat = 6
}

enum RelayMetric {
    static let sidebarWidth: CGFloat = 204
    static let titlebarHeight: CGFloat = 46
    static let labelColumn: CGFloat = 140
    static let formRowGap: CGFloat = 16
    static let dotSize: CGFloat = 7
}

enum RelayFont {
    static let label = Font.system(size: 11, weight: .semibold)        // uppercase section/labels
    static let body = Font.system(size: 13)
    static let cardValue = Font.system(size: 14, weight: .semibold)
    static let title = Font.system(size: 15, weight: .bold)
    static let mono = Font.system(size: 12.5, design: .monospaced)     // terminal / tokens
    static let monoSmall = Font.system(size: 11, design: .monospaced)
}

// MARK: - Components

/// A 7px status dot tinted by its `DotState` (design: green/amber/red/gray).
struct StatusDot: View {
    @Environment(\.colorScheme) private var scheme
    let state: DotState
    var size: CGFloat = RelayMetric.dotSize

    init(_ state: DotState, size: CGFloat = RelayMetric.dotSize) {
        self.state = state
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(Color(state.token, scheme))
            .frame(width: size, height: size)
    }
}

/// A status card: uppercase label, a value with its status dot, and a mono detail line
/// (design frame 1 — Telegram Bot / Source Chat / Claude Code).
struct StatusCard: View {
    @Environment(\.colorScheme) private var scheme
    let label: String
    let value: String
    let dot: DotState
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(RelayFont.label)
                .tracking(0.04 * 11)
                .foregroundStyle(Color(.textTertiary, scheme))
            HStack(spacing: 6) {
                StatusDot(dot)
                Text(value)
                    .font(RelayFont.cardValue)
                    .foregroundStyle(Color(.textPrimary, scheme))
            }
            Text(detail)
                .font(RelayFont.monoSmall)
                .foregroundStyle(Color(.textSecondary, scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .background(Color(.card, scheme))
        .clipShape(RoundedRectangle(cornerRadius: RelayRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.card)
                .strokeBorder(Color(.border, scheme), lineWidth: 1)
        )
    }
}

/// The design's green pill toggle (knob inset 2px). Used for the bot-listener switch.
struct RelayToggleStyle: ToggleStyle {
    @Environment(\.colorScheme) private var scheme
    var width: CGFloat = 34
    var height: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        let knob = height - 4
        return HStack {
            configuration.label
            Spacer(minLength: 8)
            RoundedRectangle(cornerRadius: height / 2)
                .fill(configuration.isOn ? Color(.success, scheme) : Color(.border, scheme))
                .frame(width: width, height: height)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .offset(x: configuration.isOn ? (width - height) / 2 : -(width - height) / 2)
                )
                .onTapGesture { configuration.isOn.toggle() }
                .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
        }
    }
}

/// A small outlined pill (design: "Approve in Telegram ↗", blue outline by default).
struct Pill: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var tint: PaletteToken = .telegramBlue

    var body: some View {
        Text(text)
            .font(RelayFont.monoSmall)
            .foregroundStyle(Color(tint, scheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(Color(tint, scheme), lineWidth: 1))
    }
}

/// Terminal typography: 12.5pt mono with the design's 1.7 line-height.
private struct TerminalTextModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(RelayFont.mono)
            .lineSpacing(12.5 * 0.7)   // 1.7 line-height ≈ 0.7× extra leading
    }
}

extension View {
    func terminalText() -> some View { modifier(TerminalTextModifier()) }
}

// MARK: - Previews

private struct ThemePreview: View {
    @Environment(\.colorScheme) private var scheme
    @State private var listening = true

    private let swatches: [(String, PaletteToken)] = [
        ("accent", .accent), ("telegram", .telegramBlue), ("claude", .claudeTerracotta),
        ("success", .success), ("destructive", .destructive), ("card", .card),
        ("field", .field), ("terminal", .terminalBackground),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ForEach(swatches, id: \.0) { name, token in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(token, scheme))
                            .frame(width: 44, height: 32)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(.border, scheme)))
                        Text(name).font(.system(size: 9)).foregroundStyle(Color(.textTertiary, scheme))
                    }
                }
            }

            HStack(spacing: 10) {
                StatusCard(label: "Telegram Bot", value: "Connected", dot: .connected, detail: "@relay_dev_bot")
                StatusCard(label: "Source Chat", value: "Allowed", dot: .allowed, detail: "Dewa · 7129•••842")
                StatusCard(label: "Claude Code", value: "Ready", dot: .ready, detail: "~/dev/payments-api")
            }

            HStack(spacing: 12) {
                Toggle("Bot listener", isOn: $listening).toggleStyle(RelayToggleStyle())
                Pill(text: "Approve in Telegram ↗")
            }

            Text("$ npm test\n PASS  src/auth.test.ts")
                .terminalText()
                .foregroundStyle(Color(.success, scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.terminalBackground, scheme))
                .clipShape(RoundedRectangle(cornerRadius: RelayRadius.card))
        }
        .padding(20)
        .frame(width: 560)
        .background(Color(.windowBackground, scheme))
    }
}

#Preview("Theme — Dark") { ThemePreview().preferredColorScheme(.dark) }
#Preview("Theme — Light") { ThemePreview().preferredColorScheme(.light) }
