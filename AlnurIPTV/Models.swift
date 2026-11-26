import Foundation

enum Kind: String, Codable, CaseIterable {
    case live, movie, series, episode

    var title: String {
        switch self {
        case .live: return "Channels"
        case .movie: return "Movies"
        case .series: return "Series"
        case .episode: return "Episodes"
        }
    }
}

struct Item: Codable, Identifiable, Hashable {
    var kind: Kind
    var sid: Int
    var name: String
    var logo: String?
    var cat: String = ""
    var num: Int?
    var ext: String?
    var rating: String?
    var added: Int = 0
    var plot: String?
    var seriesId: Int?
    var seriesName: String?
    var season: String?
    var duration: Int?
    /// direct stream link (M3U playlists); Xtream items build their link from the account
    var url: String?

    var id: String { "\(kind.rawValue):\(sid)" }

    var displayName: String {
        if kind == .episode, let s = seriesName { return "\(s) · \(name)" }
        return name
    }
}

struct Category: Codable, Identifiable, Hashable {
    var id: String
    var name: String
}

struct ListData: Codable {
    var cats: [Category]
    var items: [Item]
    var at: Date
}

struct Account: Codable, Equatable {
    var url: String
    var username: String
    var password: String
    var apiUA: String?
    var streamUA: String?
    var name: String?
    /// set when this user is a plain M3U playlist (no Xtream API)
    var m3u: String?

    /// one user = one username on one server
    var key: String { "\(username)@\(URL(string: url)?.host ?? url)" }
    var title: String { (name?.isEmpty == false ? name! : username) }
}

struct AccountInfo: Codable, Equatable {
    var status: String = ""
    var expDate: Date?
    var maxConnections: String = ""
    var activeConnections: String = ""
    var formats: [String] = []
}

struct AppSettings: Codable, Equatable {
    var liveFormat: String = "ts"
    var caching: Int = 1500
    var autoNext: Bool = true
    /// sound: 100…200 % (boost with limiter) and auto-level (same loudness on every channel)
    var soundBoost: Int = 100
    var autoLevel: Bool = false
    /// look: "auto" / "light" / "dark" and the accent colour id (see AppTheme)
    var theme: String = "auto"
    var accent: String = "blue"

    init() {}
    // older saved settings have no sound keys – read what is there, default the rest
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        liveFormat = try c.decodeIfPresent(String.self, forKey: .liveFormat) ?? "ts"
        caching = try c.decodeIfPresent(Int.self, forKey: .caching) ?? 1500
        autoNext = try c.decodeIfPresent(Bool.self, forKey: .autoNext) ?? true
        soundBoost = try c.decodeIfPresent(Int.self, forKey: .soundBoost) ?? 100
        autoLevel = try c.decodeIfPresent(Bool.self, forKey: .autoLevel) ?? false
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "auto"
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? "blue"
    }
}

struct Season: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var episodes: [Item]
}

struct SeriesInfo {
    var plot: String?
    var genre: String?
    var cast: String?
    var rating: String?
    var cover: String?
    var release: String?
    var seasons: [Season]
}

struct MovieInfo {
    var plot: String?
    var genre: String?
    var cast: String?
    var director: String?
    var release: String?
    var duration: String?
    var cover: String?
    var rating: String?
}

struct PlayRequest: Identifiable {
    let id = UUID()
    var queue: [Item]
    var index: Int
}

// Xtream servers mix strings and numbers – read both.
func str(_ v: Any?) -> String? {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    default: return nil
    }
}

func int(_ v: Any?) -> Int? {
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String {
        if let i = Int(s) { return i }
        if let d = Double(s) { return Int(d) }
    }
    return nil
}

func fmtTime(_ secs: Double) -> String {
    guard secs.isFinite, secs >= 0 else { return "0:00" }
    let s = Int(secs)
    let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
}
