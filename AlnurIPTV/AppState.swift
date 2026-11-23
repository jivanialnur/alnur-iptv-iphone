import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var account: Account?
    @Published var info = AccountInfo()
    @Published var lists: [Kind: ListData] = [:]
    @Published var loading: Set<Kind> = []
    @Published var errors: [Kind: String] = [:]
    @Published var favs: [Item] = []
    @Published var playCount: [String: Int] = [:]
    @Published var played: [String: Item] = [:]
    @Published var positions: [String: Double] = [:]
    @Published var durations: [String: Double] = [:]
    @Published var cont: [Item] = []
    @Published var recent: [Item] = []
    @Published var settings = AppSettings()
    @Published var player: PlayRequest?
    @Published var offline = false
    @Published var toast: String?

    private let ud = UserDefaults.standard
    static let listMaxAge: TimeInterval = 12 * 3600

    init() {
        account = load("account")
        info = load("info") ?? AccountInfo()
        settings = load("settings") ?? AppSettings()
        favs = load("favs") ?? []
        playCount = load("playCount") ?? [:]
        played = load("played") ?? [:]
        positions = load("positions") ?? [:]
        durations = load("durations") ?? [:]
        cont = load("cont") ?? []
        recent = load("recent") ?? []
    }

    // MARK: storage
    private func load<T: Decodable>(_ key: String) -> T? {
        guard let d = ud.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    private func save<T: Encodable>(_ key: String, _ v: T) {
        if let d = try? JSONEncoder().encode(v) { ud.set(d, forKey: key) }
    }
    private var listDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("lists", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func listFile(_ k: Kind) -> URL { listDir.appendingPathComponent("\(k.rawValue).json") }

    var apiUA: String { account?.apiUA ?? API_UAS[0] }

    func show(_ msg: String) {
        toast = msg
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if toast == msg { toast = nil } }
    }

    // MARK: login
    func login(url: String, user: String, pass: String) async throws {
        var acc = Account(url: Xtream.normBase(url), username: user.trimmingCharacters(in: .whitespaces), password: pass)
        let r = try await Xtream.login(acc)
        acc.apiUA = r.ua
        if account?.url != acc.url || account?.username != acc.username { clearLists() }
        account = acc
        info = Xtream.accountInfo(r.info)
        offline = false
        save("account", acc); save("info", info)
        fixFormat()
    }

    /// At app start: lists are shown from disk at once; account is checked quietly.
    func refreshAccount() async {
        guard var acc = account else { return }
        do {
            let r = try await Xtream.login(acc)
            if acc.apiUA != r.ua { acc.apiUA = r.ua; account = acc; save("account", acc) }
            info = Xtream.accountInfo(r.info); save("info", info)
            offline = false
            fixFormat()
        } catch XtreamError.auth {
            show("Account login nathi thatu – Settings ma check karo")
        } catch {
            offline = true
        }
    }

    private func fixFormat() {
        if !info.formats.isEmpty && !info.formats.contains(settings.liveFormat) {
            settings.liveFormat = info.formats.contains("ts") ? "ts" : info.formats[0]
            saveSettings()
        }
    }

    func logout() {
        account = nil
        ud.removeObject(forKey: "account")
        clearLists()
    }

    private func clearLists() {
        lists = [:]
        for k in [Kind.live, .movie, .series] { try? FileManager.default.removeItem(at: listFile(k)) }
    }

    func saveSettings() { save("settings", settings) }

    func setStreamUA(_ ua: String) {
        guard var a = account, a.streamUA != ua else { return }
        a.streamUA = ua; account = a; save("account", a)
    }

    // MARK: lists
    func ensure(_ kind: Kind, force: Bool = false) async {
        guard let acc = account else { return }
        if !force, lists[kind] != nil { return }
        if !force, lists[kind] == nil {
            let file = listFile(kind)
            let cached: ListData? = await Task.detached(priority: .userInitiated) { () -> ListData? in
                guard let d = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(ListData.self, from: d)
            }.value
            if let cached, !cached.items.isEmpty {
                lists[kind] = cached
                if Date().timeIntervalSince(cached.at) > Self.listMaxAge { Task { await self.fetch(kind, acc: acc, quiet: true) } }
                return
            }
        }
        await fetch(kind, acc: acc, quiet: false)
    }

    private func fetch(_ kind: Kind, acc: Account, quiet: Bool) async {
        if loading.contains(kind) { return }
        loading.insert(kind); errors[kind] = nil
        defer { loading.remove(kind) }
        do {
            let d = try await Xtream.fetchList(kind, acc: acc, ua: acc.apiUA ?? API_UAS[0])
            guard account == acc || account?.url == acc.url else { return }
            let old = lists[kind]?.items.count ?? 0
            lists[kind] = d
            let file = listFile(kind)
            Task.detached(priority: .background) { if let data = try? JSONEncoder().encode(d) { try? data.write(to: file, options: .atomic) } }
            if quiet, old > 0, d.items.count > old { show("🆕 \(d.items.count - old) navi \(kind.title.lowercased()) aavi") }
        } catch {
            if !quiet || lists[kind] == nil { errors[kind] = error.localizedDescription }
        }
    }

    func items(_ kind: Kind, cat: String?) -> [Item] {
        guard let l = lists[kind] else { return [] }
        guard let cat else { return l.items }
        return l.items.filter { $0.cat == cat }
    }

    func count(_ kind: Kind, cat: String) -> Int { lists[kind]?.items.reduce(0) { $0 + ($1.cat == cat ? 1 : 0) } ?? 0 }

    // MARK: favourites / history
    func isFav(_ it: Item) -> Bool { favs.contains { $0.id == it.id } }
    func toggleFav(_ it: Item) {
        if let i = favs.firstIndex(where: { $0.id == it.id }) { favs.remove(at: i); show("Favourites mathi kadhyu") }
        else { favs.insert(it, at: 0); show("Favourites ma umeryu ★") }
        save("favs", favs)
    }

    func recordPlay(_ it: Item) {
        playCount[it.id, default: 0] += 1
        played[it.id] = it
        recent.removeAll { $0.id == it.id }
        recent.insert(it, at: 0)
        if recent.count > 60 { recent.removeLast(recent.count - 60) }
        save("playCount", playCount); save("played", played); save("recent", recent)
    }

    func mostWatched(_ kind: Kind, limit: Int = 10) -> [Item] {
        played.values.filter { $0.kind == kind }
            .sorted { (playCount[$0.id] ?? 0) > (playCount[$1.id] ?? 0) }
            .prefix(limit).map { $0 }
    }

    func setPosition(_ it: Item, pos: Double, dur: Double) {
        guard it.kind == .movie || it.kind == .episode, dur > 0 else { return }
        durations[it.id] = dur
        if pos / dur > 0.95 || dur - pos < 60 {
            positions[it.id] = nil
            cont.removeAll { $0.id == it.id }
        } else if pos > 30 {
            positions[it.id] = pos
            cont.removeAll { $0.id == it.id }
            cont.insert(it, at: 0)
            if cont.count > 40 { cont.removeLast(cont.count - 40) }
        }
        save("positions", positions); save("durations", durations); save("cont", cont)
    }

    func progress(_ it: Item) -> Double? {
        guard let p = positions[it.id], let d = durations[it.id], d > 0 else { return nil }
        return p / d
    }

    func removeCont(_ it: Item) {
        cont.removeAll { $0.id == it.id }; positions[it.id] = nil
        save("cont", cont); save("positions", positions)
    }
    func clearHistory() {
        cont = []; recent = []; positions = [:]; playCount = [:]; played = [:]
        save("cont", cont); save("recent", recent); save("positions", positions); save("playCount", playCount); save("played", played)
    }

    // MARK: play
    func play(_ queue: [Item], index: Int) {
        guard queue.indices.contains(index) else { return }
        player = PlayRequest(queue: queue, index: index)
    }
}
