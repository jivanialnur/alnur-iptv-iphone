import SwiftUI

struct CatRoute: Hashable {
    var kind: Kind
    var cat: String?
    var name: String
}

/// Live / Movies / Series home: big title, search, Most Watched + Suggestions, categories.
struct BrowseView: View {
    @EnvironmentObject var app: AppState
    let kind: Kind
    @State private var query = ""
    @State private var results: [Item] = []
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section(results.isEmpty ? "Kai malyu nahi" : "\(results.count >= 300 ? "300+" : String(results.count)) results") {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, it in
                            ItemLink(item: it, queue: results, index: i)
                        }
                    }
                } else {
                    homeSections
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(kind.title)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(kind.title.lowercased())")
            .refreshable { await app.ensure(kind, force: true) }
            .navigationDestination(for: CatRoute.self) { r in CategoryView(route: r) }
            .navigationDestination(for: Item.self) { it in DetailView(item: it) }
            .overlay { stateOverlay }
            .task {
                await app.ensure(kind)
                if let t = UITest.parse(UITest.open), t.0 == kind, let it = app.lists[kind]?.items.first(where: { $0.sid == t.1 }) { path.append(it) }
            }
            .task(id: query) { await search() }
        }
    }

    @ViewBuilder private var homeSections: some View {
        let list = app.lists[kind]
        if kind == .live {
            let most = app.mostWatched(.live)
            if !most.isEmpty {
                Section("Most Watched") {
                    ForEach(Array(most.enumerated()), id: \.element.id) { i, it in ItemLink(item: it, queue: most, index: i) }
                }
            }
            let favs = app.favs.filter { $0.kind == .live }
            let sugg = favs.isEmpty ? Array((list?.items ?? []).prefix(8)) : favs
            if !sugg.isEmpty {
                Section(favs.isEmpty ? "Suggestions" : "Favourites") {
                    ForEach(Array(sugg.enumerated()), id: \.element.id) { i, it in ItemLink(item: it, queue: sugg, index: i) }
                }
            }
        } else {
            let cont = app.cont.filter { kind == .movie ? $0.kind == .movie : $0.kind == .episode }
            if !cont.isEmpty {
                Section("Continue Watching") {
                    ForEach(cont.prefix(10)) { it in ItemLink(item: it, queue: [it], index: 0) }
                }
            }
            if let list {
                let newest = Array(list.items.sorted { $0.added > $1.added }.prefix(10))
                Section("Recently Added") {
                    ForEach(newest) { it in ItemLink(item: it, queue: newest, index: 0) }
                }
            }
        }
        if let list {
            Section("Categories") {
                NavigationLink(value: CatRoute(kind: kind, cat: nil, name: "All \(kind.title.lowercased())")) {
                    CatRow(name: "All", count: list.items.count)
                }
                ForEach(list.cats) { c in
                    NavigationLink(value: CatRoute(kind: kind, cat: c.id, name: c.name)) {
                        CatRow(name: c.name, count: nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var stateOverlay: some View {
        if app.lists[kind] == nil {
            if app.loading.contains(kind) {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("\(kind.title) download thay chhe…\n(pehli vaar thodi var lage)").multilineTextAlignment(.center).font(.footnote).foregroundStyle(.secondary)
                }
            } else if let e = app.errors[kind] {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(e).multilineTextAlignment(.center).font(.footnote)
                    Button("Fari try karo") { Task { await app.ensure(kind, force: true) } }.buttonStyle(.borderedProminent)
                }.padding()
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        let items = app.lists[kind]?.items ?? []
        let found = await Task.detached(priority: .userInitiated) { () -> [Item] in
            var out: [Item] = []
            let num = Int(q)
            for it in items {
                if it.name.localizedCaseInsensitiveContains(q) || (num != nil && it.num == num) {
                    out.append(it)
                    if out.count >= 300 { break }
                }
            }
            return out
        }.value
        if !Task.isCancelled { results = found }
    }
}

struct CatRow: View {
    let name: String
    let count: Int?
    var body: some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(.tint)
            Text(name).lineLimit(1)
            Spacer()
            if let count { Text("\(count)").foregroundStyle(.secondary).font(.footnote) }
        }
    }
}

struct CategoryView: View {
    @EnvironmentObject var app: AppState
    let route: CatRoute
    @State private var query = ""
    @State private var sortNew = false

    var body: some View {
        let all = app.items(route.kind, cat: route.cat)
        let q = query.trimmingCharacters(in: .whitespaces)
        var items = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        if sortNew { items.sort { $0.added > $1.added } }
        return List {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                ItemLink(item: it, queue: items, index: i)
            }
        }
        .listStyle(.plain)
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search in \(route.name)")
        .toolbar {
            if route.kind != .live {
                Button { sortNew.toggle() } label: { Image(systemName: sortNew ? "clock.fill" : "clock") }
            }
        }
        .overlay { if items.isEmpty { Text("Kai nathi").foregroundStyle(.secondary) } }
    }
}

/// One row: live → plays (queue = the list it is in), movie/series → detail page.
struct ItemLink: View {
    @EnvironmentObject var app: AppState
    let item: Item
    let queue: [Item]
    let index: Int

    var body: some View {
        Group {
            if item.kind == .live || item.kind == .episode {
                Button { app.play(queue, index: index) } label: { ItemRow(item: item) }
                    .buttonStyle(.plain)
            } else {
                NavigationLink(value: item) { ItemRow(item: item) }
            }
        }
        .swipeActions(edge: .trailing) {
            Button { app.toggleFav(item) } label: {
                Label(app.isFav(item) ? "Remove" : "Favourite", systemImage: app.isFav(item) ? "star.slash" : "star")
            }.tint(.yellow)
        }
        .contextMenu {
            Button { app.toggleFav(item) } label: {
                Label(app.isFav(item) ? "Favourites mathi kadho" : "Favourites ma umero", systemImage: "star")
            }
            if item.kind == .live || item.kind == .episode || item.kind == .movie {
                Button { app.play(queue, index: index) } label: { Label("Play", systemImage: "play.fill") }
            }
        }
    }
}

struct ItemRow: View {
    @EnvironmentObject var app: AppState
    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.logo, placeholder: item.kind == .live ? "tv" : "film", fill: item.kind != .live)
                .frame(width: item.kind == .live ? 54 : 44, height: item.kind == .live ? 40 : 62)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).font(.body).lineLimit(2)
                HStack(spacing: 6) {
                    if item.kind == .live, let n = item.num { Text("#\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    if let r = item.rating, !r.isEmpty, r != "0" { Text("★ \(r)").font(.caption).foregroundStyle(.orange) }
                }
                if let p = app.progress(item) {
                    ProgressView(value: p).tint(.red).frame(maxWidth: 160)
                }
            }
            Spacer(minLength: 0)
            if app.isFav(item) { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
