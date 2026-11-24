#!/bin/bash
# Runs the app in the iPhone simulator against test/mock.js and takes screenshots.
# Usage: test/simtest.sh <path to AlnurIPTV.app>
set -u
APP="$1"; BID=com.alnur.iptvplayer
OUT=simout; mkdir -p $OUT
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys; d=json.load(sys.stdin)['devices']
import os
want=os.environ.get('SIM_OS','')
keys=sorted([k for k in d if 'iOS' in k and want in k]) or sorted([k for k in d if 'iOS' in k])
c=[x for k in keys for x in d[k] if x['name'].startswith('iPhone') and 'Pro' in x['name'] and 'Max' not in x['name']]
print(c[-1]['udid'], file=sys.stdout)")
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
if [ "${MODE:-full}" = glass ]; then
  # iOS 26 simulator (Liquid Glass) is slow on Intel: just screenshots of the player controls
  run g1_login 120 -uitest_reset YES -uitest_login "$LOGIN"; stop
  run g2_landscape 60 -uitest_play live:1001 -uitest_keep_controls YES -uitest_sound_panel YES
  sleep 2; stop
  run g3_portrait 60 -uitest_play live:1004 -uitest_keep_controls YES -uitest_portrait_after 30 -uitest_sound_panel YES
  stop
  run g4_movie 60 -uitest_play movie:5000 -uitest_keep_controls YES; stop
  sleep 1; cp "$LOG" $OUT/app.log; echo "glass screenshots done"; exit 0
fi
# first launch on a fresh simulator can take very long: wait until the app has logged in (max 3 min)
echo "=== 01_live: -uitest_reset YES -uitest_login $LOGIN"; mark "01_live: first launch"
xcrun simctl launch "$UDID" $BID -uitest_reset YES -uitest_login "$LOGIN" >/dev/null
for i in $(seq 1 90); do grep -q "list live:" "$LOG" 2>/dev/null && break; sleep 2; done
sleep 3; xcrun simctl io "$UDID" screenshot "$OUT/01_live.png" >/dev/null 2>&1; stop
run 01b_search 10 -uitest_search Gujarati; stop
run 02_movies 10 -uitest_tab movie; stop
run 03_series_detail 10 -uitest_tab series -uitest_open series:700; stop
run 04a_controls 3 -uitest_play live:1001 -uitest_next_after 19
sleep 11; xcrun simctl io "$UDID" screenshot "$OUT/04_play_interlaced.png" >/dev/null 2>&1
sleep 14; xcrun simctl io "$UDID" screenshot "$OUT/05_after_next.png" >/dev/null 2>&1; stop
run 06_play_ac3 14 -uitest_play live:1000; stop
run 06b_portrait 9 -uitest_play live:1000 -uitest_portrait_after 6; stop
run 07_play_hevc 14 -uitest_play live:1002; stop
run 07x_sound_set 16 -uitest_sound 180 -uitest_play live:1000; stop
run 07y_sound_kept 16 -uitest_play live:1004; stop
run 07z_sound_reset 6 -uitest_sound 100 -uitest_tab live; stop
run 07s_swipes 28 -uitest_play live:1004 -uitest_swipes up,down,down,up,down,down; stop
run 07b_record 10 -uitest_play live:1004 -uitest_rec YES
sleep 10; xcrun simctl io "$UDID" screenshot "$OUT/07c_after_rec.png" >/dev/null 2>&1; stop
run 08_movie_seek 24 -uitest_play movie:5000 -uitest_seekto 100; stop
# Fill = zoom so the picture covers the screen; must be redone after turning the phone
run 08b_fill 16 -uitest_play movie:5000 -uitest_aspect fill -uitest_portrait_after 11; stop
run 08t_taps 18 -uitest_play movie:5001 -uitest_taps right,right,left,hold; stop
# app to home screen while a live channel plays, then back
run 11a_bg_live 12 -uitest_play live:1004
mark "home screen"; xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null; sleep 8
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
run 15_download 40 -uitest_tab library -uitest_download movie:5000
xcrun simctl io "$UDID" screenshot "$OUT/15b_downloads.png" >/dev/null 2>&1; stop
run 16_play_offline 45 -uitest_log YES -uitest_download movie:5000; stop
# slow movie (mock ≈1 MB/s): pause after 3 s, wait 3 s, resume → must continue from the same byte
run 16b_dl_pause 26 -uitest_tab library -uitest_download movie:5001 -uitest_dl_pause 3
xcrun simctl io "$UDID" screenshot "$OUT/16c_dl_running.png" >/dev/null 2>&1; stop
# save the (MKV) download to Photos: VLC re-packs it into MP4 first
xcrun simctl privacy "$UDID" grant photos-add $BID 2>/dev/null || true
run 16d_photos 45 -uitest_tab library -uitest_photos YES -uitest_download movie:5000; stop
run 09_library 8 -uitest_tab library; stop
run 10_settings 6 -uitest_tab settings; stop
run 17_users 25 -uitest_tab settings -uitest_add_user "Bhai|http://iptv-mock.test:8899|bhai|demo"
xcrun simctl io "$UDID" screenshot "$OUT/17b_users.png" >/dev/null 2>&1; stop
# M3U link login: plain playlist (channels + movies, plays) and an Xtream get.php link
run 18_m3u 30 -uitest_tab live -uitest_add_m3u "Playlist|http://iptv-mock.test:8899/playlist.m3u"; stop
run 18b_m3u_xtream 15 -uitest_tab live -uitest_add_m3u "Xt|http://iptv-mock.test:8899/get.php?username=demo&password=demo&type=m3u_plus&output=ts"; stop

sleep 1; cp "$LOG" $OUT/app.log
echo; echo "==== RESULTS"
chk() { if grep -q "$2" $OUT/app.log; then echo "PASS  $1"; else echo "FAIL  $1"; fi; }
chk "login (http, ATS)" "login ok"
if grep -q "App Transport Security" $OUT/app.log; then echo "FAIL  ATS blocked http"; else echo "PASS  no ATS block"; fi
chk "live list" "list live: 300 items"
chk "search finds categories AND channels (empty category hidden)" "search 'Gujarati': 2 categories, 100 items"
chk "movie list" "list movie: 60 items"
chk "interlaced 1080i AC3/MP2 plays" "PLAYING 1001"
chk "next channel after zap (busy 401 retry)" "PLAYING 1004"
chk "AC3 channel plays" "PLAYING 1000"
chk "HEVC channel plays" "PLAYING 1002"
chk "movie plays" "PLAYING 5000"
chk "movie resume point saved (~100s)" "save pos 5000 1[0-9][0-9]/180"
cnt() { grep -c "$1" $OUT/app.log; }
# section of the log for one scenario
part() { sed -n "/=== $1/,/=== [0-9][0-9][a-z_]*:/p" $OUT/app.log; }
part 11a_bg_live > /tmp/p11; part 12a_bg_movie > /tmp/p12
grep -q "PiP: true" /tmp/p11 && echo "PASS  live: home swipe → video continues in PiP window (11b_home.png)" || echo "FAIL  live: PiP did not start"
grep -q "PiP: true" /tmp/p11 && ! grep -q "background: stop" /tmp/p11 && echo "PASS  live: stream kept playing in PiP" || echo "FAIL  live: stream stopped in background"
grep -q "PiP stop (app back)" /tmp/p11 && echo "PASS  live: back to app → PiP closes, player continues" || echo "FAIL  live: PiP not closed on return"
grep -q "PiP: true" /tmp/p12 && echo "PASS  movie: home swipe → PiP" || echo "FAIL  movie: PiP did not start"
{ grep -q "PiP: true" /tmp/p12 || grep -A3 "foreground: reopen 5000" /tmp/p12 | grep -q "open movie 5000 .*start=[1-9]"; } && echo "PASS  movie: back from home continues at same time" || echo "FAIL  movie: back from home resume"
grep -q "recording saved .* bytes=[1-9]" $OUT/app.log && echo "PASS  Rec: recording file saved ($(grep -o 'recording saved.*' $OUT/app.log | head -1))" || echo "FAIL  Rec: no recording file"
grep -q "download done movie:5000 bytes=[1-9]" $OUT/app.log && echo "PASS  Download: movie saved ($(grep -o 'download done.*' $OUT/app.log | head -1))" || echo "FAIL  Download: not saved"
P=$(grep -o 'download paused movie:5001 at [0-9]*' $OUT/app.log | head -1 | grep -o '[0-9]*$')
R=$(grep -o 'download resume movie:5001 (normal) from [0-9]*' $OUT/app.log | head -1 | grep -o '[0-9]*$')
[ -n "$P" ] && [ "${P:-0}" -gt 0 ] && echo "PASS  Download pause at $P bytes" || echo "FAIL  Download pause ($(grep -o 'test: pause.*' $OUT/app.log | head -1))"
[ -n "$R" ] && [ "${R:-0}" -gt 0 ] && echo "PASS  Download resume continues from $R bytes (not from 0)" || echo "FAIL  Download resume ($(grep -o 'download resume.*' $OUT/app.log | head -1))"
grep -q "test: still" $OUT/app.log && S=$(grep -o 'test: still [0-9]*' $OUT/app.log | head -1 | grep -o '[0-9]*$') && [ "$S" = "$P" ] && echo "PASS  Download really stops while paused" || echo "FAIL  Download kept going while paused (paused $P, after 3 s ${S:-?})"
grep -q "download done movie:5001 bytes=8221381" $OUT/app.log && echo "PASS  Download after resume complete (8221381 bytes, file intact)" || echo "FAIL  Download after resume ($(grep -o 'download done movie:5001.*\|download error movie:5001.*\|download short.*' $OUT/app.log | head -2))"
grep -q "download progress movie:5001 .* MB/s" $OUT/app.log && echo "PASS  Download speed shown ($(grep -o 'download progress movie:5001.*' $OUT/app.log | tail -1))" || echo "FAIL  Download speed"
grep -q "photos saved=true" $OUT/app.log && echo "PASS  Save to Photos (MKV re-packed to MP4: $(grep -o 'remux finished.*' $OUT/app.log | head -1))" || echo "FAIL  Save to Photos ($(grep -o 'photos.*\|remux.*' $OUT/app.log | head -4 | tr '\n' ' '))"
sed -n "/=== 18_m3u:/,/=== 18b/p" $OUT/app.log > /tmp/m3.txt
grep -q "m3u playlist: 3 channels, 1 movies" /tmp/m3.txt && grep -q 'cats=\["M3U News", "M3U Sports"\]' /tmp/m3.txt && echo "PASS  M3U link login: 3 channels in 2 groups + 1 movie" || echo "FAIL  M3U login ($(grep -o 'm3u.*\|add m3u.*' /tmp/m3.txt | head -3 | tr '\n' ' '))"
grep -q "PLAYING 1 " /tmp/m3.txt && echo "PASS  M3U channel plays (direct playlist link)" || echo "FAIL  M3U channel did not play ($(grep -o 'error.*\|FAIL.*' /tmp/m3.txt | head -2 | tr '\n' ' '))"
grep -q "after switch: current=" /tmp/m3.txt && echo "PASS  switched back to the first user after the M3U test" || echo "FAIL  switch back after M3U"
sed -n "/=== 18b_m3u_xtream/,\$p" $OUT/app.log | grep -q "m3u link is an Xtream account → Xtream login" && sed -n "/=== 18b_m3u_xtream/,\$p" $OUT/app.log | grep -q "login ok" && echo "PASS  M3U get.php link → full Xtream login" || echo "FAIL  M3U Xtream link"
grep -q "open movie 5000 LOCAL-FILE" $OUT/app.log && grep -A3 "open movie 5000 LOCAL-FILE" $OUT/app.log | grep -q "PLAYING 5000" && echo "PASS  Download: plays offline from the iPhone" || echo "FAIL  Download: offline play"
sed -n "/=== 07s_swipes/,/=== 07b/p" $OUT/app.log | grep -o "middle swipe.*\|player closed.*\|player: to.*" > /tmp/sw.txt
EXP="middle swipe up landscape=true|middle swipe down landscape=true|middle swipe down landscape=true|player: to portrait|middle swipe up landscape=false|player: to landscape|middle swipe down landscape=true|player: to portrait|middle swipe down landscape=false|player closed 1004|player closed 1004"
GOT=$(grep -v "^$" /tmp/sw.txt | tr '\n' '|' | sed 's/|$//')
[ "$GOT" = "$EXP" ] && echo "PASS  middle swipe: up=zoom/full screen, down=unzoom/upright/close" || { echo "FAIL  middle swipe"; echo "   got: $GOT"; }
sed -n "/=== 08t_taps/,/=== 1[0-9a-z_]*:/p" $OUT/app.log > /tmp/tp.txt
grep -q "double tap right +10 (total 10)" /tmp/tp.txt && grep -q "double tap right +10 (total 20)" /tmp/tp.txt && grep -q "double tap left -10 (total -10)" /tmp/tp.txt && echo "PASS  double tap: right +10 (adds up to +20), left -10" || echo "FAIL  double tap"
grep -q "rate 2.0" /tmp/tp.txt && grep -q "rate 1.0" /tmp/tp.txt && echo "PASS  hold right: 2x speed, back to normal on release" || echo "FAIL  hold 2x"
B=$(grep -o "buffer 5000: time [0-9]*s, loaded to [0-9]*s (ahead [0-9]*s)" $OUT/app.log | tail -1)
echo "$B" | awk '{ split($4,t,"s"); split($7,l,"s"); exit !(l[1] > t[1] + 2) }' && echo "PASS  movie grey buffer bar ahead of play ($B)" || echo "FAIL  buffer bar ($B)"
sed -n "/=== 08_movie_seek/,/=== 08b/p" $OUT/app.log | grep -A3 "test: seek to" | grep -q "buffer base after seek" && echo "PASS  grey buffer restarts from the new point after a seek ($(sed -n '/=== 08_movie_seek/,/=== 08b/p' $OUT/app.log | grep -o 'buffer base after seek.*' | tail -1))" || echo "FAIL  buffer after seek ($(sed -n '/=== 08_movie_seek/,/=== 08b/p' $OUT/app.log | grep -o 'buffer.*' | tail -3 | tr '\n' ' '))"
F=$(sed -n "/=== 08b_fill/,/=== /p" $OUT/app.log | grep -o "aspect Fill view=.*" | tr '\n' ' ')
echo "$F" | grep -q "zoom=[1-9]" && [ $(echo "$F" | grep -o "aspect Fill" | wc -l) -ge 2 ] && echo "PASS  Fill zooms the picture and is redone after rotating ($F)" || echo "FAIL  Fill ($F)"
grep -q "users now: \[\"demo\", \"Bhai\"\] current=Bhai" $OUT/app.log && grep -q "after switch: current=demo" $OUT/app.log && echo "PASS  second user added, switch back works" || echo "FAIL  users ($(grep -o 'users now.*\|after switch.*' $OUT/app.log | tr '\n' ' '))"
sed -n "/=== 07x_sound_set/,/=== 07y/p" $OUT/app.log > /tmp/s1.txt; sed -n "/=== 07y_sound_kept/,/=== 07z/p" $OUT/app.log > /tmp/s2.txt
grep -q 'sound: boost 180% = +8.5 dB (player pre-amp now 8.5 dB)' /tmp/s1.txt && grep -q "PLAYING 1000" /tmp/s1.txt && echo "PASS  sound boost 180%: +8.5 dB set in VLC (read back from the player), channel plays" || echo "FAIL  sound filters ($(grep -o 'sound:.*' /tmp/s1.txt | head -1))"
grep -q 'sound: boost 180%' /tmp/s2.txt && grep -q "PLAYING 1004" /tmp/s2.txt && echo "PASS  sound settings kept after app restart" || echo "FAIL  sound settings not kept"
grep -q "player: to portrait" $OUT/app.log && echo "PASS  X in landscape turns to portrait (see 06b_portrait.png)" || echo "FAIL  to portrait"
grep -q "player closed 1000" $OUT/app.log && echo "PASS  X closes the player" || echo "FAIL  X does not close the player"
grep -q "PLAYING 1003" $OUT/app.log && echo "PASS  close player + open other channel" || echo "FAIL  close + reopen"
grep -q "PLAYING 1006" $OUT/app.log && echo "PASS  close a stalled stream + open other channel" || echo "FAIL  stalled close + reopen"
if grep -q "MAIN HANG" $OUT/app.log; then echo "FAIL  app froze:"; grep -o "MAIN HANG.*" $OUT/app.log; else echo "PASS  app never froze (main thread watchdog)"; fi
grep -c "GIVE UP" $OUT/app.log | sed 's/^/give-ups: /'
