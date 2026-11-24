import Foundation
import AVKit
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
    // extra player features (1.2)
    enum AspectMode: Int, CaseIterable { case fit, fill, wide, classic
        var title: String { ["Fit", "Fill", "16:9", "4:3"][rawValue] }
    }
    @Published var aspect: AspectMode = .fit { didSet { fillApplied = false } }
    private var fillApplied = false
    @Published var muted = false
    @Published var rate: Float = 1
    @Published var recording = false
    @Published var recordStarted: Date?
    @Published var sleepAt: Date?
    @Published var liveElapsed = 0          // seconds watched on this channel
    @Published var behindLive = 0           // seconds behind live (after pausing)
    @Published var message: String?        // short info shown in the player
    private var playStart: Date?
    private var pausedSince: Date?
    private var pausedTotal: TimeInterval = 0
    var viewSize: CGSize = .zero
    @Published var bufferedMs = 0           // movies / episodes: how far the video is loaded (grey part)
    private var lastDemux: Int64 = 0
    private var lastTimeForRate = 0
    private var bytesPerMs: Double = 0
    private var lastBufferLog = Date.distantPast
    /// after a seek VLC throws away what it had read ahead, but its "read" counter keeps it:
    /// remember that difference and leave it out (otherwise the grey bar jumps far ahead)
    private var bufferBase: Int64?
    private var needBufferBase = true
    private var pendingStart: Double?      // resume point, applied once the video runs
    private var eventLengthMs = 0           // length reported by VLC (more reliable than media.length)

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
        player.delegate = self
        dlog("PiP supported: \(AVPictureInPictureController.isPictureInPictureSupported())")
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
                if self.lengthMs > 0 { self.seek(fraction: UITest.seekTo * 1000 / Double(self.lengthMs)) }
                else { self.vlc { $0.time = VLCTime(int: Int32(UITest.seekTo * 1000)) } }
            }
        }
        if let a = UserDefaults.standard.string(forKey: "uitest_aspect"), let m = AspectMode.allCases.first(where: { $0.title.lowercased() == a }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                dlog("test: screen \(m.title)"); self?.aspect = m; self?.applyAspect()
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
        if recording { vlc { $0.stopRecording() } }
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
        guard let acc = app.account, let url = Downloads.shared.localURL(for: current) ?? Xtream.streamURL(current, acc: acc, format: app.settings.liveFormat) else {
            error = "No link for this item"; status = nil; return
        }
        let uas = uaList
        let ua = uas[min(uaIdx, uas.count - 1)]
        guard let media = VLCMedia(url: url) else { error = "Invalid link"; status = nil; return }
        media.addOption(":http-user-agent=\(ua)")
        media.addOption(":network-caching=\(app.settings.caching)")
        addSoundFilters(media)
        if !isLive && !url.isFileURL {
            // movies / episodes: read well ahead (64 MB) so short network dips do not stop the video
            media.addOption(":prefetch-buffer-size=65536")
        }
        media.addOption(":live-caching=\(app.settings.caching)")
        media.addOption(":http-reconnect")
        pendingStart = (startAt ?? 0) > 5 ? startAt : nil
        lastDemux = 0; lastTimeForRate = 0; bytesPerMs = 0; bufferedMs = 0; needBufferBase = true
        eventLengthMs = 0
        dlog("open \(current.kind.rawValue) \(current.sid)\(url.isFileURL ? " LOCAL-FILE" : "") ua=\(ua) try=\(attempt) start=\(startAt ?? 0)")
        gotVideo = false
        openedAt = Date()
        vlc { p in p.media = media; p.play() }
    }

    private func tick() {
        if suspended { return }
        // Fill needs the picture size, which VLC only knows a moment after the start
        if aspect == .fill, !fillApplied, player.videoSize.width > 0 { fillApplied = true; applyAspect() }
        if let s = sleepAt, Date() >= s { dlog("sleep timer: close"); sleepAt = nil; stop(); app.closePlayer(); return }
        if isLive, let st = playStart {
            if player.state == .paused, pausedSince == nil { pausedSince = Date() }
            if player.state == .playing, let p = pausedSince { pausedTotal += Date().timeIntervalSince(p); pausedSince = nil }
            behindLive = Int(pausedTotal + (pausedSince.map { Date().timeIntervalSince($0) } ?? 0))
            liveElapsed = Int(Date().timeIntervalSince(st))
        }
        let nowPlaying = player.isPlaying
        if nowPlaying != isPlaying { pip?.invalidatePlaybackState() }
        isPlaying = nowPlaying
        let t = Int(player.time.intValue)
        if t > 0 { timeMs = t }
        let len = eventLengthMs > 0 ? eventLengthMs : Int(player.media?.length.intValue ?? 0)
        if len > 0 { lengthMs = len }

        if !gotVideo && (player.hasVideoOut || (t > 0 && player.isPlaying)) {
            gotVideo = true
            status = nil
            playStart = Date(); pausedSince = nil; pausedTotal = 0; behindLive = 0
            applyAspect()
            if let s = pendingStart {
                pendingStart = nil
                dlog("resume seek to \(Int(s))")
                vlc { $0.time = VLCTime(int: Int32(s * 1000)) }
                timeMs = Int(s * 1000)
                afterSeek()
            }
            dlog("PLAYING \(current.sid) video=\(player.hasVideoOut) size=\(Int(player.videoSize.width))x\(Int(player.videoSize.height)) audio=\(audioTracks.map { $0.name }) subs=\(subtitleTracks.map { $0.name })")
            applyBoost()
            let uas = uaList
            app.setStreamUA(uas[min(uaIdx, uas.count - 1)])
        }

        switch player.state {
        case .opening:
            if !gotVideo { status = attempt > 0 ? "Connecting… (try \(attempt + 1))" : "Opening…" }
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
        updateBuffer()
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
                ? "This channel is not playing.\nThe server may be busy (1 connection – close the PC / tablet app) or the channel is down at the source."
                : "This video is not playing.\nThe server may be busy (1 connection – close the PC / tablet app)."
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
        afterSeek()
    }

    func seek(fraction f: Double) {
        guard !isLive, lengthMs > 0 else { return }
        let t = Int(Double(lengthMs) * min(max(f, 0), 1))
        vlc { $0.time = VLCTime(int: Int32(t)) }
        timeMs = t
        afterSeek()
    }

    private func afterSeek() {
        needBufferBase = true
        bufferedMs = timeMs
        lastTimeForRate = 0
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

    /// Buffered position for the grey bar: bytes VLC has read but not yet played, turned into time
    /// with the media's own byte rate (measured while playing).
    private func updateBuffer() {
        guard !isLive, gotVideo, lengthMs > 0 else { bufferedMs = 0; return }
        if let u = streamURL, Downloads.shared.localURL(for: current) != nil || u.isFileURL { bufferedMs = lengthMs; return }
        guard let media = player.media else { return }
        let st: VLCMedia.Stats = media.statistics
        let read: Int64 = Int64(truncatingIfNeeded: st.readBytes)
        let demux: Int64 = Int64(truncatingIfNeeded: st.demuxReadBytes)
        // byte rate of the video itself (bytes demuxed per ms of playback), smoothed
        let dt = timeMs - lastTimeForRate
        let db = Int(demux - lastDemux)
        if lastTimeForRate > 0, dt > 400, dt < 5000, db > 0 {
            let r = Double(db) / Double(dt)
            bytesPerMs = bytesPerMs == 0 ? r : bytesPerMs * 0.8 + r * 0.2
        }
        if !needBufferBase && (dt > 400 || dt < 0) { lastTimeForRate = timeMs; lastDemux = demux }
        guard bytesPerMs > 0, !needBufferBase else { bufferedMs = timeMs; return }
        if needBufferBase {
            // wait ~1 s after the seek so VLC has dropped its old read-ahead, then take the new zero point
            if lastTimeForRate == 0 { lastTimeForRate = -1; return }
            bufferBase = read - demux
            needBufferBase = false
            dlog("buffer base after seek/start: \(read - demux) bytes left out, at \(timeMs / 1000)s")
            lastTimeForRate = timeMs; lastDemux = demux
        }
        let aheadBytes = Double(max(read - demux - (bufferBase ?? 0), 0))
        let aheadMs = Int(aheadBytes / bytesPerMs) + app.settings.caching
        bufferedMs = min(lengthMs, timeMs + aheadMs)
        if Date().timeIntervalSince(lastBufferLog) > 5 {
            lastBufferLog = Date()
            dlog("buffer \(current.sid): time \(timeMs / 1000)s, loaded to \(bufferedMs / 1000)s (ahead \(aheadMs / 1000)s)")
        }
    }

    /// Volume boost:
    /// - the gain is VLC's equalizer pre-amp (flat, all bands 0) – it works at once, no reopening;
    ///   200 % = +10 dB, which sounds about twice as loud
    /// - a limiter (VLC compressor with a high ratio just below full scale) stops the boosted peaks from clipping;
    ///   it is always on and does nothing to normal sound
    private func addSoundFilters(_ media: VLCMedia) {
        media.addOption(":audio-filter=compressor")
        media.addOption(":compressor-rms-peak=1.0")
        media.addOption(":compressor-attack=1.5")
        media.addOption(":compressor-release=120")
        media.addOption(":compressor-threshold=-2.0")
        media.addOption(":compressor-ratio=20")
        media.addOption(":compressor-knee=1.5")
        media.addOption(":compressor-makeup-gain=0")
    }

    func applyBoost(log: Bool = true) {
        let boost = min(max(app.settings.soundBoost, 100), 200)
        let db = Float(10 * log2(Double(boost) / 100))
        vlc { p in
            if boost <= 100 { p.equalizer = nil }
            else { let eq = VLCAudioEqualizer(); eq.preAmplification = db; p.equalizer = eq }
            let now = p.equalizer?.preAmplification ?? 0
            if log { DispatchQueue.main.async { dlog(String(format: "sound: boost %d%% = +%.1f dB (player pre-amp now %.1f dB)", boost, db, now)) } }
        }
    }

    /// New boost from the slider: applied straight away (no reopening).
    func applySound() {
        applyBoost()
        say("Volume boost \(app.settings.soundBoost)%")
    }

    // MARK: extra features
    var categoryName: String {
        let c = current
        let k: Kind = c.kind == .episode ? .series : c.kind
        if c.kind == .episode { return c.season.map { "Season \($0)" } ?? "" }
        return app.lists[k]?.cats.first(where: { $0.id == c.cat })?.name ?? ""
    }

    var streamURL: URL? {
        guard let acc = app.account else { return nil }
        return Xtream.streamURL(current, acc: acc, format: app.settings.liveFormat)
    }

    func say(_ m: String) {
        message = m
        let now = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.message == now { self?.message = nil } }
    }

    func toggleMute() {
        muted.toggle()
        let m = muted
        vlc { $0.audio?.volume = m ? 0 : 100 }
        say(m ? "🔇 Mute" : "🔊 Sound on")
    }

    func cycleAspect() {
        aspect = AspectMode(rawValue: (aspect.rawValue + 1) % AspectMode.allCases.count) ?? .fit
        applyAspect()
        say("Screen: \(aspect.title)")
    }

    func applyAspect() {
        let mode = aspect
        // screen size in pixels and the picture size → zoom that covers the whole screen (edges cut off)
        let scale = UIScreen.main.scale
        let vw = Double(viewSize.width * scale), vh = Double(viewSize.height * scale)
        let pic = player.videoSize
        let fill: Float = pic.width > 0 && pic.height > 0 && vw > 0 ? Float(max(vw / Double(pic.width), vh / Double(pic.height))) : 0
        dlog("aspect \(mode.title) view=\(Int(vw))x\(Int(vh)) video=\(Int(pic.width))x\(Int(pic.height)) zoom=\(fill)")
        vlc { p in
            p.setCropRatioWithNumerator(0, denominator: 0)
            switch mode {
            case .fit: p.videoAspectRatio = nil; p.scaleFactor = 0
            case .fill: p.videoAspectRatio = nil; p.scaleFactor = fill
            case .wide: p.scaleFactor = 0; p.videoAspectRatio = "16:9"
            case .classic: p.scaleFactor = 0; p.videoAspectRatio = "4:3"
            }
        }
    }

    func setRate(_ r: Float, quiet: Bool = false) {
        rate = r
        vlc { $0.rate = r }
        dlog("rate \(r)")
        if !quiet { say("Speed \(r == 1 ? "normal" : String(format: "%.2gx", r))") }
    }

    func setSleep(minutes: Int) {
        sleepAt = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        say(minutes > 0 ? "😴 Closes in \(minutes) min" : "Sleep timer off")
    }

    /// Back to the live edge after a pause (reconnects the channel).
    func goLive() {
        guard isLive else { return }
        dlog("go live")
        play(index: index)
    }

    static var recordingsDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func toggleRecording() {
        if recording {
            dlog("rec stop")
            vlc { $0.stopRecording() }
            recording = false
            recordStarted = nil
        } else {
            guard gotVideo else { say("Start recording once the video plays"); return }
            let dir = Self.recordingsDir.path
            dlog("rec start \(dir)")
            vlc { $0.startRecording(atPath: dir) }
            recording = true
            recordStarted = Date()
            say("⏺ Recording")
        }
    }

    func recordingSaved(_ url: URL?) {
        recording = false
        recordStarted = nil
        let size = (url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }) ?? 0
        dlog("recording saved \(url?.lastPathComponent ?? "-") bytes=\(size)")
        say(url != nil ? "✅ Recording save: Files app → Alnur IPTV → Recordings" : "Recording could not be saved")
    }

    func copyLink() {
        guard let u = streamURL else { return }
        UIPasteboard.general.string = u.absoluteString
        say("🔗 Link copied")
    }

    func openInVLC() {
        guard let u = streamURL,
              let enc = u.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let x = URL(string: "vlc-x-callback://x-callback-url/stream?url=\(enc)") else { return }
        UIApplication.shared.open(x) { [weak self] ok in
            if !ok { self?.say("VLC app is not installed (get 'VLC for Mobile' from the App Store)") }
            else { self?.stop() }
        }
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

extension PlayerController: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.eventLengthMs = Int(length)
            if length > 0 { self.lengthMs = Int(length); self.pip?.invalidatePlaybackState() }
        }
    }
}

extension PlayerController {
    nonisolated func mediaPlayerStartedRecording(_ player: VLCMediaPlayer) {
        DispatchQueue.main.async { dlog("recording started") }
    }
    nonisolated func mediaPlayer(_ player: VLCMediaPlayer, recordingStoppedAt url: URL?) {
        DispatchQueue.main.async { [weak self] in self?.recordingSaved(url) }
    }
}
