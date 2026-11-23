import Foundation

/// Hooks for the automatic simulator test on GitHub (launch arguments like `-uitest_play live:1001`).
/// Normal users never pass these, so they do nothing in daily use.
enum UITest {
    static let d = UserDefaults.standard
    static var login: String? { d.string(forKey: "uitest_login") }
    static var tab: String? { d.string(forKey: "uitest_tab") }
    static var play: String? { d.string(forKey: "uitest_play") }
    static var open: String? { d.string(forKey: "uitest_open") }
    static var nextAfter: Double { d.double(forKey: "uitest_next_after") }
    static var seekTo: Double { d.double(forKey: "uitest_seekto") }
    static var reset: Bool { d.bool(forKey: "uitest_reset") }

    /// "live:1001" -> (.live, 1001)
    static func parse(_ s: String?) -> (Kind, Int)? {
        guard let p = s?.split(separator: ":"), p.count == 2, let k = Kind(rawValue: String(p[0])), let id = Int(p[1]) else { return nil }
        return (k, id)
    }
}

func dlog(_ s: String) { NSLog("[IPTV] %@", s) }
