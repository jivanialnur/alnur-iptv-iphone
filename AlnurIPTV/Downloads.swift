import Foundation
import SwiftUI

/// Movie / episode downloads with an iOS background URLSession:
/// keeps going when the app is in the background or the phone is locked.
/// Files go to Documents/Downloads (also visible in the Files app → Alnur IPTV).
struct DownloadEntry: Codable, Identifiable, Equatable {
    enum State: String, Codable { case waiting, running, done, failed }
    var item: Item
    var state: State = .waiting
    var received: Int64 = 0
    var total: Int64 = 0
    var file: String?
    var error: String?
    var id: String { item.id }
    var progress: Double { total > 0 ? Double(received) / Double(total) : 0 }
}

final class Downloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Downloads()
    static let sessionID = "com.alnur.iptvplayer.downloads"
    var backgroundDone: (() -> Void)?

    @Published private(set) var entries: [DownloadEntry] = []
    private var taskToId: [Int: String] = [:]
    private var lastPublish = Date.distantPast

    /// fallback when the background transfer service refuses the request (seen in the simulator)
    private lazy var fgSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    private var fallbackTried = Set<String>()
    private var pending: [String: URLRequest] = [:]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: "downloads"), let e = try? JSONDecoder().decode([DownloadEntry].self, from: d) {
            entries = e.map { var x = $0; if x.state == .running || x.state == .waiting { x.state = .failed; x.error = "Interrupted – try again" }; return x }
        }
        // reconnect to transfers that kept running while the app was closed
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                for t in tasks {
                    guard let id = t.taskDescription else { continue }
                    self.taskToId[t.taskIdentifier] = id
                    self.update(id) { $0.state = .running; $0.error = nil }
                }
            }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: "downloads") }
    }

    private func update(_ id: String, _ f: (inout DownloadEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        f(&entries[i])
        save()
    }

    func entry(for it: Item) -> DownloadEntry? { entries.first { $0.id == it.id } }

    func localURL(for it: Item) -> URL? {
        guard let e = entry(for: it), e.state == .done, let f = e.file else { return nil }
        let u = Self.dir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Starts (or restarts) a download. Returns a short message for the user.
    @discardableResult
    func start(_ it: Item, acc: Account, ua: String) -> String {
        guard it.kind == .movie || it.kind == .episode else { return "Live channels cannot be downloaded" }
        if let e = entry(for: it) {
            if e.state == .running || e.state == .waiting { return "Already downloading" }
            if e.state == .done, localURL(for: it) != nil { return "Already downloaded" }
        }
        guard let url = Xtream.streamURL(it, acc: acc, format: "ts") else { return "No link" }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        pending[it.id] = req
        fallbackTried.remove(it.id)
        let task = session.downloadTask(with: req)
        task.taskDescription = it.id
        entries.removeAll { $0.id == it.id }
        entries.insert(DownloadEntry(item: it, state: .running), at: 0)
        taskToId[task.taskIdentifier] = it.id
        save()
        task.resume()
        dlog("download start \(it.kind.rawValue) \(it.sid)")
        return "⬇ Download started – see Library → Downloads"
    }

    func cancel(_ e: DownloadEntry) {
        session.getAllTasks { tasks in tasks.filter { $0.taskDescription == e.id }.forEach { $0.cancel() } }
        if let f = e.file { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(f)) }
        entries.removeAll { $0.id == e.id }
        save()
    }

    // MARK: URLSession delegate (background queue)
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        DispatchQueue.main.async {
            // publishing on every chunk would flood SwiftUI – twice a second is enough
            guard Date().timeIntervalSince(self.lastPublish) > 0.5 || totalBytesWritten == totalBytesExpectedToWrite else { return }
            self.lastPublish = Date()
            self.update(id) { $0.received = totalBytesWritten; $0.total = max(totalBytesExpectedToWrite, 0); $0.state = .running }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            DispatchQueue.main.async {
                self.update(id) {
                    $0.state = .failed
                    $0.error = code == 401 ? "Server busy (1 connection) – close the player / PC / tablet and try again" : "Server error HTTP \(code)"
                }
                dlog("download failed \(id) HTTP \(code)")
            }
            return
        }
        // the temp file disappears when this method returns: move it now (on this queue)
        let item = entries.first { $0.id == id }?.item
        let safe = (item?.displayName ?? id).components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let name = "\(safe).\(item?.ext ?? "mp4")"
        let dest = Self.dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            DispatchQueue.main.async {
                self.update(id) { $0.state = .done; $0.file = name; $0.received = size; $0.total = size; $0.error = nil }
                dlog("download done \(id) bytes=\(size)")
            }
        } catch {
            DispatchQueue.main.async { self.update(id) { $0.state = .failed; $0.error = error.localizedDescription } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        DispatchQueue.main.async {
            // background service failed before any data: try once more with a normal download
            if session !== self.fgSession, !self.fallbackTried.contains(id), let req = self.pending[id],
               (self.entries.first { $0.id == id }?.received ?? 0) == 0 {
                self.fallbackTried.insert(id)
                dlog("download background failed (\(error.localizedDescription)) – retry normal \(id)")
                let t = self.fgSession.downloadTask(with: req)
                t.taskDescription = id
                t.resume()
                return
            }
            self.update(id) { if $0.state != .done { $0.state = .failed; $0.error = error.localizedDescription } }
            dlog("download error \(id) \(error.localizedDescription)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.backgroundDone?(); self.backgroundDone = nil }
    }
}

/// Library section: progress, play offline, swipe to delete.
struct DownloadsSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dl = Downloads.shared

    var body: some View {
        if !dl.entries.isEmpty {
            Section("Downloads") {
                ForEach(dl.entries) { e in
                    Button {
                        if e.state == .done { app.play([e.item], index: 0) }
                        else if e.state == .failed, let acc = app.account { app.show(dl.start(e.item, acc: acc, ua: app.streamUA)) }
                    } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: e.item.logo, placeholder: "film", fill: true)
                                .frame(width: 44, height: 62)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.item.displayName).lineLimit(2)
                                switch e.state {
                                case .done:
                                    Text("✅ Downloaded · " + ByteCountFormatter.string(fromByteCount: e.total, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                case .running, .waiting:
                                    ProgressView(value: e.progress).tint(.blue)
                                    Text(e.total > 0 ? "\(Int(e.progress * 100))% · " + ByteCountFormatter.string(fromByteCount: e.received, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: e.total, countStyle: .file) : "Starting…")
                                        .font(.caption).foregroundStyle(.secondary)
                                case .failed:
                                    Text("⚠️ " + (e.error ?? "Download failed") + " · tap to retry").font(.caption).foregroundStyle(.red)
                                }
                            }
                            Spacer(minLength: 0)
                            if e.state == .done { Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { dl.cancel(e) } label: { Label(e.state == .done ? "Delete" : "Cancel", systemImage: "trash") }
                    }
                }
            }
        }
    }
}
