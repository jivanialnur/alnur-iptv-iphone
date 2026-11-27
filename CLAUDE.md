# Alnur IPTV – iPhone app

Owner: Alnur. Writes romanized Gujarati / Gujarati – answer in the same, short and clear. Test properly before claiming it works.

## What he wants
- An iPhone version of his own IPTV player (Windows app = repo `alnur-iptv-windows`, Android tablet app = repo `alnur-iptv-android`).
- Device: **iPhone 18 Pro (small)** → **portrait-only browsing UI**, like the screenshot he shared from another IPTV app:
  large "Channels" title, search bar, "Most Watched" + "Suggestions" lists (logo + name rows), bottom tab bar
  **Live · Movies · Series · Library · Settings**. Player full screen (landscape allowed there).
- Same account / features as the other apps where possible: login (Xtream), categories, search, favourites, continue watching,
  resume, channel numbers, auto-next episode, swipe volume/brightness in player.

## Hard facts / decisions still open
- iOS apps can only be built on macOS (Xcode). Claude's sandbox is Linux → build on **GitHub Actions macOS runner** (this repo).
- **Decided 2026-11-23: free Apple ID + Sideloadly** (no $99 account). CI builds an UNSIGNED IPA; Sideloadly signs it on his
  Windows PC. Free-ID limits: re-install every 7 days, max 3 sideloaded apps, Developer Mode must be on in the iPhone.
- Player: AVPlayer can't play raw MPEG-TS live / AC3 interlaced well → use **MobileVLCKit** (VLCKit via CocoaPods/SPM).
  Streams need UA `VLC/3.0.21 LibVLC/3.0.21`; API needs MAG/Dalvik-like UA (see alnur-iptv-windows/CLAUDE.md "IPTV server facts").
- Server allows **1 connection at a time** (shared with PC and tablet).
- Suggested approach: SwiftUI app (native tabs/lists as in his screenshot) + VLCKit player screen; reuse the Xtream API logic
  from `alnur-iptv-windows/renderer/app.js` (probe UAs, list caching, favourites, resume points).

## Project layout / build (v1.0.0 started 2026-11-23)
- `project.yml` (XcodeGen) + `Podfile` (MobileVLCKit 3.6) – `.xcodeproj`/`Pods` are generated on CI, not in git.
- `.github/workflows/build.yml` (macos-15): xcodegen → pod install → xcodebuild unsigned → `AlnurIPTV-<ver>.ipa`,
  uploaded as artifact AND as a GitHub release (`releases/latest`). Bump `MARKETING_VERSION` in project.yml.
- No Mac / Swift here: compile errors are only seen in CI logs (`gh run view <id> --log-failed`).
- Code: `AlnurIPTV/` – `Xtream.swift` (API, UA probe, 503 retry), `AppState.swift` (account, lists cached in
  Application Support, favourites, most watched, resume / continue watching in UserDefaults), `Views/` (tabs Live ·
  Movies · Series · Library · Settings), `Player/` (VLCKit; stop + 0.8 s wait before next stream; 4 retries per UA then next UA;
  swipe left = brightness, right = volume; auto-next episode with 5 s countdown).
- **Simulator test** (job `simtest`): `test/mock.js` (mock Xtream: MAG/Dalvik-only API, VLC-only streams, 1 connection + 1 s busy)
  + `test/simtest.sh` launch the app with hooks (`AlnurIPTV/UITest.swift`: `-uitest_login`, `-uitest_play live:1001`,
  `-uitest_tab`, `-uitest_open`, `-uitest_next_after`, `-uitest_seekto`) and take screenshots. Results + PNGs go to the
  prerelease `simtest`; download with `gh api .../releases/tags/simtest` + asset ids (artifact host is blocked here).
- Player is presented with UIKit (`PlayerHost`), NOT SwiftUI fullScreenCover – the cover only allowed portrait.
  Open/close it ONLY via `AppState.play()` / `closePlayer()`: the tab views are paused under the full-screen player,
  so a SwiftUI `.onChange`/`.task` there does not run (1.0.1 bug: X stopped the stream but the black player stayed).
- All blocking VLC calls (stop/play/pause/seek) go through `PlayerController.vlcQueue`, never the main thread.
- App to background → stream stopped (frees the 1 connection); back to foreground → reopened (VOD at same time), landscape again.
- Swipe volume = iPhone system volume via hidden MPVolumeView (VLC volume reacted 1–2 s late).
- ATS: only `NSAllowsArbitraryLoads` – adding `...ForMedia` silently disables it (1.0.0 login bug). Test uses host
  `iptv-mock.test` (/etc/hosts) because localhost/IPs are exempt from ATS and hid that bug.
- Test log = app's own `Documents/iptv.log` (+ `HangWatch` main-thread watchdog), copied by simtest.sh.
- Versions: 1.0.0 first · 1.0.1 ATS/login fix · 1.0.2 X closes player, no freeze, background handling, instant volume
  · 1.0.3 (his wish) Live/Movies/Series open straight on the category list (no Most Watched / Suggestions /
  Recently Added; empty categories hidden, counts shown); search shows matching categories AND items
  · 1.0.4 no swipe hint text, volume % also for side buttons (KVO outputVolume), X in landscape → upright (chevron),
  controls inside safe area (Dynamic Island), full-screen button in portrait. Delivered to his Downloads.
- **PiP (his wish, home swipe → small window)**: MobileVLCKit 3 has no PiP. Branch `vlc4` = VLCKit 4 alpha
  (`pod 'VLCKit', '4.0.0a26'`) + ObjC `AlnurIPTV/PiP/PiPVideoView` (VLCDrawable + VLCPictureInPictureDrawable) +
  PlayerController as VLCPictureInPictureMediaControlling; starts PiP on willResignActive. With a18 everything played
  but `pictureInPictureReady` was never called (no "PiP ready" log) and `:start-time` was ignored (now: seek after start).
  Reference that works: github.com/cornejobarraza/expo-libvlc-player (VLCKit 4.0.0a26, Swift drawable).
  a26 builds and plays (1.1.0, pre-release, delivered to his Downloads as AlnurIPTV-1.1.0-PiP.ipa for a real-iPhone test).
  **Simulator reports `isPictureInPictureSupported() == false` → PiP can only be tested on his iPhone.** a26 has no
  `.buffering` state. Resume = seek after first frame (`:start-time` ignored by VLC 4).
- Repo was recreated PUBLIC on 2026-11-23 (history rewritten, server address removed; never commit it). Public = free CI,
  but macos-15 (arm64) jobs were "not acquired" for hours → workflow uses `macos-15-intel` (slower; simtest there shows
  MAIN HANG at app start / list load, not in the player – Intel simulator slowness, arm64 run had none).
  `main` = app-v1 (1.0.4). Use `[skip ci]` for doc-only commits.
- 1.2.0 (vlc4 branch, delivered 2026-11-23 to his Downloads, NOT yet tested by him): Windows-like player controls in
  Liquid Glass (`Player/Glass.swift`, `.glassEffect` under `#if compiler(>=6.2)`, build job selects Xcode 26.x):
  back/title+category, Rec (VLC startRecording → Documents/Recordings, Files app), Link copy, TV Guide (get_short_epg),
  Open in VLC (vlc-x-callback), mute, screen Fit/Fill/16:9/4:3, ±30, subtitle/audio menus, speed, sleep timer, PiP,
  GO LIVE (−behind) + elapsed. CI: `simtest` = iOS 18 sim via Xcode 16.4 (functional, all pass except PiP – sim
  unsupported – and Intel MAIN HANG at app start); `glass` job = iOS 26 sim screenshots (release `glass-<branch>`).
  · 1.2.x title never shortened (2 lines), landscape top buttons ViewThatFits labels → icons, long press on any glass
  button shows its name (env `glassHelp` → pc.say). · 1.3.0 Downloads (`Downloads.swift`: background URLSession, falls back
  to a normal session when the background service fails – it always does in the simulator; Documents/Downloads,
  Library → Downloads, offline play via `Downloads.shared.localURL`). · 1.3.1 middle swipe like YouTube (left third =
  brightness, right third = volume, middle: up = landscape / Fill zoom, down = unzoom / portrait / close).
  · 1.3.2 double tap left/right = −10/+10 s (adds up), hold right = 2x. · 1.3.3 short title keeps labelled buttons.
  1.3.3 sent in chat 2026-11-23 (PC was off). simtest: all pass except PiP (sim), Intel MAIN HANG at launch, and
  timing flukes (search) from the slow Intel simulator.
  · 1.3.4 grey buffered part on the VOD bar (`ScrubBar`, VLCMedia.Stats readBytes − demuxReadBytes over the measured
  byte rate; 64 MB prefetch). · 1.4.0 several users (Settings → Users; favourites / history stored per user key
  `username@host|…`, old data migrated to the first user). · 1.4.1 ALL UI text in English (his wish – keep it that way),
  confirmation dialogs attached to their buttons (iOS 26 shows them as popovers). · 1.5.0 Sound: boost 100–200 % via VLC
  `compressor` (limiter + make-up gain) and auto-level via `normvol`; set as media options, so a change reopens the
  stream (`pc.applySound()` → retry); right panel (landscape) / bottom sheet (portrait) + Settings; AppSettings decodes
  missing keys. · 1.5.1 ⬇ visible in the portrait player and on each episode row.
  1.5.1 delivered 2026-11-24 (Downloads + chat).
  · 1.6.0 (his 8-point list): Login/Add user has "Xtream Codes | M3U link" (`M3U.swift`: get.php link → Xtream login,
  other playlists parsed – live by group-title, file links → Movies; `Item.url` direct link, `Account.m3u`).
  Volume boost = VLC equalizer pre-amp (`player.equalizer`, flat, 200 % = +10 dB, applied live, no reopen) + compressor
  as limiter (media options; whether a media `:audio-filter` really applies is unverified). Auto-level REMOVED (his wish).
  Fill = `player.scaleFactor` = cover zoom from videoSize/view px (redone after rotation / when size known).
  Rotation bug (video small, left) → `PiPVideoView.layoutSubviews` keeps VLC subviews/sublayers = bounds.
  Grey buffer: baseline (read − demux) taken at start/after every seek. Time label tap = total ⇄ −remaining (UserDefaults).
  Downloads rewritten: foreground = URLSessionDataTask + Range into Application Support/parts/<id>.part (pause/resume
  from bytes on the phone, no ETag needed); app to background → rest via background session (Range), back → normal
  again; MB/s; "Save to Photos" (mp4 direct, else VLC sout `#std{access=file,mux=mp4}` remux, then PHPhotoLibrary addOnly).
  Mock: movie 5001 is throttled ≈1 MB/s (pause test), `/playlist.m3u` + `/get.php`. Hooks: `-uitest_dl_pause`,
  `-uitest_photos`, `-uitest_aspect fill`, `-uitest_add_m3u "Name|link"`.
  · 1.6.1: Fill/Fit = `videoGravity` on VLC's AVSampleBufferDisplayLayer (PiPVideoView.applyFill, re-applied every tick;
  VLC 4 scaleFactor/crop are ignored by that output – 1.6.0 Fill did nothing on his phone). Background downloads:
  `KeepAwake` (silent looping AVAudioPlayer, .mixWithOthers) keeps the app alive so the fast foreground download continues;
  off when no download runs / app returns; if another app interrupts the sound → hand over to background session.
  Photos: remuxed file is 640x360 identity transform (landscape) → "Photos doesn't rotate" = his portrait lock.
  · 1.6.2: 1.6.1 crashed right after "Save to Photos" on his iPhone – PHAsset.fetchAssets (read access, no
  NSPhotoLibraryUsageDescription → iOS kills the app; the simulator did not). Never read/fetch from Photos, add-only.
  · 1.7.0 (his wish: glass look): `Views/Theme.swift` – AppBackground (blurred accent blobs), GlassRow (ultraThinMaterial row
  background via `.glassRows()` on every Section), `.glassList()`, GlassSearchField (glass capsule pinned with
  safeAreaInset, replaces `.searchable`), Settings → Appearance (Auto/Light/Dark + 8 accent colours, applied to all
  windows via overrideUserInterfaceStyle/tintColor; AppSettings.theme/accent). Hook `-uitest_theme dark,purple`;
  glass job screenshots g5–g8 show the browsing screens.
  · 1.7.1 (his iPhone test: PiP works ✔; boost had no effect; background download not faster): boost = `player.audio.volume`
  100–200 (VLC soft gain, float_mixer is in VLCKit; the `equalizer` filter is NOT in VLCKit iOS → 1.6/1.7.0 boost did nothing);
  volume swipe continues above iPhone max into boost (hint "🔊 150% boost"), side button down resets boost.
  KeepAwake now starts on willResignActive (iOS refuses to START audio from the background – why 1.6.1 failed on device;
  the simulator does not suspend apps so simtest could not show it); stop() no longer deactivates the session. iOS 18 simtest needs a long first launch on fresh runner images
  (now waits for "list live:"). Next: his feedback on 1.7.1 boost + background download on the real iPhone.
- 2026-11-27: his iPhone test – PiP works. vlc4 MERGED into `main` (1.7.1); work on `main` from now on (vlc4 = same).
- Not verifiable in the simulator: real audio volume swipe, real server streams.
