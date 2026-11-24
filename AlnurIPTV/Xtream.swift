import Foundation

enum XtreamError: LocalizedError {
    case http(Int)
    case auth
    case bad(String)

    var errorDescription: String? {
        switch self {
        case .http(let c):
            if c == 503 || c == 429 { return "Server busy (HTTP \(c)). Try again in 2–3 minutes." }
            if c == 401 || c == 403 { return "Server refused (HTTP \(c))." }
            return "Server error HTTP \(c)"
        case .auth: return "Wrong username / password"
        case .bad(let m): return m
        }
    }
}

// The server only answers the API to MAG / Android-like players, and streams to VLC.
let API_UAS = [
    "Dalvik/2.1.0 (Linux; U; Android 13; SM-A736B Build/TP1A.220624.014)",
    "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3",
    "IPTVSmartersPro",
    "okhttp/4.12.0",
]
let STREAM_UAS = ["VLC/3.0.21 LibVLC/3.0.21", "VLC/3.0.20 LibVLC/3.0.20", "IPTVSmartersPro", "okhttp/4.12.0", "Lavf/60.16.100"]

func unique(_ a: [String?]) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for case let s? in a where !s.isEmpty && !seen.contains(s) { seen.insert(s); out.append(s) }
    return out
}

enum Xtream {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 300
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()

    static func normBase(_ s: String) -> String {
        var u = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        let low = u.lowercased()
        if !low.hasPrefix("http://") && !low.hasPrefix("https://") { u = "http://" + u }
        for marker in ["/player_api.php", "/get.php"] {
            if let r = u.range(of: marker, options: .caseInsensitive) { u = String(u[..<r.lowerBound]) }
        }
        return u
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    static func apiURL(_ a: Account, _ action: String? = nil, _ extra: String = "") -> URL? {
        var s = "\(a.url)/player_api.php?username=\(enc(a.username))&password=\(enc(a.password))"
        if let action { s += "&action=\(action)" }
        return URL(string: s + extra)
    }

    static func streamURL(_ it: Item, acc: Account, format: String) -> URL? {
        if let u = it.url { return URL(string: u) }
        let cred = "\(enc(acc.username))/\(enc(acc.password))"
        switch it.kind {
        case .live: return URL(string: "\(acc.url)/live/\(cred)/\(it.sid).\(format)")
        case .movie: return URL(string: "\(acc.url)/movie/\(cred)/\(it.sid).\(it.ext ?? "mp4")")
        case .episode: return URL(string: "\(acc.url)/series/\(cred)/\(it.sid).\(it.ext ?? "mp4")")
        case .series: return nil
        }
    }

    static func get(_ url: URL, ua: String) async throws -> Any {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw XtreamError.http(code) }
        if data.isEmpty { return [Any]() }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// GET JSON; waits and asks again when the server says "busy" (503 / 429).
    static func getJSON(_ url: URL, ua: String) async throws -> Any {
        var last: Error = XtreamError.bad("No response")
        for i in 0..<4 {
            do { return try await get(url, ua: ua) }
            catch XtreamError.http(let c) where c == 503 || c == 429 {
                last = XtreamError.http(c)
                try await Task.sleep(nanoseconds: UInt64(3_000_000_000) * UInt64(i + 1))
            }
        }
        throw last
    }

    /// Tries user-agents gently until the server answers. Returns the UA that worked + the account JSON.
    static func login(_ acc: Account) async throws -> (ua: String, info: [String: Any]) {
        guard let url = apiURL(acc) else { throw XtreamError.bad("Invalid server address") }
        let order = unique([acc.apiUA] + API_UAS)
        var last: Error = XtreamError.bad("No response")
        for (n, ua) in order.enumerated() {
            if n > 0 { try await Task.sleep(nanoseconds: 1_500_000_000) }
            do {
                let j = try await getJSON(url, ua: ua)
                if let d = j as? [String: Any], let ui = d["user_info"] as? [String: Any] {
                    guard str(ui["auth"]) == "1" else { throw XtreamError.auth }
                    return (ua, d)
                }
                last = XtreamError.bad("The server gave no valid answer (not an Xtream account?)")
            } catch XtreamError.auth {
                throw XtreamError.auth
            } catch {
                last = error
                if case XtreamError.http(let c) = error, c == 503, ua == acc.apiUA { break }
            }
        }
        throw last
    }

    static func accountInfo(_ d: [String: Any]) -> AccountInfo {
        let ui = d["user_info"] as? [String: Any] ?? [:]
        var a = AccountInfo()
        a.status = str(ui["status"]) ?? ""
        if let e = int(ui["exp_date"]), e > 0 { a.expDate = Date(timeIntervalSince1970: TimeInterval(e)) }
        a.maxConnections = str(ui["max_connections"]) ?? ""
        a.activeConnections = str(ui["active_cons"]) ?? ""
        a.formats = (ui["allowed_output_formats"] as? [Any] ?? []).compactMap { str($0) }
        return a
    }

    static func fetchList(_ kind: Kind, acc: Account, ua: String) async throws -> ListData {
        let actions: (String, String)
        switch kind {
        case .live: actions = ("get_live_categories", "get_live_streams")
        case .movie: actions = ("get_vod_categories", "get_vod_streams")
        default: actions = ("get_series_categories", "get_series")
        }
        let cj = try await getJSON(apiURL(acc, actions.0)!, ua: ua)
        let ij = try await getJSON(apiURL(acc, actions.1)!, ua: ua)
        let cats = (cj as? [[String: Any]] ?? []).map {
            Category(id: str($0["category_id"]) ?? "", name: str($0["category_name"]) ?? "")
        }
        let rows = ij as? [[String: Any]] ?? []
        var items: [Item] = []
        items.reserveCapacity(rows.count)
        for x in rows {
            let name = str(x["name"]) ?? ""
            let cat = str(x["category_id"]) ?? ""
            switch kind {
            case .live:
                guard let id = int(x["stream_id"]) else { continue }
                items.append(Item(kind: .live, sid: id, name: name, logo: str(x["stream_icon"]), cat: cat, num: int(x["num"])))
            case .movie:
                guard let id = int(x["stream_id"]) else { continue }
                items.append(Item(kind: .movie, sid: id, name: name, logo: str(x["stream_icon"]), cat: cat,
                                  ext: str(x["container_extension"]), rating: str(x["rating"]), added: int(x["added"]) ?? 0))
            default:
                guard let id = int(x["series_id"]) else { continue }
                items.append(Item(kind: .series, sid: id, name: name, logo: str(x["cover"]), cat: cat,
                                  rating: str(x["rating"]), added: int(x["last_modified"]) ?? 0, plot: str(x["plot"])))
            }
        }
        return ListData(cats: cats, items: items, at: Date())
    }

    static func seriesInfo(_ series: Item, acc: Account, ua: String) async throws -> SeriesInfo {
        let sid = series.seriesId ?? series.sid
        let j = try await getJSON(apiURL(acc, "get_series_info", "&series_id=\(sid)")!, ua: ua)
        let d = j as? [String: Any] ?? [:]
        let info = d["info"] as? [String: Any] ?? [:]
        let sname = str(info["name"]) ?? series.seriesName ?? series.name
        let cover = str(info["cover"]) ?? series.logo

        var raw: [(String, [[String: Any]])] = []
        if let eps = d["episodes"] as? [String: Any] {
            for (k, v) in eps { raw.append((k, v as? [[String: Any]] ?? [])) }
        } else if let eps = d["episodes"] as? [[Any]] {
            for (i, v) in eps.enumerated() {
                let arr = v.compactMap { $0 as? [String: Any] }
                raw.append((str(arr.first?["season"]) ?? String(i + 1), arr))
            }
        }
        raw.sort { (Int($0.0) ?? 0) < (Int($1.0) ?? 0) }

        let seasons: [Season] = raw.map { (s, arr) in
            let eps: [Item] = arr.compactMap { e in
                guard let id = int(e["id"]) else { return nil }
                let ei = e["info"] as? [String: Any] ?? [:]
                let num = int(e["episode_num"]) ?? 0
                let title = str(e["title"]) ?? ""
                return Item(kind: .episode, sid: id, name: "S\(s) E\(num)" + (title.isEmpty ? "" : " · \(title)"),
                            logo: str(ei["movie_image"]) ?? cover, ext: str(e["container_extension"]),
                            plot: str(ei["plot"]), seriesId: sid, seriesName: sname, season: s,
                            duration: int(ei["duration_secs"]))
            }
            return Season(name: s, episodes: eps)
        }
        return SeriesInfo(plot: str(info["plot"]), genre: str(info["genre"]), cast: str(info["cast"]),
                          rating: str(info["rating"]), cover: cover, release: str(info["releaseDate"]) ?? str(info["release_date"]),
                          seasons: seasons)
    }

    static func movieInfo(_ m: Item, acc: Account, ua: String) async throws -> MovieInfo {
        let j = try await getJSON(apiURL(acc, "get_vod_info", "&vod_id=\(m.sid)")!, ua: ua)
        let d = j as? [String: Any] ?? [:]
        let i = d["info"] as? [String: Any] ?? [:]
        return MovieInfo(plot: str(i["plot"]) ?? str(i["description"]), genre: str(i["genre"]), cast: str(i["cast"]) ?? str(i["actors"]),
                         director: str(i["director"]), release: str(i["releasedate"]) ?? str(i["release_date"]),
                         duration: str(i["duration"]), cover: str(i["movie_image"]) ?? m.logo, rating: str(i["rating"]))
    }

    struct EPGItem: Identifiable { let id = UUID(); let title: String; let desc: String; let start: Date?; let end: Date? }

    static func shortEPG(_ it: Item, acc: Account, ua: String) async throws -> [EPGItem] {
        let j = try await getJSON(apiURL(acc, "get_short_epg", "&stream_id=\(it.sid)&limit=8")!, ua: ua)
        let rows = (j as? [String: Any])?["epg_listings"] as? [[String: Any]] ?? []
        func dec(_ v: Any?) -> String {
            guard let s = str(v) else { return "" }
            if let d = Data(base64Encoded: s), let t = String(data: d, encoding: .utf8) { return t }
            return s
        }
        return rows.map { r in
            EPGItem(title: dec(r["title"]), desc: dec(r["description"]),
                    start: int(r["start_timestamp"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    end: int(r["stop_timestamp"]).map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }
}
