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
xcrun simctl spawn "$UDID" log stream --style compact --predicate 'eventMessage CONTAINS "[IPTV]"' > $OUT/app.log 2>&1 &
LOGPID=$!
sleep 3

run() { # name seconds args... ; screenshot at the end
  local name=$1 secs=$2; shift 2
  echo "=== $name: $*" | tee -a $OUT/app.log
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
run 09_library 8 -uitest_tab library; stop
run 10_settings 6 -uitest_tab settings; stop

kill $LOGPID 2>/dev/null
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
grep -c "GIVE UP" $OUT/app.log | sed 's/^/give-ups: /'
