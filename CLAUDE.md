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
  Recently Added; empty categories hidden, counts shown); search shows matching categories AND items.
- Work is on branch `app-v1` (17/17 simtest checks pass); not yet merged to `main`. 1.0.1 installed on his iPhone via Sideloadly.
- Not verifiable in the simulator: real audio volume swipe, real server streams.
