import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                DownloadsSection()
                if !app.cont.isEmpty {
                    Section("Continue Watching") {
                        ForEach(app.cont) { it in ItemLink(item: it, queue: [it], index: 0) }
                            .onDelete { idx in idx.map { app.cont[$0] }.forEach { app.removeCont($0) } }
                    }
                }
                ForEach([Kind.live, .movie, .series], id: \.self) { k in
                    let f = app.favs.filter { $0.kind == k }
                    if !f.isEmpty {
                        Section("Favourite \(k.title.lowercased())") {
                            ForEach(Array(f.enumerated()), id: \.element.id) { i, it in ItemLink(item: it, queue: f, index: i) }
                                .onDelete { idx in idx.map { f[$0] }.forEach { app.toggleFav($0) } }
                        }
                    }
                }
                if !app.recent.isEmpty {
                    Section("Recently Watched") {
                        ForEach(Array(app.recent.prefix(30).enumerated()), id: \.element.id) { _, it in
                            ItemLink(item: it, queue: [it], index: 0)
                        }
                    }
                    Section {
                        Button("History saaf karo", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .overlay {
                if app.cont.isEmpty && app.favs.isEmpty && app.recent.isEmpty && Downloads.shared.entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "star").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Haju kai nathi.\nChannel / movie par left swipe karine ★ favourite karo.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.footnote)
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Item.self) { it in DetailView(item: it) }
            .confirmationDialog("Continue watching, recently watched ane most watched saaf karvu?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Saaf karo", role: .destructive) { app.clearHistory() }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var confirmLogout = false
    @State private var addUser = false
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(app.accounts, id: \.key) { a in
                        Button {
                            app.switchTo(a)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill").font(.title2)
                                    .foregroundStyle(a.key == app.account?.key ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.title).foregroundStyle(.primary)
                                    Text("\(a.username) · \(URL(string: a.url)?.host ?? a.url)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if a.key == app.account?.key { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { app.removeAccount(a) } label: { Label("Kadho", systemImage: "trash") }
                        }
                    }
                    Button { addUser = true } label: { Label("Navo user umero", systemImage: "person.badge.plus") }
                } header: { Text("Users") } footer: {
                    Text("User par tap karo = e user par badlo. Dar user na favourites ane continue watching alag rahe chhe.")
                }

                if let a = app.account {
                    Section("Account") {
                        LabeledContent("Server", value: URL(string: a.url)?.host ?? a.url)
                        LabeledContent("Username", value: a.username)
                        LabeledContent("Status", value: app.offline ? "\(app.info.status) (offline)" : app.info.status)
                        if let e = app.info.expDate {
                            LabeledContent("Expiry", value: e.formatted(date: .abbreviated, time: .omitted))
                        }
                        if !app.info.maxConnections.isEmpty {
                            LabeledContent("Connections", value: "\(app.info.activeConnections) / \(app.info.maxConnections)")
                        }
                    }
                }
                Section {
                    Picker("Live format", selection: $app.settings.liveFormat) {
                        Text("TS (best)").tag("ts")
                        Text("HLS (m3u8)").tag("m3u8")
                    }
                    Picker("Buffer", selection: $app.settings.caching) {
                        Text("1 sec (fast zapping)").tag(1000)
                        Text("1.5 sec").tag(1500)
                        Text("3 sec").tag(3000)
                        Text("5 sec (slow internet)").tag(5000)
                    }
                    Toggle("Next episode automatic", isOn: $app.settings.autoNext)
                } header: { Text("Player") } footer: {
                    Text("Server ek j connection aape chhe – PC / tablet par chalu hoy to iPhone par stream nahi chale.")
                }
                .onChange(of: app.settings) { _ in app.saveSettings() }

                Section("Lists") {
                    ForEach([Kind.live, .movie, .series], id: \.self) { k in
                        LabeledContent(k.title, value: app.lists[k].map { "\($0.items.count)" } ?? "–")
                    }
                    Button {
                        refreshing = true
                        Task {
                            for k in [Kind.live, .movie, .series] { await app.ensure(k, force: true) }
                            refreshing = false
                            app.show("Lists update thai gayi ✅")
                        }
                    } label: {
                        HStack { Text("Badhi lists refresh karo"); Spacer(); if refreshing { ProgressView() } }
                    }
                    .disabled(refreshing)
                }

                Section {
                    Button("Logout", role: .destructive) { confirmLogout = true }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $addUser) { LoginView(addingUser: true).environmentObject(app) }
            .task { for k in [Kind.live, .movie, .series] { await app.ensure(k) } }
            .confirmationDialog("Logout karvu? Saved lists kadhi nakhashe (favourites rehse).", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Logout", role: .destructive) { app.logout() }
            }
        }
    }
}
