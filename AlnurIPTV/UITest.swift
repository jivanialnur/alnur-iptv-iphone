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
    static var autoplayDone = false
    static var openDone = false
    static var search: String? { d.string(forKey: "uitest_search") }
    static var reset: Bool { d.bool(forKey: "uitest_reset") }
    static var closeAfter: Double { d.double(forKey: "uitest_close_after") }
    static var reopen: String? { d.string(forKey: "uitest_reopen") }

    /// "live:1001" -> (.live, 1001)
    static func parse(_ s: String?) -> (Kind, Int)? {
        guard let p = s?.split(separator: ":"), p.count == 2, let k = Kind(rawValue: String(p[0])), let id = Int(p[1]) else { return nil }
        return (k, id)
    }
}

enum TestLog {
    static var enabled = false
    static let q = DispatchQueue(label: "alnur.log")
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("iptv.log")
    static func write(_ s: String) {
        let line = String(format: "%.3f ", Date().timeIntervalSince1970) + s + "\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.data(using: .utf8)!.write(to: url) }
        }
    }
}

func dlog(_ s: String) {
    NSLog("[IPTV] %@", s)
    if TestLog.enabled { TestLog.write("[IPTV] " + s) }
}

/// Logs when the main thread is blocked (= app frozen) for more than 1 s.
enum HangWatch {
    static func start() {
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let sem = DispatchSemaphore(value: 0)
                let t0 = Date()
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 1.0) == .timedOut {
                    sem.wait()
                    dlog(String(format: "MAIN HANG %.1f s", Date().timeIntervalSince(t0)))
                }
            }
        }
    }
}
