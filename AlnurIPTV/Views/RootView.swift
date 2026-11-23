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
        .task {
            if app.account == nil, let l = UITest.login {
                let p = l.components(separatedBy: "|")
                if p.count == 3 {
                    do { try await app.login(url: p[0], user: p[1], pass: p[2]) } catch { dlog("login failed: \(error.localizedDescription)") }
                }
            }
        }
        .onChange(of: app.player?.id) { _ in
            if let req = app.player {
                PlayerHost.present(AnyView(PlayerScreen(app: app, request: req).environmentObject(app)))
            } else {
                PlayerHost.dismissIfShown()
            }
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var app: AppState
    @State private var tab = UITest.tab ?? "live"

    var body: some View {
        TabView(selection: $tab) {
            BrowseView(kind: .live)
                .tabItem { Label("Live", systemImage: "tv") }.tag("live")
            BrowseView(kind: .movie)
                .tabItem { Label("Movies", systemImage: "film") }.tag("movie")
            BrowseView(kind: .series)
                .tabItem { Label("Series", systemImage: "play.rectangle.on.rectangle") }.tag("series")
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag("library")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
        }
        .task { await app.refreshAccount() }
        .task {
            guard let t = UITest.parse(UITest.play) else { return }
            let (k, id) = t
            await app.ensure(k)
            guard let it = app.lists[k]?.items.first(where: { $0.sid == id }) else { dlog("autoplay: \(id) not found"); return }
            let q = app.items(k, cat: it.cat)
            dlog("autoplay \(it.name)")
            app.play(q, index: q.firstIndex(of: it) ?? 0)
            if UITest.closeAfter > 0 {
                try? await Task.sleep(nanoseconds: UInt64(UITest.closeAfter * 1e9))
                dlog("test: close player")
                app.player = nil
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let r = UITest.parse(UITest.reopen), let it2 = app.lists[r.0]?.items.first(where: { $0.sid == r.1 }) {
                    dlog("test: reopen \(it2.sid)")
                    let q2 = app.items(r.0, cat: it2.cat)
                    app.play(q2, index: q2.firstIndex(of: it2) ?? 0)
                }
            }
        }
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
