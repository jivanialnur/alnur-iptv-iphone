# Alnur IPTV – iPhone app (planned, nothing built yet)

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
- Installing needs either an **Apple Developer account ($99/yr, TestFlight – recommended)** or a free Apple ID with Sideloadly
  (re-install every 7 days). He has NOT decided yet ("pehla Windows nu kaam, iPhone pachhi") – ask before building.
- Player: AVPlayer can't play raw MPEG-TS live / AC3 interlaced well → use **MobileVLCKit** (VLCKit via CocoaPods/SPM).
  Streams need UA `VLC/3.0.21 LibVLC/3.0.21`; API needs MAG/Dalvik-like UA (see alnur-iptv-windows/CLAUDE.md "IPTV server facts").
- Server allows **1 connection at a time** (shared with PC and tablet).
- Suggested approach: SwiftUI app (native tabs/lists as in his screenshot) + VLCKit player screen; reuse the Xtream API logic
  from `alnur-iptv-windows/renderer/app.js` (probe UAs, list caching, favourites, resume points).
