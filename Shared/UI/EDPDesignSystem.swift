import AppKit
import SwiftUI

enum EDPTheme {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 18
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 10
        static let row: CGFloat = 14
        static let card: CGFloat = 18
        static let floating: CGFloat = 22
    }

    enum Motion {
        static let hover = Animation.easeOut(duration: 0.12)
        static let navigation = Animation.snappy(duration: 0.22)
        static let layout = Animation.smooth(duration: 0.28)
        static let reduced = Animation.linear(duration: 0)
    }

    static let cardStroke = Color.primary.opacity(0.10)
    static let quietFill = Color.primary.opacity(0.045)
    static let selectedFill = Color.accentColor.opacity(0.14)
}

enum EDPStatusTone {
    case accent
    case success
    case warning
    case danger
    case neutral

    var color: Color {
        switch self {
        case .accent: .accentColor
        case .success: .green
        case .warning: .orange
        case .danger: .red
        case .neutral: .secondary
        }
    }
}

struct EDPWindowBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !reduceTransparency {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(contrast == .increased ? 0.06 : 0.035),
                        Color.clear,
                        Color.indigo.opacity(contrast == .increased ? 0.045 : 0.025)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct EDPContentCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = EDPTheme.Spacing.md, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: EDPTheme.Radius.card, style: .continuous)
                    .fill(reduceTransparency
                          ? Color(nsColor: .controlBackgroundColor)
                          : Color.primary.opacity(contrast == .increased ? 0.075 : 0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: EDPTheme.Radius.card, style: .continuous)
                    .stroke(
                        Color.primary.opacity(contrast == .increased ? 0.24 : 0.10),
                        lineWidth: contrast == .increased ? 1 : 0.5
                    )
            }
    }
}

struct EDPGlassToolbar<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        let toolbar = GlassEffectContainer(spacing: EDPTheme.Spacing.xs) {
            content
                .padding(.horizontal, EDPTheme.Spacing.sm)
                .padding(.vertical, EDPTheme.Spacing.xs)
        }

        if reduceTransparency {
            toolbar
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: EDPTheme.Radius.floating, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: EDPTheme.Radius.floating, style: .continuous)
                        .stroke(
                            Color.primary.opacity(contrast == .increased ? 0.24 : 0.10),
                            lineWidth: contrast == .increased ? 1 : 0.5
                        )
                }
        } else {
            toolbar
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: EDPTheme.Radius.floating))
        }
    }
}

struct EDPGlassCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if reduceTransparency {
            content
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: EDPTheme.Radius.floating, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: EDPTheme.Radius.floating, style: .continuous)
                        .stroke(
                            Color.primary.opacity(contrast == .increased ? 0.24 : 0.10),
                            lineWidth: contrast == .increased ? 1 : 0.5
                        )
                }
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: EDPTheme.Radius.floating))
        }
    }
}

struct EDPStatusPill: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let systemImage: String
    var tone: EDPStatusTone = .neutral

    @ViewBuilder
    var body: some View {
        let label = Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(
                tone.color.opacity(contrast == .increased ? 1 : (colorScheme == .dark ? 0.82 : 1))
            )
            .padding(.horizontal, 11)
            .padding(.vertical, 6)

        if reduceTransparency {
            label
                .background(
                    tone.color.opacity(
                        contrast == .increased ? (colorScheme == .dark ? 0.12 : 0.16) : (colorScheme == .dark ? 0.055 : 0.10)
                    ),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(
                            tone.color.opacity(contrast == .increased ? 0.55 : (colorScheme == .dark ? 0.22 : 0.28)),
                            lineWidth: contrast == .increased ? 1 : 0.5
                        )
                }
        } else {
            label
                .glassEffect(
                    .regular.tint(
                        tone.color.opacity(
                            contrast == .increased ? (colorScheme == .dark ? 0.08 : 0.12) : (colorScheme == .dark ? 0.035 : 0.075)
                        )
                    ),
                    in: .capsule
                )
                .overlay {
                    Capsule()
                        .stroke(
                            tone.color.opacity(contrast == .increased ? 0.50 : (colorScheme == .dark ? 0.18 : 0.22)),
                            lineWidth: contrast == .increased ? 1 : 0.5
                        )
                }
        }
    }
}

struct EDPSectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    private let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: EDPTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: EDPTheme.Spacing.sm)
            trailing
        }
    }
}

extension EDPSectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String) {
        self.init(title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

struct EDPNoticeBanner<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    var tone: EDPStatusTone = .accent
    private let actions: Actions

    init(
        title: String,
        message: String,
        systemImage: String,
        tone: EDPStatusTone = .accent,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tone = tone
        self.actions = actions()
    }

    var body: some View {
        EDPContentCard(padding: EDPTheme.Spacing.sm) {
            HStack(spacing: EDPTheme.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tone.color)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: EDPTheme.Spacing.sm)
                actions
            }
        }
    }
}

struct EDPEmptyState<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    private let actions: Actions

    init(
        _ title: String,
        message: String,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: EDPTheme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            VStack(spacing: EDPTheme.Spacing.xs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            actions
        }
        .padding(EDPTheme.Spacing.xl)
    }
}

extension EDPEmptyState where Actions == EmptyView {
    init(_ title: String, message: String, systemImage: String) {
        self.init(title, message: message, systemImage: systemImage) { EmptyView() }
    }
}

struct EDPMotionAwareModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Bool

    func body(content: Content) -> some View {
        content.animation(
            reduceMotion ? EDPTheme.Motion.reduced : EDPTheme.Motion.navigation,
            value: value
        )
    }
}

extension View {
    func edpMotionAware(value: Bool) -> some View {
        modifier(EDPMotionAwareModifier(value: value))
    }
}
