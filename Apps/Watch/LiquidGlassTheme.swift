import SwiftUI
import CodexWatchCore

struct WatchBackdrop: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(AppPreferenceKeys.appearance) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var colors: [Color] {
        if effectiveColorScheme == .light {
            return [
                Color(red: 0.88, green: 0.96, blue: 1.0),
                Color(red: 0.95, green: 0.91, blue: 1.0),
                Color(red: 0.97, green: 0.98, blue: 1.0),
            ]
        }
        return [
            Color(red: 0.015, green: 0.025, blue: 0.09),
            Color(red: 0.025, green: 0.015, blue: 0.07),
            .black,
        ]
    }

    private var effectiveColorScheme: ColorScheme {
        switch AppAppearance(rawValue: appearanceRaw) ?? .system {
        case .light: .light
        case .dark: .dark
        case .system: systemColorScheme
        }
    }
}

private struct WatchGlassCard: ViewModifier {
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(watchOS 26.0, *) {
            content
                .padding(10)
                .glassEffect(
                    .regular.tint(tint.opacity(0.12)),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        } else {
            content
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// Keeps every pushed screen transparent above the same adaptive backdrop.
/// Applying a background directly to List works on the dashboard but can be
/// ignored by a watchOS navigation destination, leaving a black sheet in
/// light mode.  Placing the backdrop behind the entire destination fixes that
/// behaviour for Settings, Chat, and task detail screens alike.
private struct WatchScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            WatchBackdrop()
            content
                .scrollContentBackground(.hidden)
        }
        .adaptiveWatchNavigationAppearance()
    }
}

extension View {
    func watchGlassCard(tint: Color = .cyan) -> some View {
        modifier(WatchGlassCard(tint: tint))
    }

    func watchScreenBackground() -> some View {
        modifier(WatchScreenBackground())
    }

    @ViewBuilder
    func watchPrimaryButton() -> some View {
        if #available(watchOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func watchGlassButton() -> some View {
        if #available(watchOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
