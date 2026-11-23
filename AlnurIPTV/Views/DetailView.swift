import SwiftUI

struct DetailView: View {
    let item: Item
    var body: some View {
        if item.kind == .series { SeriesDetail(series: item) } else { MovieDetail(movie: item) }
    }
}

struct Header: View {
    let cover: String?
    let title: String
    let chips: [String]
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(url: cover, placeholder: "film", fill: true)
                .frame(width: 110, height: 160)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.bold()).lineLimit(4)
                ForEach(chips.filter { !$0.isEmpty }, id: \.self) { c in
                    Text(c).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct MovieDetail: View {
    @EnvironmentObject var app: AppState
    let movie: Item
    @State private var info: MovieInfo?

    var body: some View {
        List {
            Section {
                Header(cover: info?.cover ?? movie.logo, title: movie.name,
                       chips: [info?.release ?? "", info?.genre ?? "", info?.duration ?? "",
                               (info?.rating ?? movie.rating).map { $0.isEmpty || $0 == "0" ? "" : "★ \($0)" } ?? ""])
                let pos = app.positions[movie.id]
                Button {
                    app.play([movie], index: 0)
                } label: {
                    Label(pos != nil ? "Resume (\(fmtTime(pos ?? 0)))" : "Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity).bold()
                }
                .buttonStyle(.borderedProminent)
                .listRowSeparator(.hidden)
                if pos != nil {
                    Button {
                        app.removeCont(movie)
                        app.play([movie], index: 0)
                    } label: { Label("Play from start", systemImage: "backward.end.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .listRowSeparator(.hidden)
                }
                DownloadButton(item: movie)
                    .listRowSeparator(.hidden)
                Button { app.toggleFav(movie) } label: {
                    Label(app.isFav(movie) ? "Remove from Favourites" : "Add to Favourites", systemImage: app.isFav(movie) ? "star.fill" : "star")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if let p = info?.plot, !p.isEmpty { Section("Story") { Text(p).font(.callout) } }
            if let c = info?.cast, !c.isEmpty { Section("Cast") { Text(c).font(.callout) } }
            if let d = info?.director, !d.isEmpty { Section("Director") { Text(d).font(.callout) } }
        }
        .navigationTitle(movie.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard info == nil, let acc = app.account else { return }
            info = try? await Xtream.movieInfo(movie, acc: acc, ua: app.apiUA)
        }
    }
}

struct SeriesDetail: View {
    @EnvironmentObject var app: AppState
    let series: Item
    @State private var info: SeriesInfo?
    @State private var season: String = ""
    @State private var error: String?

    var allEpisodes: [Item] { info?.seasons.flatMap { $0.episodes } ?? [] }

    var body: some View {
        List {
            Section {
                Header(cover: info?.cover ?? series.logo, title: series.name,
                       chips: [info?.release ?? "", info?.genre ?? "",
                               info.map { "\($0.seasons.count) season(s)" } ?? "",
                               (info?.rating ?? series.rating).map { $0.isEmpty || $0 == "0" ? "" : "★ \($0)" } ?? ""])
                if let next = nextUp {
                    Button {
                        let all = allEpisodes
                        app.play(all, index: all.firstIndex(of: next) ?? 0)
                    } label: {
                        Label(app.positions[next.id] != nil ? "Resume \(next.name)" : "Play \(next.name)", systemImage: "play.fill")
                            .lineLimit(1).frame(maxWidth: .infinity).bold()
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowSeparator(.hidden)
                }
                Button { app.toggleFav(series) } label: {
                    Label(app.isFav(series) ? "Remove from Favourites" : "Add to Favourites", systemImage: app.isFav(series) ? "star.fill" : "star")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if let p = info?.plot ?? series.plot, !p.isEmpty { Section("Story") { Text(p).font(.callout).lineLimit(8) } }

            if let info {
                if info.seasons.count > 1 {
                    Picker("Season", selection: $season) {
                        ForEach(info.seasons) { s in Text("Season \(s.name)").tag(s.name) }
                    }
                }
                let eps = info.seasons.first { $0.name == season }?.episodes ?? []
                Section("Episodes") {
                    ForEach(eps) { ep in
                      HStack(spacing: 8) {
                        Button {
                            let all = allEpisodes
                            app.play(all, index: all.firstIndex(of: ep) ?? 0)
                        } label: {
                            HStack(spacing: 12) {
                                RemoteImage(url: ep.logo, placeholder: "play.rectangle", fill: true)
                                    .frame(width: 96, height: 54)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ep.name).lineLimit(2)
                                    if let d = ep.duration, d > 0 { Text(fmtTime(Double(d))).font(.caption).foregroundStyle(.secondary) }
                                    if let p = app.progress(ep) { ProgressView(value: p).tint(.red) }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        EpisodeDownloadIcon(item: ep)
                      }
                        .swipeActions { Button { app.download(ep) } label: { Label("Download", systemImage: "arrow.down.circle") }.tint(.blue) }
                        .contextMenu { Button { app.download(ep) } label: { Label("Download", systemImage: "arrow.down.circle") } }
                    }
                }
            } else if let error {
                Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await load() } } }
            } else {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
        }
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if info == nil { await load() } }
    }

    /// First episode with a resume point, else the one after the last finished, else the first.
    private var nextUp: Item? {
        let all = allEpisodes
        if let r = all.first(where: { app.positions[$0.id] != nil }) { return r }
        if let lastSeen = all.lastIndex(where: { app.played[$0.id] != nil }), lastSeen + 1 < all.count { return all[lastSeen + 1] }
        return all.first
    }

    private func load() async {
        guard let acc = app.account else { return }
        error = nil
        do {
            var i = try await Xtream.seriesInfo(series, acc: acc, ua: app.apiUA)
            i.seasons = i.seasons.filter { !$0.episodes.isEmpty }
            info = i
            season = nextUp?.season ?? i.seasons.first?.name ?? ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Download / progress / downloaded state for a movie.
struct DownloadButton: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dl = Downloads.shared
    let item: Item

    var body: some View {
        let e = dl.entry(for: item)
        Button {
            if e?.state != .running { app.download(item) }
        } label: {
            Group {
                switch e?.state {
                case .running?, .waiting?: Label("Downloading… \(Int((e?.progress ?? 0) * 100))%", systemImage: "arrow.down.circle")
                case .done?: Label("Downloaded (offline)", systemImage: "checkmark.circle.fill")
                case .failed?: Label("Retry download", systemImage: "arrow.clockwise.circle")
                default: Label("Download", systemImage: "arrow.down.circle")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(e?.state == .done)
    }
}

/// Small download button on each episode row: ⬇ / % while loading / ✓ when on the iPhone.
struct EpisodeDownloadIcon: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dl = Downloads.shared
    let item: Item

    var body: some View {
        let e = dl.entry(for: item)
        Button {
            if e?.state != .running && e?.state != .done { app.download(item) }
        } label: {
            Group {
                switch e?.state {
                case .running?, .waiting?:
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                        Circle().trim(from: 0, to: e?.progress ?? 0).stroke(Color.accentColor, lineWidth: 3).rotationEffect(.degrees(-90))
                    }
                    .frame(width: 24, height: 24)
                case .done?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed?: Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange)
                default: Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor)
                }
            }
            .font(.title2)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Download")
    }
}
