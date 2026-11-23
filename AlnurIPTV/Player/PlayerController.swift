import Foundation
import UIKit
import VLCKit

/// VLC based player: plays raw MPEG-TS live, AC3, interlaced etc.
/// The server allows one connection – old stream is stopped and we wait a moment before opening the next.
struct Track: Identifiable, Hashable {
    var id: String
    var name: String
}

@MainActor
final class PlayerController: NSObject, ObservableObject {
    let player = VLCMediaPlayer()
    unowned let app: AppState

    @Published var queue: [Item]
    @Published var index: Int
    @Published var status: String? = "Opening…"
    @Published var error: String?
    @Published var isPlaying = false
    @Published var timeMs = 0
    @Published var lengthMs = 0
    @Published var nextIn: Int?
    @Published var finished = false

    private var timer: Timer?
    private var token = 0
    private var attempt = 0
    private var uaIdx = 0
    private var gotVideo = false
    private var openedAt = Date()
    private var lastSave = Date()
    private var retrying = false
    private var countdownTask: Task<Void, Never>?
    private var suspended = false
    private var resumeAfterBackground: Double?
    private var observers: [NSObjectProtocol] = []

    // Picture in Picture (VLCKit 4)
    private var pip: VLCPictureInPictureWindowControlling?
    @Published var pipAvailable = false
    @Published var pipActive = false
    private var pipRequested = false

    /// libVLC stop/play can block (network, decoder threads). Never do them on the main thread.
    nonisolated static let vlcQueue = DispatchQueue(label: "alnur.vlc", qos: .userInitiated)
    private func vlc(_ block: @escaping (VLCMediaPlayer) -> Void) {
        let p = player
        Self.vlcQueue.async { block(p) }
    }

    var current: Item { queue[index] }
    var isLive: Bool { current.kind == .live }
    var canPrev: Bool { index > 0 }
    var canNext: Bool { index + 1 < queue.count }

    init(app: AppState, queue: [Item], index: Int) {
        self.app = app
        self.queue = queue
        self.index = index
        super.init()
        player.setDeinterlaceFilter("yadif")
    }

    private var uaList: [String] { unique([app.account?.streamUA] + STREAM_UAS) }

    func start() {
        timer?.invalidate()
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.willResignActive() }
            },
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enterBackground() }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enterForeground() }
            },
        ]
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        play(index: index)
        loadSeriesQueueIfNeeded()
        if UITest.nextAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + UITest.nextAfter) { [weak self] in dlog("test: next"); self?.next() }
        }
        if UITest.seekTo > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self else { return }
                dlog("test: seek to \(UITest.seekTo) (len \(self.lengthMs))")
                self.vlc { $0.time = VLCTime(int: Int32(UITest.seekTo * 1000)) }
            }
        }
    }

    func stop() {
        saveProgress()
        token += 1
        retrying = true
        countdownTask?.cancel()
        timer?.invalidate(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if pipActive { pip?.stopPictureInPicture() }
        dlog("player closed \(current.sid)")
        vlc { $0.stop() }
    }

    // App goes to the home screen / lock: stop the stream (frees the single server connection,
    // and iOS does not allow video drawing in the background – that gave the black frozen screen).
    func pipReady(_ c: VLCPictureInPictureWindowControlling) {
        pip = c
        c.stateChangeEventHandler = { [weak self] started in
            DispatchQueue.main.async { self?.pipChanged(started) }
        }
        pipAvailable = true
        dlog("PiP ready")
    }

    func startPiP() {
        guard let pip, !pipActive else { return }
        pipRequested = true
        dlog("PiP start requested")
        pip.startPictureInPicture()
    }

    private func pipChanged(_ started: Bool) {
        pipActive = started
        pipRequested = false
        dlog("PiP: \(started)")
        // PiP window closed while the app is in the background: stop the stream (frees the 1 connection)
        if !started && UIApplication.shared.applicationState == .background { suspendForBackground() }
    }

    // Home swipe while a video plays → continue in the small PiP window
    private func willResignActive() {
        guard timer != nil, !suspended, gotVideo, error == nil, !pipActive else { return }
        startPiP()
    }

    private func enterBackground() {
        guard !suspended, timer != nil else { return }
        if pipActive || pipRequested {
            // give PiP a moment to come up; if it did not, stop as before
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, UIApplication.shared.applicationState == .background, !self.pipActive else { return }
                dlog("PiP did not start – stop")
                self.suspendForBackground()
            }
            return
        }
        suspendForBackground()
    }

    private func suspendForBackground() {
        guard !suspended, timer != nil else { return }
        saveProgress()
        suspended = true
        resumeAfterBackground = isLive ? nil : (timeMs > 0 ? Double(timeMs) / 1000 : app.positions[current.id])
        token += 1
        retrying = true
        countdownTask?.cancel(); nextIn = nil
        dlog("background: stop \(current.sid)")
        vlc { $0.stop() }
    }

    private func enterForeground() {
        if pipActive { dlog("PiP stop (app back)"); pip?.stopPictureInPicture() }
        guard suspended else { return }
        suspended = false
        attempt = 0; uaIdx = 0; error = nil; finished = false
        status = "Opening…"
        token += 1
        let tok = token
        let at = resumeAfterBackground
        dlog("foreground: reopen \(current.sid)")
        Orientation.set(.allButUpsideDown, prefer: .landscapeRight)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.open(tok: tok, startAt: at) }
    }

    func play(index i: Int) {
        guard queue.indices.contains(i) else { return }
        saveProgress()
        countdownTask?.cancel(); nextIn = nil
        index = i
        attempt = 0; uaIdx = 0; error = nil; finished = false
        timeMs = 0; lengthMs = 0
        status = "Opening…"
        app.recordPlay(current)
        token += 1
        retrying = true
        let tok = token
        let wasOpen = player.media != nil
        vlc { $0.stop() }
        let startAt: Double? = isLive ? nil : app.positions[current.id]
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasOpen ? 0.8 : 0)) { [weak self] in
            self?.open(tok: tok, startAt: startAt)
        }
    }

    func next() { if canNext { play(index: index + 1) } }
    func prev() { if canPrev { play(index: index - 1) } }

    private func open(tok: Int, startAt: Double?) {
        guard tok == token else { return }
        retrying = false
        guard let acc = app.account, let url = Xtream.streamURL(current, acc: acc, format: app.settings.liveFormat) else {
            error = "Aa item mate link nathi"; status = nil; return
        }
        let uas = uaList
        let ua = uas[min(uaIdx, uas.count - 1)]
        guard let media = VLCMedia(url: url) else { error = "Link kharab chhe"; status = nil; return }
        media.addOption(":http-user-agent=\(ua)")
        media.addOption(":network-caching=\(app.settings.caching)")
        media.addOption(":live-caching=\(app.settings.caching)")
        media.addOption(":http-reconnect")
        if let s = startAt, s > 5 { media.addOption(":start-time=\(Int(s))") }
        dlog("open \(current.kind.rawValue) \(current.sid) ua=\(ua) try=\(attempt) start=\(startAt ?? 0)")
        gotVideo = false
        openedAt = Date()
        vlc { p in p.media = media; p.play() }
    }

    private func tick() {
        if suspended { return }
        let nowPlaying = player.isPlaying
        if nowPlaying != isPlaying { pip?.invalidatePlaybackState() }
        isPlaying = nowPlaying
        let t = Int(player.time.intValue)
        if t > 0 { timeMs = t }
        let len = Int(player.media?.length.intValue ?? 0)
        if len > 0 { lengthMs = len }

        if !gotVideo && (player.hasVideoOut || (t > 0 && player.isPlaying)) {
            gotVideo = true
            status = nil
            dlog("PLAYING \(current.sid) video=\(player.hasVideoOut) size=\(Int(player.videoSize.width))x\(Int(player.videoSize.height)) audio=\(audioTracks.map { $0.name }) subs=\(subtitleTracks.map { $0.name })")
            let uas = uaList
            app.setStreamUA(uas[min(uaIdx, uas.count - 1)])
        }

        switch player.state {
        case .opening:
            if !gotVideo { status = attempt > 0 ? "Connecting… (try \(attempt + 1))" : "Opening…" }
        case .buffering:
            if !gotVideo { status = "Buffering…" }
        case .error:
            fail()
        case .stopped:
            if retrying || error != nil || finished || player.media == nil { break }
            if Date().timeIntervalSince(openedAt) < 1.0 { break }
            if !isLive && gotVideo && lengthMs > 0 && Double(timeMs) > Double(lengthMs) * 0.9 { ended() }
            else { fail() }
        default:
            break
        }
        if !gotVideo && error == nil && !retrying && Date().timeIntervalSince(openedAt) > 25 { fail() }
        if Date().timeIntervalSince(lastSave) > 10 { saveProgress() }
    }

    private func fail() {
        guard !retrying, error == nil, !finished else { return }
        let wasPlaying = gotVideo
        if wasPlaying { attempt = 0 }
        attempt += 1
        if attempt > 4 { uaIdx += 1; attempt = 1 }
        dlog("fail \(current.sid) state=\(player.state.rawValue) attempt=\(attempt) ua#\(uaIdx)")
        if uaIdx >= uaList.count {
            dlog("GIVE UP \(current.sid)")
            status = nil
            error = isLive
                ? "Aa channel chali nathi rahyo.\nServer busy hoy (1 connection – PC / tablet bandh karo) athva channel source par kharab chhe."
                : "Video chali nathi rahyo.\nServer busy hoy (1 connection – PC / tablet bandh karo)."
            vlc { $0.stop() }
            return
        }
        retrying = true
        status = wasPlaying ? "Reconnecting…" : "Connecting… (try \(attempt + 1))"
        let resume: Double? = isLive ? nil : Double(timeMs) / 1000
        vlc { $0.stop() }
        let tok = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, tok == self.token else { return }
            self.retrying = false
            self.open(tok: tok, startAt: resume)
        }
    }

    func retry() {
        error = nil; attempt = 0; uaIdx = 0
        status = "Opening…"
        token += 1
        retrying = true
        let tok = token
        vlc { $0.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.open(tok: tok, startAt: (self?.isLive ?? true) ? nil : Double(self?.timeMs ?? 0) / 1000)
        }
    }

    private func ended() {
        dlog("ended \(current.sid)")
        finished = true
        saveProgress(force: true)
        if current.kind == .episode && canNext && app.settings.autoNext {
            countdownTask?.cancel()
            countdownTask = Task { [weak self] in
                for s in stride(from: 5, through: 1, by: -1) {
                    await MainActor.run { self?.nextIn = s }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                await MainActor.run { self?.next() }
            }
        } else {
            status = nil
        }
    }

    func cancelAutoNext() { countdownTask?.cancel(); nextIn = nil }

    func saveProgress(force: Bool = false) {
        lastSave = Date()
        guard current.kind == .movie || current.kind == .episode, lengthMs > 0, timeMs > 0 else { return }
        let pos = force && finished ? Double(lengthMs) / 1000 : Double(timeMs) / 1000
        dlog("save pos \(current.sid) \(Int(pos))/\(lengthMs / 1000)")
        app.setPosition(current, pos: pos, dur: Double(lengthMs) / 1000)
    }

    // MARK: controls
    func togglePause() {
        if finished { finished = false; play(index: index); return }
        if player.isPlaying { vlc { $0.pause() } } else { vlc { $0.play() } }
    }

    func skip(_ secs: Int) {
        guard !isLive, player.isSeekable else { return }
        let t = max(0, timeMs + secs * 1000)
        vlc { $0.time = VLCTime(int: Int32(t)) }
        timeMs = t
    }

    func seek(fraction f: Double) {
        guard !isLive, lengthMs > 0 else { return }
        let t = Int(Double(lengthMs) * min(max(f, 0), 1))
        vlc { $0.time = VLCTime(int: Int32(t)) }
        timeMs = t
    }

    var audioTracks: [Track] { player.audioTracks.map { Track(id: $0.trackId, name: $0.trackName) } }
    var subtitleTracks: [Track] {
        let t = player.textTracks
        return t.isEmpty ? [] : [Track(id: "", name: "Off")] + t.map { Track(id: $0.trackId, name: $0.trackName) }
    }
    var currentAudio: String { player.audioTracks.first(where: { $0.isSelected })?.trackId ?? "" }
    var currentSub: String { player.textTracks.first(where: { $0.isSelected })?.trackId ?? "" }
    func setAudio(_ id: String) { player.audioTracks.first(where: { $0.trackId == id })?.isSelectedExclusively = true; objectWillChange.send() }
    func setSub(_ id: String) {
        if id.isEmpty { player.deselectAllTextTracks() }
        else { player.textTracks.first(where: { $0.trackId == id })?.isSelectedExclusively = true }
        objectWillChange.send()
    }

    // Opened from "Continue watching": fetch the series so the next episode can follow.
    private func loadSeriesQueueIfNeeded() {
        guard queue.count == 1, current.kind == .episode, current.seriesId != nil, let acc = app.account else { return }
        let ep = current
        Task {
            guard let info = try? await Xtream.seriesInfo(ep, acc: acc, ua: app.apiUA) else { return }
            let all = info.seasons.flatMap { $0.episodes }
            if let i = all.firstIndex(where: { $0.id == ep.id }), queue.count == 1, current.id == ep.id {
                queue = all; index = i
            }
        }
    }
}

// Picture in Picture asks VLC's media controller for these (called from VLC / AVKit threads).
extension PlayerController: VLCPictureInPictureMediaControlling {
    nonisolated func play() { PlayerController.vlcQueue.async { [player] in player.play() } }
    nonisolated func pause() { PlayerController.vlcQueue.async { [player] in player.pause() } }
    nonisolated func seek(by offset: Int64, completion: @escaping () -> Void) {
        PlayerController.vlcQueue.async { [player] in
            let t = max(0, Int64(player.time.intValue) + offset)
            player.time = VLCTime(int: Int32(truncatingIfNeeded: t))
            DispatchQueue.main.async(execute: completion)
        }
    }
    nonisolated func mediaLength() -> Int64 { Int64(player.media?.length.intValue ?? 0) }
    nonisolated func mediaTime() -> Int64 { Int64(player.time.intValue) }
    nonisolated func isMediaSeekable() -> Bool { player.isSeekable && mediaLength() > 0 }
    nonisolated func isMediaPlaying() -> Bool { player.isPlaying }
}
