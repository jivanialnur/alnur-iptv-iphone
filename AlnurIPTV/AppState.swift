import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var account: Account?
    @Published var info = AccountInfo()
    @Published var lists: [Kind: ListData] = [:] { didSet { recount() } }
    @Published var catCounts: [Kind: [String: Int]] = [:]
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
        if UITest.reset, let b = Bundle.main.bundleIdentifier {
            ud.removePersistentDomain(forName: b)
            try? FileManager.default.removeItem(at: listDir)
        }
        account = load("account")
        info = load("info") ?? AccountInfo()
        settings = load("settings") ?? AppSettings()
        accounts = load("accounts") ?? (account.map { [$0] } ?? [])
        migrateLegacyProfile()
        loadProfile()
    }

    // MARK: users (several accounts; favourites / history are kept per user)
    @Published var accounts: [Account] = []
    private var pk: String { account.map { $0.key + "|" } ?? "" }
    private static let profileKeys = ["favs", "playCount", "played", "positions", "durations", "cont", "recent"]

    /// data saved before users existed belongs to the first user
    private func migrateLegacyProfile() {
        guard account != nil else { return }
        for k in Self.profileKeys where ud.data(forKey: k) != nil && ud.data(forKey: pk + k) == nil {
            ud.set(ud.data(forKey: k), forKey: pk + k)
            ud.removeObject(forKey: k)
        }
    }

    private func loadProfile() {
        favs = load(pk + "favs") ?? []
        playCount = load(pk + "playCount") ?? [:]
        played = load(pk + "played") ?? [:]
        positions = load(pk + "positions") ?? [:]
        durations = load(pk + "durations") ?? [:]
        cont = load(pk + "cont") ?? []
        recent = load(pk + "recent") ?? []
    }

    private func psave<T: Encodable>(_ key: String, _ v: T) { save(pk + key, v) }

    private func rememberAccount(_ acc: Account) {
        if let i = accounts.firstIndex(where: { $0.key == acc.key }) { accounts[i] = acc } else { accounts.append(acc) }
        save("accounts", accounts)
    }

    /// Switch to another saved user.
    func switchTo(_ acc: Account) {
        guard acc.key != account?.key else { return }
        if player != nil { closePlayer() }
        dlog("switch user → \(acc.key)")
        account = acc
        save("account", acc)
        accountChecked = false
        info = AccountInfo()
        clearLists()
        loadProfile()
        show("👤 \(acc.title)")
        Task { await refreshAccount(); await ensure(.live) }
    }

    func removeAccount(_ acc: Account) {
        accounts.removeAll { $0.key == acc.key }
        save("accounts", accounts)
        for k in Self.profileKeys { ud.removeObject(forKey: acc.key + "|" + k) }
        if acc.key == account?.key {
            if let other = accounts.first { switchTo(other) } else { logout() }
        }
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
    var streamUA: String { account?.streamUA ?? STREAM_UAS[0] }

    /// Download a movie / episode (stops the player first: the server allows only one connection).
    func download(_ it: Item) {
        guard let acc = account else { return }
        if player != nil { closePlayer() }
        let ua = streamUA
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.show(Downloads.shared.start(it, acc: acc, ua: ua))
        }
    }

    func show(_ msg: String) {
        toast = msg
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if toast == msg { toast = nil } }
    }

    // MARK: login
    /// Login with an M3U link: Xtream get.php links become a normal Xtream login, others are read as a playlist.
    func loginM3U(_ link: String, name: String? = nil) async throws {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let x = M3U.xtreamParts(link) {
            do {
                dlog("m3u link is an Xtream account → Xtream login")
                try await login(url: x.base, user: x.user, pass: x.pass, name: name)
                return
            } catch XtreamError.auth { throw XtreamError.auth }
            catch { dlog("Xtream login from M3U link failed (\(error.localizedDescription)) – reading it as a playlist") }
        }
        let text = try await M3U.download(link)
        let lists = await Task.detached(priority: .userInitiated) { M3U.parse(text) }.value
        let nLive = lists[.live]?.items.count ?? 0, nMovie = lists[.movie]?.items.count ?? 0
        guard nLive + nMovie > 0 else { throw XtreamError.bad("The playlist has no channels") }
        dlog("m3u playlist: \(nLive) channels, \(nMovie) movies")
        let host = URL(string: link)?.host ?? "playlist"
        var acc = Account(url: link, username: "m3u-" + M3U.stableHash(link), password: "")
        acc.m3u = link
        acc.name = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? host
        let changed = account?.key != acc.key
        if changed { if player != nil { closePlayer() }; clearLists() }
        account = acc
        rememberAccount(acc)
        if changed { accountChecked = true; loadProfile() }
        storeM3U(lists)
        info = AccountInfo(status: "M3U playlist")
        offline = false
        save("account", acc); save("info", info)
    }

    private func storeM3U(_ l: [Kind: ListData]) {
        for (k, d) in l {
            lists[k] = d
            let file = listFile(k)
            Task.detached(priority: .background) { if let data = try? JSONEncoder().encode(d) { try? data.write(to: file, options: .atomic) } }
        }
    }

    func login(url: String, user: String, pass: String, name: String? = nil) async throws {
        var acc = Account(url: Xtream.normBase(url), username: user.trimmingCharacters(in: .whitespaces), password: pass)
        acc.name = name?.trimmingCharacters(in: .whitespaces)
        let r = try await Xtream.login(acc)
        acc.apiUA = r.ua
        dlog("login ok, api UA = \(r.ua)")
        let changed = account?.key != acc.key
        if changed { if player != nil { closePlayer() }; clearLists() }
        account = acc
        rememberAccount(acc)
        if changed { accountChecked = true; loadProfile() }
        dlog("accounts: \(accounts.count)")
        info = Xtream.accountInfo(r.info)
        offline = false
        save("account", acc); save("info", info)
        fixFormat()
    }

    /// At app start: lists are shown from disk at once; account is checked quietly.
    private var accountChecked = false
    /// Once per app start (the tab screen re-appears every time the player closes).
    func refreshAccount() async {
        guard !accountChecked, var acc = account else { return }
        accountChecked = true
        if acc.m3u != nil { offline = false; return }      // playlist: nothing to check
        do {
            let r = try await Xtream.login(acc)
            if acc.apiUA != r.ua { acc.apiUA = r.ua; account = acc; save("account", acc); rememberAccount(acc) }
            info = Xtream.accountInfo(r.info); save("info", info)
            offline = false
            fixFormat()
        } catch XtreamError.auth {
            show("Account login failed – check Settings")
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
        accountChecked = false
        if let a = account { accounts.removeAll { $0.key == a.key }; save("accounts", accounts) }
        if let other = accounts.first { account = nil; switchTo(other); return }
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
        a.streamUA = ua; account = a; save("account", a); rememberAccount(a)
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
        if let link = acc.m3u {
            // playlist: one download fills channels and movies
            do {
                let text = try await M3U.download(link)
                let l = await Task.detached(priority: .userInitiated) { M3U.parse(text) }.value
                guard account?.key == acc.key else { return }
                storeM3U(l)
                dlog("list \(kind.rawValue) (m3u): \(l[kind]?.items.count ?? 0) items")
            } catch {
                dlog("m3u reload failed: \(error.localizedDescription)")
                if !quiet || lists[kind] == nil { errors[kind] = error.localizedDescription }
            }
            return
        }
        do {
            let d = try await Xtream.fetchList(kind, acc: acc, ua: acc.apiUA ?? API_UAS[0])
            dlog("list \(kind.rawValue): \(d.items.count) items, \(d.cats.count) cats")
            guard account == acc || account?.url == acc.url else { return }
            let old = lists[kind]?.items.count ?? 0
            lists[kind] = d
            let file = listFile(kind)
            Task.detached(priority: .background) { if let data = try? JSONEncoder().encode(d) { try? data.write(to: file, options: .atomic) } }
            if quiet, old > 0, d.items.count > old { show("🆕 \(d.items.count - old) new \(kind.title.lowercased())") }
        } catch {
            dlog("list \(kind.rawValue) failed: \(error.localizedDescription)")
            if !quiet || lists[kind] == nil { errors[kind] = error.localizedDescription }
        }
    }

    private var countedAt: [Kind: Date] = [:]
    private func recount() {
        for (k, l) in lists where countedAt[k] != l.at {
            var c: [String: Int] = [:]
            for it in l.items { c[it.cat, default: 0] += 1 }
            countedAt[k] = l.at
            catCounts[k] = c
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
        if let i = favs.firstIndex(where: { $0.id == it.id }) { favs.remove(at: i); show("Removed from Favourites") }
        else { favs.insert(it, at: 0); show("Added to Favourites ★") }
        psave("favs", favs)
    }

    func recordPlay(_ it: Item) {
        playCount[it.id, default: 0] += 1
        played[it.id] = it
        recent.removeAll { $0.id == it.id }
        recent.insert(it, at: 0)
        if recent.count > 60 { recent.removeLast(recent.count - 60) }
        psave("playCount", playCount); psave("played", played); psave("recent", recent)
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
        psave("positions", positions); psave("durations", durations); psave("cont", cont)
    }

    func progress(_ it: Item) -> Double? {
        guard let p = positions[it.id], let d = durations[it.id], d > 0 else { return nil }
        return p / d
    }

    func removeCont(_ it: Item) {
        cont.removeAll { $0.id == it.id }; positions[it.id] = nil
        psave("cont", cont); psave("positions", positions)
    }
    func clearHistory() {
        cont = []; recent = []; positions = [:]; playCount = [:]; played = [:]
        psave("cont", cont); psave("recent", recent); psave("positions", positions); psave("playCount", playCount); psave("played", played)
    }

    // MARK: play
    // The tab screens are paused by iOS while the full-screen player covers them,
    // so the player is opened / closed here directly (not via a SwiftUI onChange).
    func play(_ queue: [Item], index: Int) {
        guard queue.indices.contains(index) else { return }
        let req = PlayRequest(queue: queue, index: index)
        player = req
        PlayerHost.present(AnyView(PlayerScreen(app: self, request: req).environmentObject(self)))
    }

    func closePlayer() {
        player = nil
        PlayerHost.dismissIfShown()
    }
}
