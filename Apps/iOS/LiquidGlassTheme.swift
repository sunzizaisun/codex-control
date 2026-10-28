import SwiftUI
import CodexWatchCore

struct CodexBackdrop: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(AppPreferenceKeys.appearance) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        ZStack {
            backgroundColor
            Circle()
                .fill(Color.cyan.opacity(effectiveColorScheme == .dark ? 0.32 : 0.20))
                .frame(width: 330, height: 330)
                .blur(radius: 75)
                .offset(x: -150, y: -300)
            Circle()
                .fill(Color.purple.opacity(effectiveColorScheme == .dark ? 0.30 : 0.16))
                .frame(width: 360, height: 360)
                .blur(radius: 85)
                .offset(x: 170, y: 270)
        }
        .ignoresSafeArea()
    }

    private var backgroundColor: Color {
        effectiveColorScheme == .dark
            ? Color(red: 0.015, green: 0.02, blue: 0.09)
            : Color(red: 0.91, green: 0.96, blue: 1.0)
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
        if #available(iOS 26.0, *) {
            content
                .padding(18)
                .glassEffect(
                    .regular.tint(tint.opacity(0.10)),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous)
                )
        } else {
            content
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
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
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func codexGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
