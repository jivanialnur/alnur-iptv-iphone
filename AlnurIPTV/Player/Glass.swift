import SwiftUI

/// iOS 26 "Liquid Glass" on iPhone 18 Pro; frosted blur on older iOS / older Xcode.
extension View {
    @ViewBuilder func glass<S: Shape>(_ shape: S, interactive: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if interactive { self.glassEffect(.regular.interactive(), in: shape) }
            else { self.glassEffect(.regular, in: shape) }
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}

/// Long press on a glass button shows what it does (set by the player).
private struct GlassHelpKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }
extension EnvironmentValues {
    var glassHelp: ((String) -> Void)? {
        get { self[GlassHelpKey.self] }
        set { self[GlassHelpKey.self] = newValue }
    }
}

/// Round glass icon button.
struct GlassIcon: View {
    @Environment(\.glassHelp) private var help
    let system: String
    var size: CGFloat = 44
    var font: Font = .system(size: 18, weight: .semibold)
    var tint: Color = .white
    var label: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(font)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(Circle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in if let label { help?(label) } })
        .accessibilityLabel(label ?? system)
    }
}

/// Glass capsule with icon + text (Rec, Link, TV Guide …).
struct GlassPill: View {
    @Environment(\.glassHelp) private var help
    let title: String
    let system: String
    var tint: Color = .white
    var showTitle = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: system).foregroundStyle(tint)
                if showTitle { Text(title).lineLimit(1) }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, showTitle ? 14 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(Capsule())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in help?(title) })
        .accessibilityLabel(title)
    }
}

/// Icon used as a Menu label, in glass.
struct GlassMenuLabel: View {
    let system: String
    var label: String? = nil
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: system)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glass(Circle())
    }
}
