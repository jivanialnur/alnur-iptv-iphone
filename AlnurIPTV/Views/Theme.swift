import SwiftUI
import UIKit

/// Look of the browsing screens (his wish 2026-11-26): soft coloured background behind
/// Liquid Glass rows, a glass search bar, and Light / Dark / Auto + accent colour in Settings.
enum AppTheme {
    static let accents: [(id: String, name: String, color: Color)] = [
        ("blue", "Blue", .blue), ("indigo", "Indigo", .indigo), ("purple", "Purple", .purple),
        ("pink", "Pink", .pink), ("red", "Red", .red), ("orange", "Orange", .orange),
        ("green", "Green", .green), ("teal", "Teal", .teal),
    ]
    static func accent(_ id: String) -> Color { accents.first { $0.id == id }?.color ?? .blue }

    static func style(_ mode: String) -> UIUserInterfaceStyle {
        switch mode { case "light": return .light; case "dark": return .dark; default: return .unspecified }
    }

    /// whole app incl. the UIKit player window / alerts follows the chosen mode and colour
    @MainActor static func apply(_ s: AppSettings) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows {
                w.overrideUserInterfaceStyle = style(s.theme)
                w.tintColor = UIColor(accent(s.accent))
            }
        }
        dlog("theme \(s.theme) accent \(s.accent)")
    }
}

/// Soft coloured blobs behind the glass (drawn once, does not move).
struct AppBackground: View {
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let a = AppTheme.accent(app.settings.accent)
        let dark = scheme == .dark
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                (dark ? Color(red: 0.04, green: 0.05, blue: 0.08) : Color(red: 0.94, green: 0.95, blue: 0.98))
                Circle().fill(a.opacity(dark ? 0.55 : 0.35))
                    .frame(width: w * 1.1).position(x: w * 0.1, y: h * 0.12)
                Circle().fill((dark ? Color.purple : Color.cyan).opacity(dark ? 0.35 : 0.28))
                    .frame(width: w * 0.95).position(x: w * 0.95, y: h * 0.45)
                Circle().fill((dark ? Color.teal : Color.pink).opacity(dark ? 0.28 : 0.22))
                    .frame(width: w * 1.0).position(x: w * 0.2, y: h * 0.88)
            }
            .blur(radius: 70)
            .drawingGroup()
        }
        .ignoresSafeArea()
    }
}

/// Row background: frosted glass that lets the colours through.
struct GlassRow: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
            .overlay(Rectangle().fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.35)))
    }
}

extension View {
    /// list on the coloured background, rows made of glass
    func glassList() -> some View {
        self.scrollContentBackground(.hidden)
            .background(AppBackground())
    }
    func glassRows() -> some View { self.listRowBackground(GlassRow()) }
}

/// Search bar made of Liquid Glass (pinned under the big title).
struct GlassSearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            if focused {
                Button("Cancel") { text = ""; focused = false }
                    .buttonStyle(.plain).foregroundStyle(.tint)
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .glass(Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .animation(.snappy, value: focused)
    }
}

/// Settings → Appearance
struct AppearanceSection: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Section {
            Picker("Theme", selection: Binding(get: { app.settings.theme }, set: { app.settings.theme = $0; app.saveSettings(); AppTheme.apply(app.settings) })) {
                Text("Auto").tag("auto")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 10) {
                Text("Accent colour")
                HStack(spacing: 0) {
                    ForEach(AppTheme.accents, id: \.id) { a in
                        Button {
                            app.settings.accent = a.id; app.saveSettings(); AppTheme.apply(app.settings)
                        } label: {
                            ZStack {
                                Circle().fill(a.color).frame(width: 30, height: 30)
                                if app.settings.accent == a.id {
                                    Circle().strokeBorder(.primary, lineWidth: 2.5).frame(width: 38, height: 38)
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(a.name)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: { Text("Appearance") }
        .glassRows()
    }
}
