#!/bin/bash
# Runs the app in the iPhone simulator against test/mock.js and takes screenshots.
# Usage: test/simtest.sh <path to AlnurIPTV.app>
set -u
APP="$1"; BID=com.alnur.iptvplayer
OUT=simout; mkdir -p $OUT
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys; d=json.load(sys.stdin)['devices']
c=[x for k,v in d.items() if 'iOS' in k for x in v if x['name'].startswith('iPhone') and 'Pro' in x['name'] and 'Max' not in x['name']]
print(c[-1]['udid'])")
echo "simulator $UDID"
xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$UDID" $BID data)
mkdir -p "$DATA/Documents"; LOG="$DATA/Documents/iptv.log"; : > "$LOG"
mark() { echo "$(date +%s).000 === $*" >> "$LOG"; }

run() { # name seconds args... ; screenshot at the end
  local name=$1 secs=$2; shift 2
  echo "=== $name: $*"; mark "$name: $*"
  xcrun simctl launch "$UDID" $BID "$@" >/dev/null
  sleep "$secs"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
}
stop() { xcrun simctl terminate "$UDID" $BID 2>/dev/null; sleep 2; }

LOGIN="http://iptv-mock.test:8899|demo|demo"
run 01_live 25 -uitest_reset YES -uitest_login "$LOGIN"; stop
run 02_movies 10 -uitest_tab movie; stop
run 03_series_detail 10 -uitest_tab series -uitest_open series:700; stop
run 04a_controls 3 -uitest_play live:1001 -uitest_next_after 19
sleep 11; xcrun simctl io "$UDID" screenshot "$OUT/04_play_interlaced.png" >/dev/null 2>&1
sleep 14; xcrun simctl io "$UDID" screenshot "$OUT/05_after_next.png" >/dev/null 2>&1; stop
run 06_play_ac3 14 -uitest_play live:1000; stop
run 07_play_hevc 14 -uitest_play live:1002; stop
run 08_movie_seek 24 -uitest_play movie:5000 -uitest_seekto 100; stop
# app to home screen while a live channel plays, then back
run 11a_bg_live 12 -uitest_play live:1004
mark "home screen"; xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null; sleep 6
xcrun simctl io "$UDID" screenshot "$OUT/11b_home.png" >/dev/null 2>&1
mark "back to app"; xcrun simctl launch "$UDID" $BID >/dev/null; sleep 12
xcrun simctl io "$UDID" screenshot "$OUT/11c_back_live.png" >/dev/null 2>&1; stop
# same with a movie (must continue from where it was)
run 12a_bg_movie 14 -uitest_play movie:5000
mark "home screen"; xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null; sleep 6
mark "back to app"; xcrun simctl launch "$UDID" $BID >/dev/null; sleep 12
xcrun simctl io "$UDID" screenshot "$OUT/12b_back_movie.png" >/dev/null 2>&1; stop
# close the player (X) and open another channel
run 13a_after_close 12 -uitest_play live:1000 -uitest_close_after 10 -uitest_reopen live:1003
sleep 9
xcrun simctl io "$UDID" screenshot "$OUT/13_close_reopen.png" >/dev/null 2>&1; stop
# close while the server has stopped sending (stalled connection), then open another
run 14_stall_close 24 -uitest_play live:1005 -uitest_close_after 9 -uitest_reopen live:1006
xcrun simctl io "$UDID" screenshot "$OUT/14_after_stall.png" >/dev/null 2>&1; stop
run 09_library 8 -uitest_tab library; stop
run 10_settings 6 -uitest_tab settings; stop

sleep 1; cp "$LOG" $OUT/app.log
echo; echo "==== RESULTS"
chk() { if grep -q "$2" $OUT/app.log; then echo "PASS  $1"; else echo "FAIL  $1"; fi; }
chk "login (http, ATS)" "login ok"
if grep -q "App Transport Security" $OUT/app.log; then echo "FAIL  ATS blocked http"; else echo "PASS  no ATS block"; fi
chk "live list" "list live: 300 items"
chk "movie list" "list movie: 60 items"
chk "interlaced 1080i AC3/MP2 plays" "PLAYING 1001"
chk "next channel after zap (busy 401 retry)" "PLAYING 1004"
chk "AC3 channel plays" "PLAYING 1000"
chk "HEVC channel plays" "PLAYING 1002"
chk "movie plays" "PLAYING 5000"
chk "movie resume point saved (~100s)" "save pos 5000 1[0-9][0-9]/180"
cnt() { grep -c "$1" $OUT/app.log; }
[ "$(cnt 'background: stop 1004')" -ge 1 ] && [ "$(cnt 'PLAYING 1004')" -ge 3 ] && echo "PASS  live: home screen and back plays again" || echo "FAIL  live: home screen and back"
[ "$(cnt 'foreground: reopen 5000')" -ge 1 ] && grep -A3 "foreground: reopen 5000" $OUT/app.log | grep -q "open movie 5000 .*start=[1-9]" && echo "PASS  movie: back from home continues at same time" || echo "FAIL  movie: back from home resume"
grep -q "player closed 1000" $OUT/app.log && echo "PASS  X closes the player" || echo "FAIL  X does not close the player"
grep -q "PLAYING 1003" $OUT/app.log && echo "PASS  close player + open other channel" || echo "FAIL  close + reopen"
grep -q "PLAYING 1006" $OUT/app.log && echo "PASS  close a stalled stream + open other channel" || echo "FAIL  stalled close + reopen"
if grep -q "MAIN HANG" $OUT/app.log; then echo "FAIL  app froze:"; grep -o "MAIN HANG.*" $OUT/app.log; else echo "PASS  app never froze (main thread watchdog)"; fi
grep -c "GIVE UP" $OUT/app.log | sed 's/^/give-ups: /'
