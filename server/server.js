#!/usr/bin/env node
// Snapper upload server: no dependencies, Node 18+.
//   PORT=8787 TOKEN=secret BASE_URL=https://snaps.example.com node server.js
// App setting "Upload URL":  https://snaps.example.com/u    (file name is appended)
//
//   PUT    /u/<name>         store a file, reply {"url": ".../s/<id>"}
//          headers (optional): X-Snapper-Password, X-Snapper-Expires-Hours, X-Snapper-Burn: 1
//   GET    /s/<id>           share page (password form, comments)
//   POST   /s/<id>/unlock    password form
//   POST   /s/<id>/comments  add a comment
//   GET    /f/<id>           the raw file
//   DELETE /f/<id>           delete (needs TOKEN)
//   GET    /library          list of uploads (needs ?token= when TOKEN is set)
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 8787);
const TOKEN = process.env.TOKEN || '';
const DATA = path.resolve(process.env.DATA_DIR || path.join(__dirname, 'data'));
const MAX_BYTES = 500 * 1024 * 1024;
const BURN_GRACE_MS = 60 * 1000;   // a self-destructing file stays reachable this long after its first view
fs.mkdirSync(DATA, { recursive: true });

// Secret for unlock cookies, kept across restarts.
const SECRET_FILE = path.join(DATA, '.secret');
if (!fs.existsSync(SECRET_FILE)) fs.writeFileSync(SECRET_FILE, crypto.randomBytes(32).toString('hex'), { mode: 0o600 });
const SECRET = fs.readFileSync(SECRET_FILE, 'utf8').trim();

// Snapper logo badge (128 px PNG), served at /brand.png and used as the favicon.
const BRAND_PNG = Buffer.from('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', 'base64');

const TYPES = { '.png': 'image/png', '.jpg': 'image/jpeg', '.gif': 'image/gif', '.mp4': 'video/mp4', '.webp': 'image/webp', '.mov': 'video/quicktime' };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const base = (req) => process.env.BASE_URL || `http://${req.headers.host}`;

function authorized(req, url) {
  if (!TOKEN) return true;
  const header = req.headers.authorization || '';
  const given = header.startsWith('Bearer ') ? header.slice(7) : url.searchParams.get('token') || '';
  const a = Buffer.from(given), b = Buffer.from(TOKEN);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// ---------- storage ----------

const validId = (id) => /^[a-f0-9]{16}$/.test(id);
const metaPath = (id) => path.join(DATA, `${id}.meta.json`);

function readMeta(id) {
  try { return JSON.parse(fs.readFileSync(metaPath(id), 'utf8')); } catch { return {}; }
}
function writeMeta(id, meta) {
  fs.writeFileSync(metaPath(id), JSON.stringify(meta, null, 2));
}

function findFile(id) {
  if (!validId(id)) return null;
  const hit = fs.readdirSync(DATA).find((f) => f.startsWith(id + '-'));
  return hit ? { file: path.join(DATA, hit), name: hit.slice(17) } : null;
}

function removeUpload(id) {
  const hit = findFile(id);
  if (hit) fs.rmSync(hit.file, { force: true });
  fs.rmSync(metaPath(id), { force: true });
}

/// null when the upload exists and is still valid; otherwise an HTTP status to answer with.
function gone(id) {
  const hit = findFile(id);
  if (!hit) return 404;
  const meta = readMeta(id);
  if (meta.expires && Date.now() > meta.expires) { removeUpload(id); return 410; }
  if (meta.burnAt && Date.now() > meta.burnAt) { removeUpload(id); return 410; }
  return null;
}

// ---------- passwords ----------

function hashPassword(pw) {
  const salt = crypto.randomBytes(16).toString('hex');
  return `${salt}:${crypto.scryptSync(pw, salt, 32).toString('hex')}`;
}
function checkPassword(pw, stored) {
  const [salt, hash] = String(stored).split(':');
  if (!salt || !hash) return false;
  const a = crypto.scryptSync(pw, salt, 32), b = Buffer.from(hash, 'hex');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
const unlockToken = (id) => crypto.createHmac('sha256', SECRET).update(id).digest('hex').slice(0, 32);
function cookies(req) {
  const out = {};
  for (const part of (req.headers.cookie || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}
function unlocked(req, id, meta) {
  if (!meta.password) return true;
  const given = Buffer.from(cookies(req)[`snp_${id}`] || ''), want = Buffer.from(unlockToken(id));
  return given.length === want.length && crypto.timingSafeEqual(given, want);
}

// ---------- helpers ----------

function send(res, code, body, type = 'text/plain; charset=utf-8', extra = {}) {
  res.writeHead(code, { 'Content-Type': type, 'X-Content-Type-Options': 'nosniff', ...extra });
  res.end(body);
}

function readForm(req, limit = 16 * 1024) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > limit) { reject(new Error('too large')); req.destroy(); } });
    req.on('end', () => resolve(new URLSearchParams(body)));
    req.on('error', reject);
  });
}

const page = (title, inner) => `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)} · Snapper</title><link rel="icon" href="/brand.png">
<style>body{margin:0;min-height:100vh;background:radial-gradient(1200px 600px at 50% -10%,#2a2a6e 0%,#14142f 55%,#0d0d1f 100%);color:#eee;font:15px -apple-system,system-ui,sans-serif}
header{display:flex;align-items:center;gap:10px;padding:16px 22px}header img{width:28px;height:28px}
header b{font:700 18px ui-rounded,-apple-system,system-ui,sans-serif;letter-spacing:.2px}
footer{color:#8b8bb5;font-size:12px;text-align:center;padding:24px}
main{padding:24px;max-width:1000px;margin:0 auto;text-align:center}img,video{max-width:100%;max-height:75vh;border-radius:10px}
a{color:#7cc4ff}.meta{color:#999;font-size:13px}form{margin:16px auto;max-width:520px;text-align:left}
input,textarea,button{font:inherit;border-radius:10px;border:1px solid #2e2e5c;background:rgba(255,255,255,.06);color:#eee;padding:9px 11px;box-sizing:border-box}
textarea{width:100%;min-height:70px}button{background:#5b5bd6;border-color:#5b5bd6;cursor:pointer;font-weight:600}
img,video{box-shadow:0 20px 60px rgba(0,0,0,.45)}
.c{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.08);border-radius:12px;padding:10px 12px;margin:8px auto;max-width:520px;text-align:left}
.c b{color:#c9c9ff}.c small{color:#8b8bb5;margin-left:6px}</style>
<header><img src="/brand.png" alt=""><b>Snapper</b></header><main>${inner}</main><footer>Shared with Snapper</footer>`;

function sharePage(id, hit, meta) {
  const raw = `/f/${id}`;
  const lower = hit.name.toLowerCase();
  const isVideo = lower.endsWith('.mp4') || lower.endsWith('.mov');
  const media = isVideo ? `<video src="${raw}" controls autoplay loop muted playsinline></video>` : `<img src="${raw}" alt="${esc(hit.name)}">`;
  const notes = [];
  if (meta.expires) notes.push(`expires ${new Date(meta.expires).toUTCString()}`);
  if (meta.burn) notes.push('this link stops working shortly after it is first opened');
  const comments = (meta.comments || []).map((c) =>
    `<div class="c"><b>${esc(c.name || 'Someone')}</b><small>${esc(new Date(c.at).toLocaleString('en-GB'))}</small><div>${esc(c.text)}</div></div>`).join('');
  return page(hit.name, `${media}
<p>${esc(hit.name)} · <a href="${raw}" download="${esc(hit.name)}">Download</a></p>
${notes.length ? `<p class="meta">${esc(notes.join(' · '))}</p>` : ''}
<h3>Comments</h3>${comments || '<p class="meta">No comments yet.</p>'}
<form method="post" action="/s/${id}/comments">
<p><input name="name" placeholder="Your name" maxlength="60" style="width:100%"></p>
<p><textarea name="text" placeholder="Add a comment" maxlength="2000" required></textarea></p>
<p><button>Comment</button></p></form>`);
}

const lockPage = (id, wrong) => page('Password required', `<h2>This link is password protected</h2>
${wrong ? '<p class="meta">That password is not right.</p>' : ''}
<form method="post" action="/s/${id}/unlock"><p><input type="password" name="password" placeholder="Password" autofocus style="width:100%"></p>
<p><button>Open</button></p></form>`);

// ---------- server ----------

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const parts = url.pathname.split('/').filter(Boolean);

    // Upload
    if (req.method === 'PUT' && parts[0] === 'u' && parts.length === 2) {
      if (!authorized(req, url)) return send(res, 401, 'Unauthorized');
      const name = decodeURIComponent(parts[1]).replace(/[^\w.\- ]+/g, '_').slice(0, 120) || 'file';
      const ext = path.extname(name).toLowerCase();
      if (!TYPES[ext]) return send(res, 415, 'Unsupported file type');
      const id = crypto.randomBytes(8).toString('hex');
      const target = path.join(DATA, `${id}-${name}`);
      const meta = { created: Date.now(), comments: [] };
      const pw = req.headers['x-snapper-password'];
      if (pw) meta.password = hashPassword(String(pw));
      const hours = Number(req.headers['x-snapper-expires-hours'] || 0);
      if (hours > 0) meta.expires = Date.now() + Math.min(hours, 24 * 365) * 3600 * 1000;
      if (req.headers['x-snapper-burn'] === '1') meta.burn = true;

      const out = fs.createWriteStream(target, { flags: 'wx' });
      let size = 0, aborted = false;
      req.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_BYTES && !aborted) {
          aborted = true;
          out.destroy();
          fs.unlink(target, () => {});
          send(res, 413, 'Too large');
          req.destroy();
        }
      });
      req.pipe(out);
      out.on('finish', () => {
        if (aborted) return;
        writeMeta(id, meta);
        send(res, 201, JSON.stringify({ url: `${base(req)}/s/${id}` }), 'application/json', { Location: `${base(req)}/s/${id}` });
      });
      out.on('error', () => { if (!aborted) send(res, 500, 'Write failed'); });
      return;
    }

    // Raw file
    if (parts[0] === 'f' && parts.length === 2) {
      const id = parts[1];
      if (req.method === 'DELETE') {
        if (!authorized(req, url)) return send(res, 401, 'Unauthorized');
        if (!findFile(id)) return send(res, 404, 'Not found');
        removeUpload(id);
        return send(res, 204, '');
      }
      if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'Method not allowed');
      const status = gone(id);
      if (status) return send(res, status, status === 410 ? 'This link has expired' : 'Not found');
      const hit = findFile(id), meta = readMeta(id);
      if (!unlocked(req, id, meta)) return send(res, 403, 'Password required');
      if (meta.burn && !meta.burnAt) { meta.burnAt = Date.now() + BURN_GRACE_MS; writeMeta(id, meta); }
      const type = TYPES[path.extname(hit.name).toLowerCase()] || 'application/octet-stream';
      const stat = fs.statSync(hit.file);
      const cache = meta.password || meta.burn || meta.expires ? 'private, no-store' : 'public, max-age=31536000, immutable';
      const range = /bytes=(\d*)-(\d*)/.exec(req.headers.range || '');
      if (range) {
        let start = range[1] === '' ? stat.size - Number(range[2]) : Number(range[1]);
        let end = range[1] !== '' && range[2] !== '' ? Number(range[2]) : stat.size - 1;
        if (isNaN(start) || start < 0) start = 0;
        if (end >= stat.size) end = stat.size - 1;
        if (start > end) return send(res, 416, 'Range not satisfiable', 'text/plain', { 'Content-Range': `bytes */${stat.size}` });
        res.writeHead(206, { 'Content-Type': type, 'X-Content-Type-Options': 'nosniff', 'Cache-Control': cache,
          'Accept-Ranges': 'bytes', 'Content-Range': `bytes ${start}-${end}/${stat.size}`, 'Content-Length': end - start + 1 });
        if (req.method === 'HEAD') return res.end();
        return fs.createReadStream(hit.file, { start, end }).pipe(res);
      }
      res.writeHead(200, { 'Content-Type': type, 'X-Content-Type-Options': 'nosniff', 'Cache-Control': cache,
        'Accept-Ranges': 'bytes', 'Content-Length': stat.size });
      if (req.method === 'HEAD') return res.end();
      return fs.createReadStream(hit.file).pipe(res);
    }

    // Share page, unlock, comments
    if (parts[0] === 's' && (parts.length === 2 || parts.length === 3)) {
      const id = parts[1];
      const status = gone(id);
      if (status) return send(res, status, page('Gone', `<h2>${status === 410 ? 'This link has expired' : 'Not found'}</h2>`), 'text/html; charset=utf-8');
      const hit = findFile(id), meta = readMeta(id);

      if (req.method === 'POST' && parts[2] === 'unlock') {
        const form = await readForm(req);
        if (meta.password && checkPassword(form.get('password') || '', meta.password)) {
          return send(res, 303, '', 'text/plain', {
            Location: `/s/${id}`,
            'Set-Cookie': `snp_${id}=${unlockToken(id)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400`
          });
        }
        return send(res, 401, lockPage(id, true), 'text/html; charset=utf-8');
      }

      if (!unlocked(req, id, meta)) return send(res, 401, lockPage(id, false), 'text/html; charset=utf-8');

      if (req.method === 'POST' && parts[2] === 'comments') {
        const form = await readForm(req);
        const text = (form.get('text') || '').trim().slice(0, 2000);
        if (text) {
          meta.comments = meta.comments || [];
          if (meta.comments.length < 500) {
            meta.comments.push({ name: (form.get('name') || '').trim().slice(0, 60), text, at: Date.now() });
            writeMeta(id, meta);
          }
        }
        return send(res, 303, '', 'text/plain', { Location: `/s/${id}` });
      }

      if (req.method === 'GET' && parts.length === 2) {
        return send(res, 200, sharePage(id, hit, meta), 'text/html; charset=utf-8', { 'Cache-Control': 'no-store' });
      }
      return send(res, 405, 'Method not allowed');
    }

    // Logo
    if (req.method === 'GET' && (url.pathname === '/brand.png' || url.pathname === '/favicon.ico')) {
      return send(res, 200, BRAND_PNG, 'image/png', { 'Cache-Control': 'public, max-age=86400' });
    }

    // Library
    if (req.method === 'GET' && parts[0] === 'library' && parts.length === 1) {
      if (!authorized(req, url)) return send(res, 401, 'Unauthorized');
      const files = fs.readdirSync(DATA).filter((f) => /^[a-f0-9]{16}-/.test(f))
        .map((f) => ({ f, t: fs.statSync(path.join(DATA, f)).mtimeMs })).sort((a, b) => b.t - a.t);
      const cards = files.map(({ f }) => {
        const id = f.slice(0, 16), name = f.slice(17), meta = readMeta(id);
        const lower = name.toLowerCase();
        const thumb = meta.password ? '<div class="lock">🔒</div>'
          : (lower.endsWith('.mp4') || lower.endsWith('.mov')) ? `<video src="/f/${id}" muted preload="metadata"></video>`
          : `<img src="/f/${id}" loading="lazy" alt="">`;
        const tags = [meta.password ? 'password' : '', meta.expires ? 'expires' : '', meta.burn ? 'self-destruct' : '',
          (meta.comments || []).length ? `${meta.comments.length} comments` : ''].filter(Boolean).join(' · ');
        return `<a class="c" href="/s/${id}">${thumb}<span>${esc(name)}</span><em>${esc(tags)}</em></a>`;
      }).join('');
      return send(res, 200, `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Snapper library</title><link rel="icon" href="/brand.png">
<style>body{margin:0;background:#0f0f24;color:#eee;font:14px -apple-system,system-ui;padding:24px}
h1{font:700 20px ui-rounded,-apple-system,system-ui;display:flex;align-items:center;gap:10px}h1 img{width:30px;height:30px}.g{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:14px}
.c{background:#1b1b1b;border-radius:10px;overflow:hidden;color:inherit;text-decoration:none}
.c img,.c video,.lock{width:100%;height:150px;object-fit:cover;display:block}.lock{display:grid;place-items:center;font-size:40px}
.c span{display:block;padding:8px 10px 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.c em{display:block;padding:0 10px 8px;color:#888;font-size:12px;font-style:normal}</style>
<h1><img src="/brand.png" alt="">Snapper library (${files.length})</h1><div class="g">${cards || 'Nothing uploaded yet.'}</div>`, 'text/html; charset=utf-8');
    }

    send(res, 404, 'Not found');
  } catch (err) {
    if (!res.headersSent) send(res, 500, 'Server error');
  }
});

// Sweep expired and burned uploads every 10 minutes.
setInterval(() => {
  for (const f of fs.readdirSync(DATA)) {
    const m = /^([a-f0-9]{16})\.meta\.json$/.exec(f);
    if (m) gone(m[1]);
  }
}, 10 * 60 * 1000).unref();

server.listen(PORT, () => console.log(`Snapper server on :${PORT}, data in ${DATA}${TOKEN ? '' : '  (no TOKEN set: anyone can upload)'}`));
