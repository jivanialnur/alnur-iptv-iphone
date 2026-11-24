import Foundation
import SwiftUI
import Photos
import VLCKit

/// Movie / episode downloads.
/// - While the app is open: a normal download into a .part file (fastest – iOS's background service is often throttled).
/// - When the app goes to the background: the rest moves to iOS's background service (Range from the .part size)
///   and keeps going with the phone locked; back in the app it continues the fast way again.
/// - Pause / resume (continues from the bytes already on the phone), speed in MB/s.
/// Files go to Documents/Downloads (also visible in the Files app → Alnur IPTV) and can be saved to Photos.
struct DownloadEntry: Codable, Identifiable, Equatable {
    enum State: String, Codable { case waiting, running, paused, done, failed }
    var item: Item
    var state: State = .waiting
    var received: Int64 = 0
    var total: Int64 = 0
    var file: String?
    var error: String?
    var url: String?
    var ua: String?
    var speed: Double?            // bytes per second (only while running)
    var inPhotos: Bool?
    var id: String { item.id }
    var progress: Double { total > 0 ? Double(received) / Double(total) : 0 }
}

final class Downloads: NSObject, ObservableObject, URLSessionDataDelegate, URLSessionDownloadDelegate {
    static let shared = Downloads()
    static let sessionID = "com.alnur.iptvplayer.downloads"
    var backgroundDone: (() -> Void)?

    @Published private(set) var entries: [DownloadEntry] = []
    @Published var photoBusy: String?          // id being saved to Photos
    @Published var photoProgress: Double = 0

    // main thread
    private var tasks: [String: URLSessionTask] = [:]
    private var bgIds = Set<String>()
    private var lastPublish: [String: Date] = [:]
    private var speedMark: [String: (Date, Int64)] = [:]
    private var fallbackTried = Set<String>()
    // delegate queue only
    private var handles: [Int: FileHandle] = [:]
    private var written: [Int: Int64] = [:]
    private var expected: [Int: Int64] = [:]
    private var lastSent: [Int: Date] = [:]

    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.name = "downloads"; return q }()

    /// app open: plain HTTP with a Range header, written straight into a .part file – fastest,
    /// and pause / resume always continues from the bytes already on the phone
    private lazy var fgSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 24 * 3600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }()

    /// app in the background / closed: iOS's background service downloads the rest (Range from the .part size)
    private lazy var bgSession: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }()

    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var partDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("parts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func partFile(_ id: String) -> URL {
        partDir.appendingPathComponent(id.replacingOccurrences(of: ":", with: "_") + ".part")
    }
    static func partSize(_ id: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: partFile(id).path)[.size] as? Int64) ?? 0
    }

    override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: "downloads"), let e = try? JSONDecoder().decode([DownloadEntry].self, from: d) {
            // anything that was running when the app was killed: paused (resume continues from the .part file)
            entries = e.map {
                var x = $0; x.speed = nil
                if x.state == .running || x.state == .waiting { x.state = .paused; x.received = Self.partSize(x.id) }
                return x
            }
        }
        // transfers that kept running in the background while the app was closed
        bgSession.getAllTasks { tasks in
            DispatchQueue.main.async {
                for t in tasks {
                    guard let id = t.taskDescription else { continue }
                    self.tasks[id] = t
                    self.bgIds.insert(id)
                    self.update(id) { $0.state = .running; $0.error = nil }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.moveRunningToBackground()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.moveBackToForeground()
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

    private func request(for e: DownloadEntry, from offset: Int64) -> URLRequest? {
        guard let s = e.url, let u = URL(string: s) else { return nil }
        var req = URLRequest(url: u)
        req.setValue(e.ua ?? STREAM_UAS[0], forHTTPHeaderField: "User-Agent")
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        return req
    }

    /// Starts (or resumes / restarts) a download. Returns a short message for the user.
    @discardableResult
    func start(_ it: Item, acc: Account, ua: String) -> String {
        guard it.kind == .movie || it.kind == .episode else { return "Live channels cannot be downloaded" }
        if let e = entry(for: it) {
            if e.state == .running || e.state == .waiting { return "Already downloading" }
            if e.state == .paused || e.state == .failed, Self.partSize(e.id) > 0 { resume(e); return "⬇ Download continues" }
            if e.state == .done, localURL(for: it) != nil { return "Already downloaded" }
        }
        guard let url = Xtream.streamURL(it, acc: acc, format: "ts") else { return "No link" }
        entries.removeAll { $0.id == it.id }
        var e = DownloadEntry(item: it, state: .running)
        e.url = url.absoluteString
        e.ua = ua
        entries.insert(e, at: 0)
        save()
        fallbackTried.remove(it.id)
        try? FileManager.default.removeItem(at: Self.partFile(it.id))
        launch(e)
        return "⬇ Download started – see Library → Downloads"
    }

    private func launch(_ e: DownloadEntry, background: Bool? = nil) {
        let bg = background ?? (UIApplication.shared.applicationState == .background)
        let offset = Self.partSize(e.id)
        guard let req = request(for: e, from: offset) else { update(e.id) { $0.state = .failed; $0.error = "No link" }; return }
        let task: URLSessionTask = bg ? bgSession.downloadTask(with: req) : fgSession.dataTask(with: req)
        task.taskDescription = e.id
        tasks[e.id] = task
        if bg { bgIds.insert(e.id) } else { bgIds.remove(e.id) }
        speedMark[e.id] = nil
        update(e.id) { $0.received = offset; $0.state = .running; $0.error = nil }
        task.resume()
        dlog("download \(offset > 0 ? "resume" : "start") \(e.id) (\(bg ? "background" : "normal")) from \(offset)")
    }

    func pause(_ e: DownloadEntry) {
        let t = tasks[e.id]
        tasks[e.id] = nil
        bgIds.remove(e.id)
        t?.cancel()
        // the .part file holds everything received so far
        queue.addOperation {
            let size = Self.partSize(e.id)
            DispatchQueue.main.async {
                self.update(e.id) { $0.state = .paused; $0.speed = nil; $0.received = max($0.received, size) }
                dlog("download paused \(e.id) at \(size) bytes")
            }
        }
        update(e.id) { $0.state = .paused; $0.speed = nil }
    }

    func resume(_ e: DownloadEntry) {
        guard tasks[e.id] == nil else { return }
        // let the cancelled task finish writing first (same queue)
        queue.addOperation { DispatchQueue.main.async { self.launch(self.entries.first { $0.id == e.id } ?? e) } }
    }

    func cancel(_ e: DownloadEntry) {
        tasks[e.id]?.cancel()
        tasks[e.id] = nil
        queue.addOperation { try? FileManager.default.removeItem(at: Self.partFile(e.id)) }
        if let f = e.file { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(f)) }
        entries.removeAll { $0.id == e.id }
        save()
    }

    /// Leaving the app: hand running downloads to the background service (continues from the same byte).
    private func moveRunningToBackground() {
        let running = entries.filter { $0.state == .running && !bgIds.contains($0.id) && tasks[$0.id] != nil }
        guard !running.isEmpty else { return }
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bgTask) }
        for e in running { tasks[e.id]?.cancel(); tasks[e.id] = nil }
        queue.addOperation {
            DispatchQueue.main.async {
                for e in running { self.launch(self.entries.first { $0.id == e.id } ?? e, background: true) }
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }
    }

    /// Back in the app: background transfers are often slow – continue them in the fast normal way.
    private func moveBackToForeground() {
        let ids = bgIds.filter { id in entries.first { $0.id == id }?.state == .running }
        guard !ids.isEmpty else { return }
        dlog("download back to normal session: \(ids)")
        for id in ids {
            // a background task delivers its bytes only at the end, so the .part file is as it was: start from there
            tasks[id]?.cancel(); tasks[id] = nil
            bgIds.remove(id)
            if let e = entries.first(where: { $0.id == id }) { launch(e, background: false) }
        }
    }

    // MARK: normal (data) transfers – delegate queue
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let id = dataTask.taskDescription, let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        let code = http.statusCode
        guard code == 200 || code == 206 else {
            DispatchQueue.main.async {
                guard self.tasks[id] === dataTask else { return }
                self.tasks[id] = nil
                self.update(id) {
                    $0.state = .failed; $0.speed = nil
                    $0.error = code == 401 ? "Server busy (1 connection) – close the player / PC / tablet and try again" : "Server error HTTP \(code)"
                }
                dlog("download failed \(id) HTTP \(code)")
            }
            completionHandler(.cancel); return
        }
        let part = Self.partFile(id)
        if code == 200 || !FileManager.default.fileExists(atPath: part.path) {
            // server ignored the Range: start the file again
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: part) else { completionHandler(.cancel); return }
        let offset = (try? h.seekToEnd()).map { Int64($0) } ?? 0
        handles[dataTask.taskIdentifier] = h
        written[dataTask.taskIdentifier] = offset
        var total = http.expectedContentLength > 0 ? offset + http.expectedContentLength : 0
        if let cr = http.value(forHTTPHeaderField: "Content-Range"), let t = cr.split(separator: "/").last, let n = Int64(t) { total = n }
        expected[dataTask.taskIdentifier] = total
        DispatchQueue.main.async {
            self.update(id) { $0.total = max(total, $0.total); $0.received = offset }
            dlog("download \(id) HTTP \(code) offset \(offset) total \(total)")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = dataTask.taskDescription, let h = handles[dataTask.taskIdentifier] else { return }
        do { try h.write(contentsOf: data) } catch { dataTask.cancel(); return }
        let w = (written[dataTask.taskIdentifier] ?? 0) + Int64(data.count)
        written[dataTask.taskIdentifier] = w
        let now = Date()
        if now.timeIntervalSince(lastSent[dataTask.taskIdentifier] ?? .distantPast) >= 0.25 {
            lastSent[dataTask.taskIdentifier] = now
            progress(id, task: dataTask, bytes: w, total: expected[dataTask.taskIdentifier] ?? 0)
        }
    }

    private func progress(_ id: String, task: URLSessionTask, bytes: Int64, total: Int64) {
        DispatchQueue.main.async {
            guard self.tasks[id] === task else { return }
            let now = Date()
            var speed = self.entries.first { $0.id == id }?.speed ?? 0
            if let (t0, b0) = self.speedMark[id] {
                let dt = now.timeIntervalSince(t0)
                if dt >= 1 {
                    let s = Double(max(bytes - b0, 0)) / dt
                    speed = speed == 0 ? s : speed * 0.6 + s * 0.4
                    self.speedMark[id] = (now, bytes)
                }
            } else { self.speedMark[id] = (now, bytes) }
            // publishing on every chunk would flood SwiftUI – twice a second is enough
            let last = self.lastPublish[id] ?? .distantPast
            guard now.timeIntervalSince(last) > 0.5 else { return }
            if now.timeIntervalSince(last) > 5 {
                dlog(String(format: "download progress %@ %lld bytes %.2f MB/s", id, bytes, speed / 1_048_576))
            }
            self.lastPublish[id] = now
            self.update(id) {
                guard $0.state == .running else { return }
                $0.received = bytes
                $0.total = max(total, $0.total)
                $0.speed = speed > 0 ? speed : nil
            }
        }
    }

    // MARK: background transfers – delegate queue
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let base = Self.partSize(id)
        progress(id, task: downloadTask, bytes: base + totalBytesWritten, total: totalBytesExpectedToWrite > 0 ? base + totalBytesExpectedToWrite : 0)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard code == 200 || code == 206 else {
            DispatchQueue.main.async {
                self.tasks[id] = nil
                self.update(id) { $0.state = .failed; $0.speed = nil; $0.error = "Server error HTTP \(code)" }
                dlog("download failed \(id) HTTP \(code) (background)")
            }
            return
        }
        // the temp file disappears when this method returns: add it to the .part file now
        let part = Self.partFile(id)
        if code == 200 || !FileManager.default.fileExists(atPath: part.path) {
            try? FileManager.default.removeItem(at: part)
            try? FileManager.default.moveItem(at: location, to: part)
        } else if let out = try? FileHandle(forWritingTo: part), let inp = try? FileHandle(forReadingFrom: location) {
            _ = try? out.seekToEnd()
            while let chunk = try? inp.read(upToCount: 4 << 20), !chunk.isEmpty { try? out.write(contentsOf: chunk) }
            try? out.close(); try? inp.close()
        }
        finish(id)
    }

    /// whole file is in the .part: move it to Downloads with a nice name
    private func finish(_ id: String) {
        let item = DispatchQueue.main.sync { entries.first { $0.id == id }?.item }
        let safe = (item?.displayName ?? id).components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let name = "\(safe).\(item?.ext ?? "mp4")"
        let dest = Self.dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: Self.partFile(id), to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            DispatchQueue.main.async {
                self.tasks[id] = nil
                self.bgIds.remove(id)
                self.update(id) { $0.state = .done; $0.file = name; $0.received = size; $0.total = size; $0.error = nil; $0.speed = nil }
                dlog("download done \(id) bytes=\(size)")
            }
        } catch {
            DispatchQueue.main.async { self.update(id) { $0.state = .failed; $0.error = error.localizedDescription; $0.speed = nil } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        let tid = task.taskIdentifier
        let isData = task is URLSessionDataTask
        if isData {
            try? handles[tid]?.synchronize()
            try? handles[tid]?.close()
            handles[tid] = nil
        }
        lastSent[tid] = nil
        let got = written.removeValue(forKey: tid) ?? 0
        let total = expected.removeValue(forKey: tid) ?? 0
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }   // pause / moved / deleted
            DispatchQueue.main.async {
                guard self.tasks[id] === task else { return }
                self.tasks[id] = nil
                // background service failed (it always does in the simulator): continue the normal way
                if session === self.bgSession, !self.fallbackTried.contains(id), let e = self.entries.first(where: { $0.id == id }) {
                    self.fallbackTried.insert(id)
                    dlog("download background failed (\(error.localizedDescription)) – continue normal \(id)")
                    self.launch(e, background: false)
                    return
                }
                self.update(id) { if $0.state != .done { $0.state = .failed; $0.speed = nil; $0.error = error.localizedDescription + " – tap to continue" } }
                dlog("download error \(id) \(error.localizedDescription) at \(Self.partSize(id))")
            }
            return
        }
        guard isData else { return }   // background: handled in didFinishDownloadingTo
        if total > 0 && got < total {
            DispatchQueue.main.async {
                guard self.tasks[id] === task else { return }
                self.tasks[id] = nil
                self.update(id) { $0.state = .failed; $0.speed = nil; $0.error = "Connection ended early – tap to continue" }
                dlog("download short \(id) \(got)/\(total)")
            }
            return
        }
        let current = DispatchQueue.main.sync { self.tasks[id] === task }
        if current { finish(id) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.backgroundDone?(); self.backgroundDone = nil }
    }

    // MARK: Save to Photos
    /// Photos only takes MP4 / MOV. Other files (MKV, TS) are first re-packed into MP4 with VLC
    /// (picture and sound copied as they are, no quality loss), then saved.
    func saveToPhotos(_ e: DownloadEntry, done: @escaping (String) -> Void) {
        guard let f = e.file, photoBusy == nil else { return }
        let src = Self.dir.appendingPathComponent(f)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    dlog("photos: no permission (\(status.rawValue))")
                    done("Allow Photos access: iPhone Settings → Alnur IPTV → Photos"); return
                }
                let ext = src.pathExtension.lowercased()
                if ["mp4", "m4v", "mov"].contains(ext), UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(src.path) {
                    self.addToPhotos(src, id: e.id, temp: false, done: done)
                    return
                }
                self.photoBusy = e.id; self.photoProgress = 0
                let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                dlog("photos: remux \(f) → mp4")
                Remuxer.shared.remux(src, to: out, progress: { self.photoProgress = $0 }) { ok in
                    let compatible = ok && UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(out.path)
                    dlog("photos: remux ok=\(ok) compatible=\(compatible)")
                    if compatible {
                        self.addToPhotos(out, id: e.id, temp: true, done: done)
                    } else {
                        try? FileManager.default.removeItem(at: out)
                        self.photoBusy = nil
                        done("This video's format cannot go into Photos (e.g. AC3 sound). It stays here and in the Files app.")
                    }
                }
            }
        }
    }

    private func addToPhotos(_ file: URL, id: String, temp: Bool, done: @escaping (String) -> Void) {
        photoBusy = id
        PHPhotoLibrary.shared().performChanges({
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
        }) { ok, err in
            DispatchQueue.main.async {
                if temp { try? FileManager.default.removeItem(at: file) }
                self.photoBusy = nil
                if ok { self.update(id) { $0.inPhotos = true } }
                dlog("photos saved=\(ok) \(err?.localizedDescription ?? "")")
                done(ok ? "✅ Saved to Photos" : "Could not save to Photos: \(err?.localizedDescription ?? "unknown error")")
            }
        }
    }
}

/// Re-packs a video file into MP4 with VLC's stream output (copies picture and sound, no re-encoding).
final class Remuxer: NSObject {
    static let shared = Remuxer()
    private var player: VLCMediaPlayer?
    private var timer: Timer?

    func remux(_ src: URL, to out: URL, progress: @escaping (Double) -> Void, done: @escaping (Bool) -> Void) {
        guard let media = VLCMedia(url: src) else { done(false); return }
        media.addOption(":sout=#std{access=file,mux=mp4,dst=\"\(out.path)\"}")
        media.addOption(":sout-keep")
        media.addOption(":no-sout-spu")
        let p = VLCMediaPlayer()
        p.media = media
        player = p
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { p.play() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self, let p = self.player else { t.invalidate(); return }
            progress(Double(min(max(p.position, 0), 1)))
            let age = Date().timeIntervalSince(started)
            let ended = p.state == .stopped && age > 2
            if ended || p.state == .error || age > 1800 {
                t.invalidate()
                self.player = nil
                let state = p.state
                DispatchQueue.global().async { p.stop() }
                let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
                dlog("remux finished state=\(state.rawValue) bytes=\(size)")
                done(size > 0 && state != .error)
            }
        }
    }
}

/// Library section: progress, speed, pause / resume, play offline, save to Photos, swipe to delete.
struct DownloadsSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dl = Downloads.shared

    private func mb(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    var body: some View {
        if !dl.entries.isEmpty {
            Section("Downloads") {
                ForEach(dl.entries) { e in
                    HStack(spacing: 12) {
                        Button {
                            switch e.state {
                            case .done: app.play([e.item], index: 0)
                            case .failed: retry(e)
                            default: break
                            }
                        } label: {
                            HStack(spacing: 12) {
                                RemoteImage(url: e.item.logo, placeholder: "film", fill: true)
                                    .frame(width: 44, height: 62)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(e.item.displayName).lineLimit(2).foregroundStyle(.primary)
                                    status(e)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        Spacer(minLength: 0)
                        actionButton(e)
                    }
                    .swipeActions {
                        Button(role: .destructive) { dl.cancel(e) } label: { Label(e.state == .done ? "Delete" : "Cancel", systemImage: "trash") }
                    }
                }
            }
        }
    }

    private func retry(_ e: DownloadEntry) {
        if let acc = app.account { app.show(dl.start(e.item, acc: acc, ua: app.streamUA)) }
    }

    @ViewBuilder private func status(_ e: DownloadEntry) -> some View {
        switch e.state {
        case .done:
            if dl.photoBusy == e.id {
                ProgressView(value: dl.photoProgress).tint(.green)
                Text("Saving to Photos…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("✅ Downloaded · " + mb(e.total) + (e.inPhotos == true ? " · in Photos" : "")).font(.caption).foregroundStyle(.secondary)
            }
        case .running, .waiting:
            ProgressView(value: e.progress).tint(.blue)
            Text(e.total > 0
                 ? "\(Int(e.progress * 100))% · \(mb(e.received)) / \(mb(e.total))" + ((e.speed ?? 0) > 0 ? String(format: " · %.1f MB/s", (e.speed ?? 0) / 1_048_576) : "")
                 : "Starting…")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        case .paused:
            ProgressView(value: e.progress).tint(.gray)
            Text("⏸ Paused · \(Int(e.progress * 100))% · \(mb(e.received))" + (e.total > 0 ? " / \(mb(e.total))" : ""))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        case .failed:
            Text("⚠️ " + (e.error ?? "Download failed") + " · tap to retry").font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder private func actionButton(_ e: DownloadEntry) -> some View {
        Group {
            switch e.state {
            case .running, .waiting:
                Button { dl.pause(e) } label: { Image(systemName: "pause.circle.fill") }
            case .paused:
                Button { dl.resume(e) } label: { Image(systemName: "play.circle.fill") }
            case .failed:
                Button { retry(e) } label: { Image(systemName: "arrow.clockwise.circle.fill") }
            case .done:
                Menu {
                    Button { app.play([e.item], index: 0) } label: { Label("Play", systemImage: "play.fill") }
                    Button { dl.saveToPhotos(e) { app.show($0) } } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                    Button(role: .destructive) { dl.cancel(e) } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle.fill") }
            }
        }
        .font(.title)
        .foregroundStyle(Color.accentColor)
        .buttonStyle(.borderless)
        .frame(width: 44, height: 44)
    }
}
