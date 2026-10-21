// zen-router v2: OpenCode Zen free-tier relay.
// Plain HTTP in from magpie's zen-free plugin, HTTPS out through the local
// mihomo (group ZEN, port 7900). One egress IP per conversation while it is
// healthy (prompt cache stays warm), least-used IP across conversations,
// transparent retry on another IP when one is refused or out of quota.
import http from 'node:http';
import net from 'node:net';
import tls from 'node:tls';
import fs from 'node:fs';
import { createHash } from 'node:crypto';

const DIR = process.env.ZEN_IP_HOME || ((process.env.USERPROFILE || process.env.HOME || '.') + '\\.zen-ip');
const META = JSON.parse(fs.readFileSync(DIR + '/meta.json', 'utf8'));
const SECRET = META.secret;
const API = 'http://127.0.0.1:9099';
const EGRESS = JSON.parse(fs.readFileSync(DIR + '/node-egress.json', 'utf8'));
const STATE_PATH = DIR + '/router-state.json';
const LOG_PATH = DIR + '/zen-router.log';
const UPSTREAM = { host: 'opencode.ai', port: 443, base: '/inference/v1' };
const PROXY = { host: '127.0.0.1', port: 7900 };
const PROBE_PROXY = { host: '127.0.0.1', port: 7901 };
const QUOTA_COOLDOWN_MS = 30 * 60 * 1000;
const BLOCK_COOLDOWN_MS = 12 * 60 * 60 * 1000;
const MAX_ATTEMPTS = 6;
const AFFINITY_TTL = 2 * 60 * 60 * 1000;
const AFFINITY_CAP = 400;
const QUOTA_RE = /FreeTierError|third[-\s]?party|第三方|额度|quota|rate.?limit|too many requests|only be used from within|ip[_ -]?limit|not available in your country|permission_error/i;

const log = (msg) => { const line = new Date().toISOString() + ' ' + msg; try { fs.appendFileSync(LOG_PATH, line + '\n'); } catch {} };

const nodes = Object.values(EGRESS.nodes).filter((n) => n.delay != null && n.ip);
const byIp = new Map();
for (const n of nodes) { if (!byIp.has(n.ip)) byIp.set(n.ip, []); byIp.get(n.ip).push(n); }

let VALID = {};
try { VALID = JSON.parse(fs.readFileSync(DIR + '/ip-valid.json', 'utf8')).ips || {}; } catch {}

let state = { startedAt: new Date().toISOString(), current: null, currentIp: null, ips: {}, sessions: {}, modelCache: null, events: [] };
try { const saved = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); state = { ...state, ...saved, startedAt: new Date().toISOString() }; } catch {}
state.sessions ||= {};
function saveState() { try { fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 1)); } catch {} }
function ipState(ip) {
  if (!state.ips[ip]) state.ips[ip] = { requests: 0, tokens: 0, failures: 0, exhaustedUntil: 0, blockedUntil: 0, ewma: 0, lastOk: 0, lastError: '', lastAt: 0 };
  return state.ips[ip];
}
let dirty = false;
setInterval(() => { if (dirty) { dirty = false; saveState(); } }, 3000).unref();
function event(type, message) {
  state.events.push({ t: new Date().toISOString(), type, message });
  if (state.events.length > 60) state.events.splice(0, state.events.length - 60);
  log(type + ' ' + message);
}

// ---------- mihomo ----------
async function api(path, opt = {}) {
  const r = await fetch(API + path, { ...opt, headers: { authorization: 'Bearer ' + SECRET, 'content-type': 'application/json' } });
  const text = await r.text();
  if (r.status >= 400) throw new Error('mihomo ' + r.status + ' ' + text.slice(0, 120));
  return text;
}
let zenLock = Promise.resolve();
function withZenLock(fn) { const run = zenLock.then(fn, fn); zenLock = run.catch(() => {}); return run; }
function selectNode(name) { return api('/proxies/ZEN', { method: 'PUT', body: JSON.stringify({ name }) }); }

// ---------- verdicts ----------
function verdictOf(ip) {
  const v = VALID[ip];
  if (!v) return { kind: 'unknown', at: 0 };
  const age = Date.now() - Date.parse(v.at || 0);
  if ((v.kind === 'unavailable' || v.kind === 'limited') && age > 2 * 3600 * 1000) return { kind: 'unknown', at: 0 };
  return { kind: v.kind || (v.ok ? 'ok' : 'blocked'), at: Date.parse(v.at || 0) };
}
function usable(n, now = Date.now()) {
  const st = ipState(n.ip);
  if (st.exhaustedUntil > now || st.blockedUntil > now) return false;
  const k = verdictOf(n.ip).kind;
  return k === 'ok' || k === 'unknown';
}
function rank(n) {
  const k = verdictOf(n.ip).kind;
  const st = ipState(n.ip);
  if (k === 'ok' && st.lastOk && Date.now() - st.lastOk < 30 * 60 * 1000) return 0; // proven just now
  if (k === 'ok') return 1;                                                          // verified earlier
  if (k === 'unknown') return 2;
  return 3;
}
function byScore(a, b) {
  const ra = rank(a), rb = rank(b);
  if (ra !== rb) return ra - rb;
  const sa = ipState(a.ip), sb = ipState(b.ip);
  if (sa.requests !== sb.requests) return sa.requests - sb.requests;
  const la = sa.ewma || a.delay, lb = sb.ewma || b.delay;
  if (la !== lb) return la - lb;
  return a.delay - b.delay;
}
function pickNode(exclude) {
  let pool = nodes.filter((n) => !exclude.has(n.name) && usable(n));
  if (!pool.length) {
    // everything rested: take the one that recovers first, so a request is not dropped
    return nodes.filter((n) => !exclude.has(n.name))
      .sort((a, b) => (ipState(a.ip).exhaustedUntil || 0) - (ipState(b.ip).exhaustedUntil || 0))[0] || null;
  }
  pool.sort(byScore);
  return pool[0];
}
function pickOnIp(ip, exclude) {
  let pool = (byIp.get(ip) || []).filter((n) => !exclude.has(n.name) && usable(n));
  if (!pool.length) return null;
  pool.sort((a, b) => (ipState(a.ip).ewma || a.delay) - (ipState(b.ip).ewma || b.delay));
  return pool[0];
}

// ---------- session affinity ----------
function sessionKey(headers, body) {
  const h = headers['x-opencode-session'] || headers['x-opencode-session-id'] || headers['x-session-affinity'] || headers['x-session-id'] || headers['conversation-id'];
  if (h) return 'h:' + h;
  try {
    const j = JSON.parse(body.toString('utf8'));
    if (j.metadata && typeof j.metadata.session_id === 'string') return 'm:' + j.metadata.session_id;
    const msgs = j.messages ?? j.input;
    let first;
    if (Array.isArray(msgs)) first = msgs.find((m) => m && m.role === 'user')?.content;
    else first = msgs;
    if (first) return 'b:' + createHash('sha256').update(JSON.stringify(first)).digest('hex').slice(0, 20);
  } catch {}
  return null;
}
function affinityOf(key) {
  if (!key) return null;
  const a = state.sessions[key];
  if (!a || Date.now() - a.at > AFFINITY_TTL) return null;
  return a;
}
function setAffinity(key, ip) {
  if (!key) return;
  state.sessions[key] = { ip, at: Date.now() };
  const keys = Object.keys(state.sessions);
  if (keys.length > AFFINITY_CAP) {
    keys.sort((a, b) => state.sessions[a].at - state.sessions[b].at);
    for (const k of keys.slice(0, keys.length - AFFINITY_CAP)) delete state.sessions[k];
  }
  dirty = true;
}
function dropAffinity(key) { if (key && state.sessions[key]) { delete state.sessions[key]; dirty = true; } }

// ---------- tunnel ----------
function openTunnel(proxyPort, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const sock = net.connect({ host: '127.0.0.1', port: proxyPort });
    let buf = '';
    const timer = setTimeout(() => { sock.destroy(); reject(new Error('proxy connect timeout')); }, timeoutMs);
    sock.setNoDelay(true);
    sock.on('error', (e) => { clearTimeout(timer); reject(e); });
    sock.on('connect', () => sock.write('CONNECT ' + UPSTREAM.host + ':443 HTTP/1.1\r\nHost: ' + UPSTREAM.host + ':443\r\nProxy-Connection: keep-alive\r\n\r\n'));
    const onData = (d) => {
      buf += d.toString('latin1');
      if (!buf.includes('\r\n\r\n')) return;
      clearTimeout(timer);
      sock.removeListener('data', onData);
      if (!/^HTTP\/1\.[01] 200/.test(buf)) { sock.destroy(); reject(new Error('proxy refused: ' + buf.split('\r\n')[0])); return; }
      resolve(sock);
    };
    sock.on('data', onData);
  });
}
function tlsOver(sock, timeoutMs = 20000) {
  return new Promise((resolve, reject) => {
    const s = tls.connect({ socket: sock, servername: UPSTREAM.host, minVersion: 'TLSv1.2' });
    const timer = setTimeout(() => { s.destroy(); reject(new Error('tls timeout')); }, timeoutMs);
    s.once('secureConnect', () => { clearTimeout(timer); resolve(s); });
    s.once('error', (e) => { clearTimeout(timer); reject(e); });
  });
}
function upstreamRequest(method, path, headers, body, sock) {
  return new Promise((resolve, reject) => {
    const agent = new http.Agent({ keepAlive: false });
    agent.createConnection = () => sock;
    const req = http.request({ host: UPSTREAM.host, port: UPSTREAM.port, method, path: UPSTREAM.base + path, headers, agent }, resolve);
    req.setTimeout(120000, () => req.destroy(new Error('upstream idle timeout')));
    req.on('error', reject);
    if (body && body.length) req.write(body);
    req.end();
  });
}
async function forwardThrough(node, reqInfo, proxyPort) {
  const sock = await openTunnel(proxyPort);
  let tlsSock;
  try { tlsSock = await tlsOver(sock); } catch (e) { sock.destroy(); throw e; }
  const headers = { ...reqInfo.headers, host: UPSTREAM.host, connection: 'close' };
  delete headers['content-length']; delete headers['transfer-encoding'];
  if (reqInfo.body.length) headers['content-length'] = String(reqInfo.body.length);
  const res = await upstreamRequest(reqInfo.method, reqInfo.path, headers, reqInfo.body, tlsSock);
  return { res, tlsSock };
}
function readAll(res, limit = 300000) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    res.on('data', (d) => { size += d.length; if (size <= limit) chunks.push(d); });
    res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    res.on('error', reject);
  });
}
function isQuota(status, body) { return (status === 403 || status === 429 || status === 400) && QUOTA_RE.test(body || ''); }

// ---------- serving ----------
function writeStatus(res) {
  const now = Date.now();
  const allIps = [...new Set([...Object.keys(state.ips), ...byIp.keys()])];
  const ips = allIps.map((ip) => { const s = ipState(ip); return ({
    ip, requests: s.requests, tokens: s.tokens, failures: s.failures, ewma: s.ewma ? Math.round(s.ewma) : 0,
    verdict: verdictOf(ip).kind,
    exhausted: !!s.exhaustedUntil && s.exhaustedUntil > now,
    blocked: !!s.blockedUntil && s.blockedUntil > now,
    exhaustedUntil: s.exhaustedUntil > now ? new Date(s.exhaustedUntil).toISOString() : '',
    blockedUntil: s.blockedUntil > now ? new Date(s.blockedUntil).toISOString() : '',
    lastError: s.lastError, lastAt: s.lastAt ? new Date(s.lastAt).toISOString() : '',
    nodes: (byIp.get(ip) || []).length,
  }); }).sort((a, b) => b.requests - a.requests);
  const usableNow = ips.filter((i) => !i.exhausted && !i.blocked && (i.verdict === 'ok' || i.verdict === 'unknown')).length;
  const json = JSON.stringify({
    ok: true, now: new Date().toISOString(), version: 2,
    current: { node: state.current, egressIp: state.currentIp },
    totals: { requests: ips.reduce((a, b) => a + b.requests, 0), tokens: ips.reduce((a, b) => a + b.tokens, 0), ipCount: ips.length, usableIpCount: usableNow, sessions: Object.keys(state.sessions).length },
    ips: ips.slice(0, 80),
    nodes: { total: nodes.length, ips: byIp.size },
    events: state.events.slice(-15),
  });
  res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
  res.end(json);
}
function rememberNode(node) { state.current = node.name; state.currentIp = node.ip; dirty = true; }

async function selectFor(key, exclude) {
  return withZenLock(async () => {
    const aff = affinityOf(key);
    let node = null;
    if (aff && !exclude.has(aff.ip)) node = pickOnIp(aff.ip, exclude);
    if (!node) node = pickNode(exclude);
    if (!node) return null;
    await selectNode(node.name);
    rememberNode(node);
    return node;
  });
}

async function proxyWithRotation(reqInfo, res, key) {
  const tried = new Set();
  let last = null;
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const started = Date.now();
    let node;
    try { node = await selectFor(key, tried); } catch (e) {
      last = { status: 502, body: JSON.stringify({ error: { message: 'zen-router: mihomo unavailable: ' + e.message } }) }; break;
    }
    if (!node) { last = last || { status: 503, body: JSON.stringify({ error: { message: 'zen-router: no usable egress IP' } }) }; break; }
    tried.add(node.name);
    const st = ipState(node.ip);
    try {
      const { res: up, tlsSock } = await forwardThrough(node, reqInfo, PROXY.port);
      const ttfb = Date.now() - started;
      if (up.statusCode === 200) {
        st.requests += 1; st.lastAt = Date.now(); st.failures = 0; st.blockedUntil = 0; st.lastOk = Date.now();
        st.ewma = st.ewma ? Math.round(st.ewma * 0.7 + ttfb * 0.3) : ttfb;
        VALID[node.ip] = { node: node.name, delay: node.delay, ok: true, kind: 'ok', at: new Date().toISOString() };
        try { fs.writeFileSync(DIR + '/ip-valid.json', JSON.stringify({ checkedAt: new Date().toISOString(), ips: VALID }, null, 1)); } catch {}
        setAffinity(key, node.ip);
        res.writeHead(200, { 'content-type': up.headers['content-type'] || 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
        const tail = [];
        up.on('data', (d) => { if (tail.length > 40) tail.shift(); tail.push(d); res.write(d); });
        up.on('end', () => {
          try {
            const text = Buffer.concat(tail.slice(-6)).toString('utf8');
            const m = /"total_tokens"\s*:\s*(\d+)/g; let lastN = null, mm; while ((mm = m.exec(text))) lastN = Number(mm[1]);
            if (lastN) { st.tokens += lastN; dirty = true; }
          } catch {}
          log('ok ' + node.ip + ' ' + reqInfo.path + ' ' + ttfb + 'ms' + (key ? ' sess=' + key.slice(0, 12) : ''));
          try { tlsSock.destroy(); } catch {}
          res.end();
          saveState();
        });
        up.on('error', () => { try { res.end(); } catch {} });
        return;
      }
      const body = await readAll(up);
      try { tlsSock.destroy(); } catch {}
      last = { status: up.statusCode, body };
      if (isQuota(up.statusCode, body)) {
        const geo = /not available in your country|permission_error/i.test(body);
        const quotaLike = /third[-\s]?party|第三方|额度|quota|rate.?limit|too many/i.test(body);
        st.failures += 1; st.lastAt = Date.now(); dropAffinity(key); dirty = true;
        if (geo) {
          st.blockedUntil = Date.now() + 5 * 60 * 1000; st.lastError = 'geo: ' + body.slice(0, 120);
          event('geo', node.ip + ' (' + node.name + ') model refused for this country, retrying another IP');
        } else if (quotaLike) {
          st.exhaustedUntil = Date.now() + QUOTA_COOLDOWN_MS; st.lastError = 'quota: ' + body.slice(0, 120);
          event('exhausted', node.ip + ' (' + node.name + ') quota used up');
        } else {
          st.blockedUntil = Date.now() + BLOCK_COOLDOWN_MS; st.lastError = 'blocked: ' + body.slice(0, 120);
          VALID[node.ip] = { node: node.name, delay: node.delay, ok: false, kind: 'blocked', at: new Date().toISOString() };
          try { fs.writeFileSync(DIR + '/ip-valid.json', JSON.stringify({ checkedAt: new Date().toISOString(), ips: VALID }, null, 1)); } catch {}
          event('blocked', node.ip + ' (' + node.name + ') ' + body.slice(0, 90).replace(/\s+/g, ' '));
        }
        saveState();
        continue;
      }
      if (up.statusCode >= 500) {
        st.failures += 1; st.blockedUntil = Date.now() + 10 * 60 * 1000; st.lastError = 'upstream ' + up.statusCode; st.lastAt = Date.now();
        dropAffinity(key); dirty = true;
        event('upstream5xx', node.ip + ' ' + up.statusCode);
        saveState();
        continue;
      }
      res.writeHead(up.statusCode, { 'content-type': up.headers['content-type'] || 'application/json' });
      res.end(body);
      return;
    } catch (e) {
      st.failures += 1; st.lastError = 'net: ' + e.message; st.lastAt = Date.now(); dirty = true;
      dropAffinity(key);
      if (st.failures >= 2) st.blockedUntil = Date.now() + 5 * 60 * 1000;
      event('nodefail', node.ip + ' (' + node.name + ') ' + e.message);
      last = { status: 502, body: JSON.stringify({ error: { message: 'zen-router: upstream unreachable: ' + e.message } }) };
    }
  }
  res.writeHead(last ? last.status : 502, { 'content-type': 'application/json' });
  res.end(last ? last.body : JSON.stringify({ error: { message: 'zen-router: no answer' } }));
}

async function proxyModels(res) {
  const reqInfo = { method: 'GET', path: '/models', headers: { authorization: 'Bearer public', 'x-opencode-client': 'cli', accept: 'application/json' }, body: Buffer.alloc(0) };
  const tried = new Set();
  for (let attempt = 0; attempt < 3; attempt++) {
    let node;
    try { node = await withZenLock(async () => { const n = pickNode(tried); if (!n) return null; await selectNode(n.name); rememberNode(n); return n; }); }
    catch { node = null; }
    if (!node) break;
    tried.add(node.name);
    try {
      const { res: up, tlsSock } = await forwardThrough(node, reqInfo, PROXY.port);
      const body = await readAll(up, 2_000_000);
      try { tlsSock.destroy(); } catch {}
      if (up.statusCode === 200) { state.modelCache = body; dirty = true; res.writeHead(200, { 'content-type': 'application/json' }); res.end(body); return; }
    } catch {}
  }
  if (state.modelCache) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(state.modelCache); return; }
  res.writeHead(502, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: { message: 'zen-router: model list unavailable' } }));
}

// keep state small and cooldowns fresh
setInterval(() => {
  const now = Date.now();
  for (const s of Object.values(state.ips)) { if (s.exhaustedUntil && s.exhaustedUntil <= now) s.exhaustedUntil = 0; if (s.blockedUntil && s.blockedUntil <= now) s.blockedUntil = 0; }
  for (const [k, a] of Object.entries(state.sessions)) if (now - a.at > AFFINITY_TTL) delete state.sessions[k];
}, 60_000).unref();

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks);

    if (req.method === 'GET' && (url.pathname === '/status' || url.pathname === '/')) return writeStatus(res);
    if (req.method === 'GET' && url.pathname === '/ip') {
      const node = await withZenLock(async () => { const n = pickNode(new Set()); if (!n) throw new Error('none'); await selectNode(n.name); rememberNode(n); return n; });
      res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ node: node.name, ip: node.ip, delay: node.delay }));
      return;
    }
    if (req.method === 'POST' && url.pathname === '/rotate') {
      const node = await withZenLock(async () => { const n = pickNode(new Set(state.current ? [state.current] : [])); if (!n) return null; await selectNode(n.name); rememberNode(n); return n; });
      res.writeHead(node ? 200 : 503, { 'content-type': 'application/json' });
      res.end(JSON.stringify(node ? { ok: true, node: node.name, ip: node.ip } : { ok: false }));
      if (node) event('rotate', 'manual -> ' + node.ip);
      return;
    }
    if (req.method === 'POST' && url.pathname === '/probe') {
      for (const s of Object.values(state.ips)) { s.exhaustedUntil = 0; s.blockedUntil = 0; }
      try { VALID = JSON.parse(fs.readFileSync(DIR + '/ip-valid.json', 'utf8')).ips || VALID; } catch {}
      dirty = true;
      res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ ok: true, restedCleared: true }));
      return;
    }

    const known = ['/chat/completions', '/responses', '/messages'];
    if (req.method === 'GET' && url.pathname === '/models') return proxyModels(res);
    if (known.includes(url.pathname)) {
      const headers = { ...req.headers };
      delete headers['host']; delete headers['content-length']; delete headers['transfer-encoding']; delete headers['accept-encoding'];
      headers.accept = headers.accept || '*/*';
      const key = sessionKey(headers, body);
      return proxyWithRotation({ method: req.method, path: url.pathname, headers, body }, res, key);
    }
    res.writeHead(404, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: 'zen-router: unknown path ' + url.pathname }));
  } catch (e) {
    log('server error ' + e.stack);
    try { res.writeHead(500, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: e.message })); } catch {}
  }
});
server.listen(7999, '127.0.0.1', () => { log('zen-router v2 listening on 7999, nodes=' + nodes.length + ' ips=' + byIp.size); });
process.on('uncaughtException', (e) => log('uncaught ' + e.stack));
