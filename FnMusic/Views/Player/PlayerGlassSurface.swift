import SwiftUI

enum PlayerBarMetrics {
    static let maximumWidth: CGFloat = 700
    static let height: CGFloat = 54
    static let horizontalMargin: CGFloat = 16
    static let bottomMargin: CGFloat = 18
    static let contentClearance: CGFloat = 88
    static let playbackControlsWidth: CGFloat = 140
    static let accessoryControlsWidth: CGFloat = 124

    static func width(in availableWidth: CGFloat) -> CGFloat {
        max(0, min(maximumWidth, availableWidth - horizontalMargin * 2))
    }
}

/// Publishes actual capsule geometry for native layout regression checks.
/// SwiftUI does not evaluate this preference when no ancestor consumes it.
struct PlayerCapsuleBoundsKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

enum PlayerGlassRendering: Sendable {
    case automatic, opaque
}

private struct PlayerGlassRenderingKey: EnvironmentKey {
    static let defaultValue: PlayerGlassRendering = .automatic
}

extension EnvironmentValues {
    /// A local presentation policy for previews/high-contrast embeddings. This
    /// can only strengthen opacity; it never disables the system's accessibility setting.
    var playerGlassRendering: PlayerGlassRendering {
        get { self[PlayerGlassRenderingKey.self] }
        set { self[PlayerGlassRenderingKey.self] = newValue }
    }
}

/// Native Liquid Glass on macOS 26+, not a tinted rectangle pretending to be glass.
/// Older supported systems retain a material fallback and accessibility settings
/// always take precedence over translucency or motion.
struct PlayerGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerGlassRendering) private var rendering

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || rendering == .opaque {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(!reduceMotion), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10), .black.opacity(0.10)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
                }
        }
    }
}
