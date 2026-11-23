// Mock Xtream server for the simulator test (behaves like the real one: picky user-agents, 1 connection).
const http = require('http'), fs = require('fs'), path = require('path');
const M = (f) => path.join(__dirname, 'media', f);
const now = Math.floor(Date.now() / 1000);
const R = {
  '': { user_info: { auth: 1, status: 'Active', username: 'demo', exp_date: String(now + 86400 * 200), active_cons: '0', max_connections: '1', allowed_output_formats: ['m3u8', 'ts', 'rtmp'] }, server_info: {} },
  get_live_categories: [{ category_id: '1', category_name: 'India | Gujarati' }, { category_id: '2', category_name: 'Sports' }],
  get_live_streams: Array.from({ length: 300 }, (_, i) => ({ num: i + 1, name: (i % 3 == 0 ? 'Star Gujarati ' : i % 3 == 1 ? 'Sony Sports ' : 'Aaj Tak ') + (i + 1), stream_id: 1000 + i, stream_icon: i < 3 ? 'http://iptv-mock.test:8899/logo.png' : '', category_id: String(i % 3 == 1 ? 2 : 1) })),
  get_vod_categories: [{ category_id: '10', category_name: 'Bollywood' }, { category_id: '11', category_name: 'Hollywood' }],
  get_vod_streams: Array.from({ length: 60 }, (_, i) => ({ name: 'Movie Title ' + (i + 1), stream_id: 5000 + i, stream_icon: '', rating: '7.' + (i % 9), category_id: i % 2 ? '10' : '11', container_extension: 'mkv', added: String(now - i * 1000) })),
  get_series_categories: [{ category_id: '20', category_name: 'Drama' }],
  get_series: Array.from({ length: 20 }, (_, i) => ({ name: 'Series ' + (i + 1), series_id: 700 + i, cover: '', rating: 8, category_id: '20', last_modified: String(now - i) })),
  get_vod_info: { info: { name: 'Movie Title', plot: 'A test movie plot.', genre: 'Drama', rating: '7.5', duration: '00:03:00', cast: 'Actor One, Actor Two', director: 'Some Director' } },
  get_series_info: { info: { name: 'Series 1', plot: 'Series plot', cover: '' }, episodes: { '1': [{ id: '9001', episode_num: 1, title: 'Pilot', container_extension: 'ts', info: { duration_secs: 30 } }, { id: '9002', episode_num: 2, title: 'Two', container_extension: 'ts', info: {} }], '2': [{ id: '9003', episode_num: 1, title: 'S2', container_extension: 'ts', info: {} }] } },
};
let active = 0, lastClose = 0, lastSid = '';
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

http.createServer((q, s) => {
  const ua = q.headers['user-agent'] || '';
  const u = new URL(q.url, 'http://x');
  if (u.pathname === '/logo.png') { s.writeHead(200, { 'Content-Type': 'image/png' }); return s.end(fs.readFileSync(path.join(__dirname, 'logo.png'))); }
  if (u.pathname.endsWith('player_api.php')) {
    if (!/MAG200|Dalvik/.test(ua)) { log('api 503 bad-UA', ua.slice(0, 20)); s.writeHead(503); return s.end('503'); }
    if (u.searchParams.get('password') !== 'demo') { s.setHeader('content-type', 'application/json'); return s.end(JSON.stringify({ user_info: { auth: 0 } })); }
    const a = u.searchParams.get('action') || '';
    log('api', a || 'login', ua.slice(0, 12));
    s.setHeader('content-type', 'application/json'); return s.end(JSON.stringify(R[a] ?? []));
  }
  const m = u.pathname.match(/^\/(live|movie|series)\/demo\/demo\/(\d+)\.(\w+)$/);
  if (!m) { s.writeHead(404); return s.end(); }
  const [, kind, sid] = m;
  if (!ua.startsWith('VLC/')) { log('stream', sid, '401 bad-UA', ua.slice(0, 20)); s.writeHead(401); return s.end(); }
  const busy = (active > 0 || Date.now() - lastClose < 1000) && lastSid !== sid;
  if (busy) { log('stream', sid, '401 busy'); s.writeHead(401); return s.end(); }
  lastSid = sid;
  const f = kind === 'movie' ? 'movie.mkv' : sid === '1000' ? 'ac3.ts' : sid === '1001' ? 'interlaced.ts' : sid === '1002' ? 'hevc.ts' : 'live.ts';
  active++; let done = false; const rel = () => { if (!done) { done = true; active--; lastClose = Date.now(); log('stream', sid, 'closed'); } };
  s.on('close', rel);
  const st = fs.statSync(M(f));
  if (kind !== 'live') {
    const range = q.headers.range;
    log('stream', sid, 'OK file', f, range || '');
    if (range) { const [a, e] = range.replace('bytes=', '').split('-'); const start = +a, end = e ? +e : st.size - 1; s.writeHead(206, { 'Content-Range': `bytes ${start}-${end}/${st.size}`, 'Accept-Ranges': 'bytes', 'Content-Length': end - start + 1, 'Content-Type': 'video/x-matroska' }); return fs.createReadStream(M(f), { start, end }).pipe(s); }
    s.writeHead(200, { 'Content-Length': st.size, 'Accept-Ranges': 'bytes', 'Content-Type': 'video/x-matroska' }); return fs.createReadStream(M(f)).pipe(s);
  }
  log('stream', sid, 'OK live', f);
  const buf = fs.readFileSync(M(f)), bps = buf.length / 30, chunk = 188 * 100; let pos = Math.min(buf.length, Math.floor(bps * 2)), t;
  s.writeHead(200, { 'Content-Type': 'video/mp2t' }); s.write(buf.subarray(0, pos));
  const send = () => { if (s.destroyed) return; const n = Math.min(chunk, buf.length - pos); s.write(buf.subarray(pos, pos + n)); pos += n; if (pos >= buf.length) pos = 0; t = setTimeout(send, n / bps * 1000); };
  if (sid === '1005') { log('stream 1005 will STALL'); setTimeout(() => clearTimeout(t), 3000); }
  send(); s.on('close', () => clearTimeout(t));
}).listen(8899, '127.0.0.1', () => log('mock on 8899'));
