import SwiftUI
import UIKit
import VLCKit
import MediaPlayer
import AVFoundation

/// iPhone system volume (instant, same as the side buttons). An MPVolumeView must be on screen for this;
/// it is kept invisible and also hides the big system volume pop-up.
final class SystemVolume {
    private var kvo: NSKeyValueObservation?
    /// called with the new volume (0…1) whenever it changes – side buttons or our swipe
    func observe(_ onChange: @escaping (Float) -> Void) {
        try? AVAudioSession.sharedInstance().setActive(true)
        kvo = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, ch in
            if let v = ch.newValue { DispatchQueue.main.async { onChange(v) } }
        }
    }
    let view: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        return v
    }()
    private var slider: UISlider? { view.subviews.compactMap { $0 as? UISlider }.first }
    var value: Float {
        get { slider?.value ?? AVAudioSession.sharedInstance().outputVolume }
        set {
            guard let s = slider else { return }
            s.value = min(max(newValue, 0), 1)
            s.sendActions(for: .valueChanged)
        }
    }
}

struct VolumeHost: UIViewRepresentable {
    let volume: SystemVolume
    func makeUIView(context: Context) -> UIView {
        let c = UIView(frame: .zero)
        c.isUserInteractionEnabled = false
        c.addSubview(volume.view)
        return c
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct VLCVideoView: UIViewRepresentable {
    let pc: PlayerController
    func makeUIView(context: Context) -> UIView {
        let v = PiPVideoView()
        v.backgroundColor = .black
        v.pipMediaController = pc
        v.onPiPReady = { [weak pc] c in DispatchQueue.main.async { pc?.pipReady(c) } }
        pc.player.drawable = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PlayerScreen: View {
    @StateObject private var pc: PlayerController
    @EnvironmentObject private var app: AppState
    @State private var showControls = true
    @State private var hint: String?
    @State private var dragMode = 0          // 1 brightness, 2 volume
    @State private var dragStartValue: Float = 0
    @State private var scrubbing = false
    @State private var scrub: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var sysVolume = SystemVolume()
    @State private var showGuide = false

    init(app: AppState, request: PlayRequest) {
        _pc = StateObject(wrappedValue: PlayerController(app: app, queue: request.queue, index: request.index))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Group {
                    Color.black
                    VolumeHost(volume: sysVolume).frame(width: 1, height: 1).allowsHitTesting(false)
                    VLCVideoView(pc: pc)

                    // gestures: tap = show/hide, swipe up/down left = brightness, right = volume
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { toggleControls() }
                        .gesture(swipe(geo.size))
                }
                .ignoresSafeArea()

                if let s = pc.status, pc.error == nil {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white).scaleEffect(1.4)
                        Text(s).foregroundStyle(.white).font(.callout)
                    }
                    .allowsHitTesting(false)
                }

                if let e = pc.error { errorBox(e) }
                if let n = pc.nextIn { nextBox(n) }

                if let hint {
                    Text(hint)
                        .font(.title3.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .glass(Capsule(), interactive: false)
                        .environment(\.colorScheme, .dark)
                        .allowsHitTesting(false)
                }

                if let m = pc.message {
                    VStack {
                        Text(m).font(.callout.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .glass(Capsule(), interactive: false)
                            .environment(\.colorScheme, .dark)
                            .padding(.top, 70)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if showControls { controls(landscape: geo.size.width > geo.size.height, size: geo.size) }
            }
            .onAppear { pc.viewSize = geo.size }
            .onChange(of: geo.size) { s in pc.viewSize = s; if pc.aspect == .fill { pc.applyAspect() } }
        }
        .background(Color.black.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: pc.message)
        .sheet(isPresented: $showGuide) { GuideSheet(pc: pc).presentationDetents([.medium, .large]) }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            pc.start()
            scheduleHide()
            if UserDefaults.standard.bool(forKey: "uitest_rec") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { pc.toggleRecording() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) { pc.toggleRecording() }
            }
            let pa = UserDefaults.standard.double(forKey: "uitest_portrait_after")
            if pa > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + pa) { toPortrait() } }
            sysVolume.observe { v in showHint((v == 0 ? "🔇 " : "🔊 ") + "\(Int((v * 100).rounded()))%") }
        }
        .onDisappear {
            pc.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            Orientation.set(.portrait, prefer: .portrait)
        }
    }

    // MARK: overlay (glass controls like the Windows player)
    private func controls(landscape: Bool, size: CGSize) -> some View {
        VStack(spacing: 0) {
            // top: back · title / category · actions
            HStack(alignment: .center, spacing: 10) {
                GlassIcon(system: landscape ? "chevron.down" : "xmark") { landscape ? toPortrait() : close() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleText).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    let cat = pc.categoryName
                    if !cat.isEmpty { Text(cat.uppercased()).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                }
                .shadow(radius: 3)
                Spacer(minLength: 6)
                if landscape {
                    HStack(spacing: 8) {
                        if pc.isLive { GlassPill(title: recTitle, system: "record.circle", tint: pc.recording ? .red : .white) { pc.toggleRecording(); scheduleHide() } }
                        GlassPill(title: "Link", system: "link") { pc.copyLink(); scheduleHide() }
                        if pc.isLive { GlassPill(title: "TV Guide", system: "info.circle") { showGuide = true } }
                        GlassPill(title: "Open in VLC", system: "arrow.up.forward.app") { pc.openInVLC() }
                        GlassIcon(system: app.isFav(pc.current) ? "star.fill" : "star", tint: app.isFav(pc.current) ? .yellow : .white) { app.toggleFav(pc.current) }
                    }
                } else {
                    if pc.recording { Text(recTitle).font(.caption.bold()).foregroundStyle(.red).padding(.horizontal, 10).frame(height: 30).glass(Capsule(), interactive: false) }
                    moreMenu
                }
            }
            .padding(.horizontal, 14).padding(.top, landscape ? 10 : 4)

            Spacer()
            if !landscape { transport(big: true) }
            Spacer()

            // bottom: progress + buttons
            VStack(spacing: 10) {
                progressRow
                if landscape {
                    HStack(spacing: 10) {
                        GlassIcon(system: pc.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { pc.toggleMute(); scheduleHide() }
                        Spacer(minLength: 4)
                        GlassIcon(system: aspectIcon) { pc.cycleAspect(); scheduleHide() }
                        transport(big: false)
                        subtitleMenu
                        audioMenu
                        settingsMenu
                        Spacer(minLength: 4)
                        if pc.pipAvailable { GlassIcon(system: "pip.enter") { pc.startPiP() } }
                        GlassIcon(system: "arrow.down.right.and.arrow.up.left") { toPortrait() }
                    }
                } else {
                    HStack(spacing: 4) {
                        GlassIcon(system: pc.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 40) { pc.toggleMute(); scheduleHide() }
                        GlassIcon(system: aspectIcon, size: 40) { pc.cycleAspect(); scheduleHide() }
                        subtitleMenu
                        audioMenu
                        settingsMenu
                        if pc.pipAvailable { GlassIcon(system: "pip.enter", size: 40) { pc.startPiP() } }
                        GlassIcon(system: "arrow.up.left.and.arrow.down.right", size: 40) { toLandscape() }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, landscape ? 8 : 6)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .background(
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: 170)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
        .transition(.opacity)
    }

    /// ⏮  −30  ⏯  +30  ⏭
    private func transport(big: Bool) -> some View {
        HStack(spacing: big ? 22 : 10) {
            if pc.queue.count > 1 {
                GlassIcon(system: "backward.end.fill", size: big ? 52 : 44) { pc.prev(); scheduleHide() }
                    .disabled(!pc.canPrev).opacity(pc.canPrev ? 1 : 0.35)
            }
            if !pc.isLive { GlassIcon(system: "gobackward.30", size: big ? 52 : 44) { pc.skip(-30); scheduleHide() } }
            GlassIcon(system: pc.isPlaying ? "pause.fill" : "play.fill", size: big ? 76 : 56,
                      font: .system(size: big ? 32 : 24, weight: .bold)) { pc.togglePause(); scheduleHide() }
            if !pc.isLive { GlassIcon(system: "goforward.30", size: big ? 52 : 44) { pc.skip(30); scheduleHide() } }
            if pc.queue.count > 1 {
                GlassIcon(system: "forward.end.fill", size: big ? 52 : 44) { pc.next(); scheduleHide() }
                    .disabled(!pc.canNext).opacity(pc.canNext ? 1 : 0.35)
            }
        }
    }

    @ViewBuilder private var progressRow: some View {
        if pc.isLive {
            HStack {
                Button { pc.goLive(); scheduleHide() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(pc.behindLive > 2 ? "GO LIVE (−\(fmtTime(Double(pc.behindLive))))" : "LIVE")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                }
                .buttonStyle(.plain)
                .glass(Capsule())
                .disabled(pc.behindLive <= 2)
                Spacer()
                if pc.liveElapsed > 0 {
                    Text(fmtTime(Double(pc.liveElapsed))).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 12).frame(height: 30).glass(Capsule(), interactive: false)
                }
            }
        } else {
            HStack(spacing: 10) {
                Text(fmtTime(Double(scrubbing ? Int(scrub * Double(pc.lengthMs)) : pc.timeMs) / 1000))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Slider(value: Binding(get: { scrubbing ? scrub : fraction }, set: { scrub = $0 }), in: 0...1) { editing in
                    if editing { scrubbing = true; scrub = fraction; hideTask?.cancel() }
                    else { pc.seek(fraction: scrub); scrubbing = false; scheduleHide() }
                }
                .tint(.white)
                Text("−" + fmtTime(Double(max(pc.lengthMs - pc.timeMs, 0)) / 1000))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .padding(.horizontal, 14).frame(height: 40)
            .glass(Capsule(), interactive: false)
        }
    }

    private var recTitle: String {
        guard pc.recording, let s = pc.recordStarted else { return "Rec" }
        return "REC " + fmtTime(Date().timeIntervalSince(s))
    }

    private var aspectIcon: String {
        switch pc.aspect {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .wide: return "rectangle.ratio.16.to.9"
        case .classic: return "rectangle.ratio.4.to.3"
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { app.toggleFav(pc.current) } label: {
                Label(app.isFav(pc.current) ? "Favourites mathi kadho" : "Favourites ma umero", systemImage: app.isFav(pc.current) ? "star.fill" : "star")
            }
            if pc.isLive {
                Button { pc.toggleRecording() } label: { Label(pc.recording ? "Recording bandh karo" : "Record karo", systemImage: "record.circle") }
                Button { showGuide = true } label: { Label("TV Guide", systemImage: "info.circle") }
            }
            Button { pc.copyLink() } label: { Label("Link copy karo", systemImage: "link") }
            Button { pc.openInVLC() } label: { Label("Open in VLC", systemImage: "arrow.up.forward.app") }
        } label: { GlassMenuLabel(system: "ellipsis") }
    }

    private var subtitleMenu: some View {
        Menu {
            let s = pc.subtitleTracks
            if s.isEmpty { Text("Subtitle nathi") }
            ForEach(s) { t in
                Button { pc.setSub(t.id) } label: { Label(t.name, systemImage: t.id == pc.currentSub ? "checkmark" : "captions.bubble") }
            }
        } label: { GlassMenuLabel(system: "captions.bubble") }
    }

    private var audioMenu: some View {
        Menu {
            let a = pc.audioTracks
            if a.isEmpty { Text("Audio track nathi") }
            ForEach(a) { t in
                Button { pc.setAudio(t.id) } label: { Label(t.name, systemImage: t.id == pc.currentAudio ? "checkmark" : "speaker.wave.2") }
            }
        } label: { GlassMenuLabel(system: "music.note.list") }
    }

    private var settingsMenu: some View {
        Menu {
            if !pc.isLive {
                Menu("Speed (\(pc.rate == 1 ? "normal" : String(format: "%.2gx", pc.rate)))") {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                        Button { pc.setRate(r) } label: { Label(r == 1 ? "Normal" : String(format: "%.2gx", r), systemImage: r == pc.rate ? "checkmark" : "speedometer") }
                    }
                }
            }
            Menu(pc.sleepAt == nil ? "Sleep timer" : "Sleep timer (chalu)") {
                ForEach([0, 15, 30, 60, 90], id: \.self) { m in
                    Button { pc.setSleep(minutes: m) } label: { Text(m == 0 ? "Bandh" : "\(m) minute") }
                }
            }
            Menu("Screen: \(pc.aspect.title)") {
                ForEach(PlayerController.AspectMode.allCases, id: \.self) { a in
                    Button { pc.aspect = a; pc.applyAspect() } label: { Label(a.title, systemImage: a == pc.aspect ? "checkmark" : "rectangle") }
                }
            }
        } label: { GlassMenuLabel(system: "gearshape.fill") }
    }

    private func errorBox(_ e: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text(e).multilineTextAlignment(.center).foregroundStyle(.white)
            HStack(spacing: 12) {
                Button("Fari try karo") { pc.retry() }.buttonStyle(.borderedProminent)
                if pc.isLive && pc.canNext { Button("Next channel") { pc.next() }.buttonStyle(.bordered).tint(.white) }
                Button("Bandh karo") { close() }.buttonStyle(.bordered).tint(.white)
            }
        }
        .padding(24)
        .glass(RoundedRectangle(cornerRadius: 24), interactive: false)
        .environment(\.colorScheme, .dark)
        .padding(30)
    }

    private func nextBox(_ n: Int) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next episode \(n) sec ma…").foregroundStyle(.white).font(.callout.bold())
                    HStack {
                        Button("Have j jovo") { pc.cancelAutoNext(); pc.next() }.buttonStyle(.borderedProminent)
                        Button("Cancel") { pc.cancelAutoNext() }.buttonStyle(.bordered).tint(.white)
                    }
                }
                .padding(16)
                .glass(RoundedRectangle(cornerRadius: 22), interactive: false)
                .environment(\.colorScheme, .dark)
            }
        }
        .padding(30)
    }

    private var titleText: String {
        let c = pc.current
        if c.kind == .live, let n = c.num { return "\(n) · \(c.name)" }
        return c.displayName
    }

    private var fraction: Double { pc.lengthMs > 0 ? Double(pc.timeMs) / Double(pc.lengthMs) : 0 }

    // MARK: actions
    private func close() {
        pc.stop()
        app.closePlayer()
    }

    private func toPortrait() {
        dlog("player: to portrait")
        Orientation.set(.allButUpsideDown, prefer: .portrait)
        withAnimation { showControls = true }
        scheduleHide()
    }
    private func toLandscape() {
        dlog("player: to landscape")
        Orientation.set(.allButUpsideDown, prefer: .landscapeRight)
        withAnimation { showControls = true }
        scheduleHide()
    }

    @State private var hintTask: Task<Void, Never>?
    private func showHint(_ h: String) {
        hint = h
        hintTask?.cancel()
        hintTask = Task { try? await Task.sleep(nanoseconds: 1_200_000_000); if !Task.isCancelled && dragMode == 0 { hint = nil } }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && !scrubbing && !showGuide && pc.error == nil {
                withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
            }
        }
    }

    private func swipe(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                if dragMode == 0 {
                    guard abs(v.translation.height) > abs(v.translation.width) else { return }
                    dragMode = v.startLocation.x < size.width / 2 ? 1 : 2
                    dragStartValue = dragMode == 1 ? Float(UIScreen.main.brightness) : sysVolume.value
                }
                let delta = Float(-v.translation.height / max(size.height * 0.8, 1))
                if dragMode == 1 {
                    let b = min(max(dragStartValue + delta, 0), 1)
                    UIScreen.main.brightness = CGFloat(b)
                    showHint("☀️ \(Int(b * 100))%")
                } else if dragMode == 2 {
                    let vol = min(max(dragStartValue + delta, 0), 1)
                    if abs(vol - sysVolume.value) >= 0.01 { sysVolume.value = vol }
                    showHint((vol == 0 ? "🔇 " : "🔊 ") + "\(Int((vol * 100).rounded()))%")
                }
            }
            .onEnded { _ in
                dragMode = 0
                if let h = hint { showHint(h) }
            }
    }
}

/// UIKit host for the player: SwiftUI's fullScreenCover only allows portrait, this one allows landscape.
final class PlayerHost: UIHostingController<AnyView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    @MainActor private static var rootVC: UIViewController? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
    }

    /// Opens the player. If an old player is still closing (animation), waits for it first –
    /// otherwise iOS silently refuses to show the new one.
    @MainActor static func present(_ view: AnyView, tries: Int = 0) {
        guard let root = rootVC else { return }
        if let shown = root.presentedViewController {
            if tries < 15 && (shown.isBeingDismissed || shown.isBeingPresented || shown is PlayerHost) {
                if shown is PlayerHost && !shown.isBeingDismissed { root.dismiss(animated: false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { present(view, tries: tries + 1) }
                return
            }
            root.dismiss(animated: false)
        }
        let host = PlayerHost(rootView: view)
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = .black
        AppDelegate.mask = .allButUpsideDown
        dlog("player shown")
        root.present(host, animated: true) {
            Orientation.set(.allButUpsideDown, prefer: .landscapeRight)
        }
    }

    @MainActor static func dismissIfShown() {
        guard let root = rootVC, let shown = root.presentedViewController as? PlayerHost, !shown.isBeingDismissed else { return }
        root.dismiss(animated: true)
    }
}

/// TV Guide (now / next) – this server often has no programme data.
struct GuideSheet: View {
    @ObservedObject var pc: PlayerController
    @State private var items: [Xtream.EPGItem]?
    @State private var failed: String?

    var body: some View {
        NavigationStack {
            List {
                if let items {
                    if items.isEmpty {
                        Text("Aa channel mate server par programme ni mahiti nathi.").foregroundStyle(.secondary)
                    }
                    ForEach(items) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(e.title).font(.headline)
                                Spacer()
                                if let s = e.start { Text(s.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                            }
                            if !e.desc.isEmpty { Text(e.desc).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }
                        }
                    }
                } else if let failed {
                    Text(failed).foregroundStyle(.red)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle(pc.current.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            guard let acc = pc.app.account else { return }
            do { items = try await Xtream.shortEPG(pc.current, acc: acc, ua: pc.app.apiUA) }
            catch { failed = error.localizedDescription }
        }
    }
}
