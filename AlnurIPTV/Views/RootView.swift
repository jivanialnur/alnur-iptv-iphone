import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if app.account == nil {
                LoginView()
            } else {
                MainTabs()
            }
        }
        .overlay(alignment: .bottom) {
            if let t = app.toast {
                Text(t)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThickMaterial, in: Capsule())
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: app.toast)
        .fullScreenCover(item: $app.player) { req in
            PlayerScreen(app: app, request: req).environmentObject(app)
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TabView {
            BrowseView(kind: .live)
                .tabItem { Label("Live", systemImage: "tv") }
            BrowseView(kind: .movie)
                .tabItem { Label("Movies", systemImage: "film") }
            BrowseView(kind: .series)
                .tabItem { Label("Series", systemImage: "play.rectangle.on.rectangle") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task { await app.refreshAccount() }
    }
}

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var msg: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "play.tv.fill").font(.system(size: 54)).foregroundStyle(.tint)
                        Text("Alnur IPTV").font(.title.bold())
                        Text("Xtream Codes account thi login karo").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .listRowBackground(Color.clear)

                Section("Account") {
                    TextField("Server URL", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $pass)
                }

                Section {
                    Button {
                        Task { await doLogin() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "Connecting…" : "Login").bold()
                            Spacer()
                        }
                    }
                    .disabled(busy || server.isEmpty || user.isEmpty || pass.isEmpty)
                } footer: {
                    if let msg { Text(msg).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Login")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func doLogin() async {
        busy = true; msg = nil
        do { try await app.login(url: server, user: user, pass: pass) }
        catch { msg = "Login failed: " + error.localizedDescription }
        busy = false
    }
}
