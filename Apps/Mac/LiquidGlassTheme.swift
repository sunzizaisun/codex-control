import SwiftUI
import CodexWatchCore

struct CodexBackdrop: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(AppPreferenceKeys.appearance) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        ZStack {
            backgroundColor
            Circle()
                .fill(Color.cyan.opacity(effectiveColorScheme == .dark ? 0.30 : 0.18))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: -165, y: -250)
            Circle()
                .fill(Color.purple.opacity(effectiveColorScheme == .dark ? 0.28 : 0.15))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: 170, y: 280)
        }
        .ignoresSafeArea()
    }

    private var backgroundColor: Color {
        effectiveColorScheme == .dark
            ? Color(red: 0.012, green: 0.018, blue: 0.075)
            : Color(red: 0.92, green: 0.96, blue: 1.0)
    }

    private var effectiveColorScheme: ColorScheme {
        switch AppAppearance(rawValue: appearanceRaw) ?? .system {
        case .light: .light
        case .dark: .dark
        case .system: systemColorScheme
        }
    }
}

private struct CodexGlassCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(16)
                .glassEffect(
                    .regular.tint(tint.opacity(0.10)),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
        } else {
            content
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.12)
                                : Color.black.opacity(0.08),
                            lineWidth: 1
                        )
                }
        }
    }
}

extension View {
    func codexGlassCard(tint: Color = .cyan) -> some View {
        modifier(CodexGlassCard(tint: tint))
    }

    @ViewBuilder
    func codexPrimaryButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func codexGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
