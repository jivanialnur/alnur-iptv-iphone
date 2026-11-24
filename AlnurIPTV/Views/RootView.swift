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
            if let snd = UserDefaults.standard.string(forKey: "uitest_sound") {
                // e.g. "180" – store like the user would in Settings
                app.settings.soundBoost = Int(snd.split(separator: ",").first ?? "100") ?? 100
                app.saveSettings()
            }
            if let u = UserDefaults.standard.string(forKey: "uitest_add_m3u") {
                let p = u.components(separatedBy: "|")
                let first = app.account
                do { try await app.loginM3U(p[1], name: p[0]) } catch { dlog("add m3u failed \(error.localizedDescription)") }
                dlog("users now: \(app.accounts.map { $0.title }) current=\(app.account?.title ?? "-") live=\(app.lists[.live]?.items.count ?? 0) movies=\(app.lists[.movie]?.items.count ?? 0) cats=\(app.lists[.live]?.cats.map { $0.name } ?? [])")
                if let it = app.lists[.live]?.items.first {
                    app.play(app.items(.live, cat: it.cat), index: 0)
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    app.closePlayer()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                if let f = first, p.count < 3 { app.switchTo(f); dlog("after switch: current=\(app.account?.title ?? "-")") }
                return
            }
            if let u = UserDefaults.standard.string(forKey: "uitest_add_user") {
                let p = u.components(separatedBy: "|")
                let first = app.account
                do { try await app.login(url: p[1], user: p[2], pass: p[3], name: p[0]) } catch { dlog("add user failed \(error.localizedDescription)") }
                dlog("users now: \(app.accounts.map { $0.title }) current=\(app.account?.title ?? "-")")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let f = first { app.switchTo(f) }
                dlog("after switch: current=\(app.account?.title ?? "-") favs=\(app.favs.count)")
                return
            }
            if let t = UITest.parse(UserDefaults.standard.string(forKey: "uitest_download")) {
                await app.ensure(t.0)
                if let it = app.lists[t.0]?.items.first(where: { $0.sid == t.1 }) {
                    let dl = Downloads.shared
                    if UserDefaults.standard.bool(forKey: "uitest_dl_fresh"), let e = dl.entry(for: it) { dlog("test: delete old download"); dl.cancel(e) }
                    if dl.localURL(for: it) != nil {
                        if UserDefaults.standard.bool(forKey: "uitest_photos"), let e = dl.entry(for: it) {
                            dlog("test: save to photos")
                            dl.saveToPhotos(e) { dlog("test: photos result: \($0)") }
                        } else { dlog("test: play downloaded"); app.play([it], index: 0) }
                    } else {
                        app.download(it)
                        let p = UserDefaults.standard.double(forKey: "uitest_dl_pause")
                        if p > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(p * 1e9))
                            if let e = dl.entry(for: it) { dlog("test: pause at \(e.received)"); dl.pause(e) }
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if let e = dl.entry(for: it) { dlog("test: still \(e.received) after 3 s paused, resume"); dl.resume(e) }
                        }
                    }
                }
                return
            }
            guard !UITest.autoplayDone, let t = UITest.parse(UITest.play) else { return }
            UITest.autoplayDone = true
            let (k, id) = t
            await app.ensure(k)
            guard let it = app.lists[k]?.items.first(where: { $0.sid == id }) else { dlog("autoplay: \(id) not found"); return }
            let q = app.items(k, cat: it.cat)
            dlog("autoplay \(it.name)")
            app.play(q, index: q.firstIndex(of: it) ?? 0)
            if UITest.closeAfter > 0 { Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(UITest.closeAfter * 1e9))
                dlog("test: close player")
                app.closePlayer()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let r = UITest.parse(UITest.reopen), let it2 = app.lists[r.0]?.items.first(where: { $0.sid == r.1 }) {
                    dlog("test: reopen \(it2.sid)")
                    let q2 = app.items(r.0, cat: it2.cat)
                    app.play(q2, index: q2.firstIndex(of: it2) ?? 0)
                }
            } }
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// true = opened from Settings → "+ Add user"
    var addingUser = false
    @State private var name = ""
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var useM3U = false
    @State private var m3u = ""
    @State private var busy = false
    @State private var msg: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "play.tv.fill").font(.system(size: 54)).foregroundStyle(.tint)
                        Text("Alnur IPTV").font(.title.bold())
                        Text(useM3U ? "Log in with an M3U playlist link" : "Log in with your Xtream Codes account").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .listRowBackground(Color.clear)

                Section {
                    Picker("Login type", selection: $useM3U) {
                        Text("Xtream Codes").tag(false)
                        Text("M3U link").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Name (e.g. Home, Brother) – optional", text: $name)
                    if useM3U {
                        TextField("M3U link (http://…)", text: $m3u, axis: .vertical)
                            .lineLimit(1...4)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextField("Server URL", text: $server)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Username", text: $user)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $pass)
                    }
                } header: { Text("Account") } footer: {
                    if useM3U {
                        Text("Paste the playlist link from your provider. An Xtream link (…/get.php?username=…&password=…) gives all features; other playlists give channels and movies.")
                    }
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
                    .disabled(busy || (useM3U ? m3u.trimmingCharacters(in: .whitespaces).isEmpty : (server.isEmpty || user.isEmpty || pass.isEmpty)))
                } footer: {
                    if let msg { Text(msg).foregroundStyle(.red) }
                }
            }
            .navigationTitle(addingUser ? "New user" : "Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if addingUser { Button("Cancel") { dismiss() } } }
        }
    }

    private func doLogin() async {
        busy = true; msg = nil
        do {
            if useM3U { try await app.loginM3U(m3u, name: name) }
            else { try await app.login(url: server, user: user, pass: pass, name: name) }
            if addingUser { dismiss() }
        }
        catch { msg = "Login failed: " + error.localizedDescription }
        busy = false
    }
}
