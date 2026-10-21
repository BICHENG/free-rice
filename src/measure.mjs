import fs from 'node:fs';
import http from 'node:http';
import { DIR } from './paths.mjs';

if (!fs.existsSync(DIR + '/meta.json')) { console.error('缺少 meta.json，先运行 build-config.mjs 生成配置'); process.exit(2); }

const NAME_API = 'http://127.0.0.1:9099';
const SEC = JSON.parse(fs.readFileSync(DIR + '/meta.json','utf8')).secret;
const meta = JSON.parse(fs.readFileSync(DIR + '/meta.json','utf8'));
const statePath = DIR + '/node-egress.json';

async function api(path, opt={}) {
  const r = await fetch(NAME_API+path, { ...opt, headers:{ authorization:'Bearer '+SEC, 'content-type':'application/json' }});
  const t = await r.text();
  return { status:r.status, body: t };
}
function proxyGet(port, url, timeout=8000) {
  return new Promise((resolve) => {
    const u = new URL(url);
    const req = http.request({ host:'127.0.0.1', port, method:'GET', path:url, headers:{ host:u.host, 'user-agent':'zen-measure/1.0' } }, (res) => {
      let data=''; res.setEncoding('utf8');
      res.on('data', d=>data+=d);
      res.on('end', ()=>resolve({ status:res.statusCode, body:data.trim(), ms:Date.now()-t0 }));
    });
    const t0 = Date.now();
    req.setTimeout(timeout, ()=>{ req.destroy(new Error('timeout')); });
    req.on('error', (e)=>resolve({ error:e.message, ms:Date.now()-t0 }));
    req.end();
  });
}
async function selectProbe(name) {
  const r = await api('/proxies/PROBE', { method:'PUT', body: JSON.stringify({ name }) });
  if (r.status !== 204 && r.status !== 200) throw new Error('select '+r.status+' '+r.body.slice(0,120));
}
async function delay(name) {
  const r = await api('/proxies/' + encodeURIComponent(name) + '/delay?url=' + encodeURIComponent('https://cp.cloudflare.com/generate_204') + '&timeout=5000');
  try { const j = JSON.parse(r.body); return j.delay ?? null; } catch { return null; }
}

const nodes = meta.nodes;
const results = {};
// 1) health+latency in parallel batches
let idx = 0;
async function worker() {
  while (idx < nodes.length) {
    const n = nodes[idx++];
    const d = await delay(n.name);
    results[n.name] = { ...n, delay: d };
  }
}
await Promise.all(Array.from({length: 6}, worker));
const alive = nodes.filter(n => results[n.name].delay != null);
console.log('alive', alive.length, '/', nodes.length, alive.map(n=>n.name+':'+results[n.name].delay).slice(0,8).join(', '));

// 2) egress IP per alive node, sequential
const ipSeen = {};
for (const n of alive) {
  let ip = null, err = null;
  try { await selectProbe(n.name); } catch (e) { err = 'select:'+e.message; }
  if (!err) {
    let r = await proxyGet(7901, 'https://api.ipify.org?format=text', 7000);
    if (r.error || r.status !== 200) { r = await proxyGet(7901, 'http://ip-api.com/json?fields=query,country,city,isp', 7000); if (r.status===200) { try { const j=JSON.parse(r.body); ip=j.query; results[n.name].geo={country:j.country,city:j.city,isp:j.isp}; } catch {} } }
    else ip = r.body.trim();
    if (!ip && r.status) err = 'http'+r.status;
    if (!ip && r.error) err = r.error;
  }
  results[n.name].ip = ip || null;
  results[n.name].ipErr = err;
  results[n.name].checkedAt = new Date().toISOString();
  if (ip) ipSeen[ip] = (ipSeen[ip]||0)+1;
  process.stdout.write('.');
}
console.log('\ndone. unique egress ips', Object.keys(ipSeen).length);
const out = { checkedAt: new Date().toISOString(), nodes: results };
fs.writeFileSync(statePath, JSON.stringify(out, null, 1));
console.log('saved', statePath);
