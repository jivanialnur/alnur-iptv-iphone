import Foundation

/// Login with an M3U link.
/// - An Xtream "get.php?username=…&password=…" link is turned into a normal Xtream login
///   (all features: movies / series info, catch-up, guide …).
/// - Any other playlist (.m3u / .m3u8) is downloaded and read: channels by group-title,
///   files (.mp4 / .mkv … or /movie/ /series/ links) go to Movies.
enum M3U {
    /// Xtream server + user + password hidden in a get.php link, if it is one.
    static func xtreamParts(_ link: String) -> (base: String, user: String, pass: String)? {
        guard let c = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.path.lowercased().hasSuffix("get.php"),
              let u = c.queryItems?.first(where: { $0.name == "username" })?.value, !u.isEmpty,
              let p = c.queryItems?.first(where: { $0.name == "password" })?.value, !p.isEmpty else { return nil }
        return (Xtream.normBase(link), u, p)
    }

    /// short stable id for one playlist (Swift's hashValue changes every app start)
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h % 1_000_000_000, radix: 36)
    }

    static func download(_ link: String) async throws -> String {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw XtreamError.bad("Invalid M3U link") }
        var last: Error = XtreamError.bad("No response")
        for (n, ua) in unique(STREAM_UAS.prefix(1).map { $0 } + API_UAS).enumerated() {
            if n > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
            var req = URLRequest(url: url)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 90
            do {
                let (data, resp) = try await Xtream.session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else { last = XtreamError.http(code); continue }
                let text = String(decoding: data, as: UTF8.self)
                guard text.contains("#EXTINF") || text.contains("#EXTM3U") else { last = XtreamError.bad("This link is not an M3U playlist"); continue }
                dlog("m3u downloaded \(data.count) bytes (UA \(ua.prefix(12)))")
                return text
            } catch { last = error }
        }
        throw last
    }

    /// value of key="…" inside an #EXTINF line
    private static func attr(_ line: Substring, _ key: String) -> String? {
        guard let r = line.range(of: key + "=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let e = rest.firstIndex(of: "\"") else { return nil }
        let v = String(rest[..<e]).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    static func parse(_ text: String) -> [Kind: ListData] {
        var live: [Item] = [], movies: [Item] = []
        var liveCats: [String] = [], movieCats: [String] = []
        var seenLive = Set<String>(), seenMovie = Set<String>()
        var info: Substring?
        var group: String?
        let fileExt: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "flv", "webm", "mpg", "mpeg"]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF") { info = Substring(line); continue }
            if line.hasPrefix("#EXTGRP:") { group = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces); continue }
            if line.hasPrefix("#") { continue }
            guard let u = URL(string: line), u.scheme != nil else { info = nil; continue }
            let inf = info ?? ""
            var name = inf.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if name.isEmpty { name = attr(inf, "tvg-name") ?? u.deletingPathExtension().lastPathComponent }
            let cat = attr(inf, "group-title") ?? group ?? "Other"
            let logo = attr(inf, "tvg-logo")
            let path = u.path.lowercased()
            let ext = u.pathExtension.lowercased()
            let isFile = fileExt.contains(ext) || path.contains("/movie/") || path.contains("/series/")
            var it = Item(kind: isFile ? .movie : .live, sid: 0, name: name, logo: logo, cat: cat)
            it.url = line
            if isFile {
                it.ext = ext.isEmpty ? "mp4" : ext
                it.sid = 1 + movies.count
                movies.append(it)
                if seenMovie.insert(cat).inserted { movieCats.append(cat) }
            } else {
                it.sid = 1 + live.count
                it.num = it.sid
                live.append(it)
                if seenLive.insert(cat).inserted { liveCats.append(cat) }
            }
            info = nil; group = nil
        }
        let now = Date()
        return [
            .live: ListData(cats: liveCats.map { Category(id: $0, name: $0) }, items: live, at: now),
            .movie: ListData(cats: movieCats.map { Category(id: $0, name: $0) }, items: movies, at: now),
            .series: ListData(cats: [], items: [], at: now),
        ]
    }
}
