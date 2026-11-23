import SwiftUI
import UIKit
import MobileVLCKit
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
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        player.drawable = v
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

    init(app: AppState, request: PlayRequest) {
        _pc = StateObject(wrappedValue: PlayerController(app: app, queue: request.queue, index: request.index))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Group {
                    Color.black
                    VolumeHost(volume: sysVolume).frame(width: 1, height: 1).allowsHitTesting(false)
                    VLCVideoView(player: pc.player)

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
                        .background(.black.opacity(0.6), in: Capsule())
                        .allowsHitTesting(false)
                }

                if showControls { controls(landscape: geo.size.width > geo.size.height) }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            pc.start()
            scheduleHide()
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

    // MARK: overlay
    private func controls(landscape: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // landscape: X first turns the player upright; upright: X closes
                Button { landscape ? toPortrait() : close() } label: {
                    Image(systemName: landscape ? "chevron.down" : "xmark").font(.title3.bold()).frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText).font(.headline).lineLimit(1)
                    if pc.isLive { Text("● LIVE").font(.caption.bold()).foregroundStyle(.red) }
                }
                Spacer()
                tracksMenu
                Button { app.toggleFav(pc.current) } label: {
                    Image(systemName: app.isFav(pc.current) ? "star.fill" : "star").font(.title3).frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 12).padding(.top, landscape ? 8 : 4)
            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())

            Spacer()

            HStack(spacing: 46) {
                if pc.queue.count > 1 {
                    Button { pc.prev(); scheduleHide() } label: { Image(systemName: "backward.end.fill").font(.title) }
                        .disabled(!pc.canPrev).opacity(pc.canPrev ? 1 : 0.3)
                }
                if !pc.isLive {
                    Button { pc.seek(by: -10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.title) }
                }
                Button { pc.togglePause(); scheduleHide() } label: {
                    Image(systemName: pc.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                }
                if !pc.isLive {
                    Button { pc.seek(by: 30); scheduleHide() } label: { Image(systemName: "goforward.30").font(.title) }
                }
                if pc.queue.count > 1 {
                    Button { pc.next(); scheduleHide() } label: { Image(systemName: "forward.end.fill").font(.title) }
                        .disabled(!pc.canNext).opacity(pc.canNext ? 1 : 0.3)
                }
            }

            Spacer()

            if !pc.isLive {
                HStack(spacing: 10) {
                    Text(fmtTime(Double(scrubbing ? Int(scrub * Double(pc.lengthMs)) : pc.timeMs) / 1000)).font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { scrubbing ? scrub : fraction }, set: { scrub = $0 }), in: 0...1) { editing in
                        if editing { scrubbing = true; scrub = fraction; hideTask?.cancel() }
                        else { pc.seek(fraction: scrub); scrubbing = false; scheduleHide() }
                    }
                    .tint(.red)
                    Text(fmtTime(Double(pc.lengthMs) / 1000)).font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }
            if !landscape {
                HStack {
                    Spacer()
                    Button { toLandscape() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.title3).frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 4)
            }
        }
        .foregroundStyle(.white)
        .transition(.opacity)
    }

    private var tracksMenu: some View {
        Menu {
            let a = pc.audioTracks
            if !a.isEmpty {
                Section("Audio") {
                    ForEach(a) { t in
                        Button { pc.setAudio(t.id) } label: { Label(t.name, systemImage: t.id == pc.currentAudio ? "checkmark" : "speaker.wave.2") }
                    }
                }
            }
            let s = pc.subtitleTracks
            if !s.isEmpty {
                Section("Subtitles") {
                    ForEach(s) { t in
                        Button { pc.setSub(t.id) } label: { Label(t.name, systemImage: t.id == pc.currentSub ? "checkmark" : "captions.bubble") }
                    }
                }
            }
            if a.isEmpty && s.isEmpty { Text("Koi track nathi") }
        } label: {
            Image(systemName: "captions.bubble").font(.title3).frame(width: 44, height: 44)
        }
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
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
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
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
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
        scheduleHide()
    }
    private func toLandscape() {
        dlog("player: to landscape")
        Orientation.set(.allButUpsideDown, prefer: .landscapeRight)
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
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && !scrubbing && pc.error == nil {
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
