import fs from 'node:fs';
import path from 'node:path';
import { DIR, UA } from './paths.mjs';

const argv = process.argv.slice(2);
const arg = (name, fallback = '') => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] || fallback : fallback;
};

let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(path.join(DIR, 'config.json'), 'utf8')); } catch {}

const source = arg('--sub') || arg('--file') || cfg.subscription || cfg.clashConfig || path.join(DIR, 'sub.yaml');
const secret = 'zen-' + Math.random().toString(36).slice(2, 12);

async function readSource(src) {
  if (/^https?:\/\//i.test(src)) {
    const res = await fetch(src, { headers: { 'user-agent': UA, accept: 'text/yaml,text/plain,*/*' } });
    if (!res.ok) throw new Error('订阅拉取失败: HTTP ' + res.status);
    const text = await res.text();
    if (!/proxies:\s*\n/.test(text)) throw new Error('订阅内容里没有 proxies 段，可能不是 Clash 配置');
    fs.writeFileSync(path.join(DIR, 'sub.yaml'), text);
    return { text, from: src };
  }
  const file = path.isAbsolute(src) ? src : path.resolve(process.cwd(), src);
  if (!fs.existsSync(file)) throw new Error('找不到 Clash 配置: ' + file + '（用 --sub URL 或 --file 路径）');
  return { text: fs.readFileSync(file, 'utf8'), from: file };
}

function scalar(raw) {
  let s = raw.trim();
  if (s.startsWith("'") && s.endsWith("'")) return s.slice(1, -1).replace(/''/g, "'");
  if (s.startsWith('"') && s.endsWith('"')) { try { return JSON.parse(s); } catch { return s.slice(1, -1); } }
  const hash = s.search(/\s+#/);
  if (hash > 0) s = s.slice(0, hash).trim();
  return s;
}
function extractProxies(text) {
  const lines = text.split(/\r?\n/);
  const start = lines.findIndex((l) => /^proxies:\s*$/.test(l));
  if (start < 0) throw new Error('配置里没有 proxies 段');
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) if (/^[a-zA-Z][a-zA-Z0-9_-]*:\s*/.test(lines[i])) { end = i; break; }
  return lines.slice(start + 1, end);
}
function parseNodes(block) {
  const nodes = [];
  let cur = null;
  for (const l of block) {
    if (/^  -\s*$/.test(l)) { cur = { raw: ['  -'] }; nodes.push(cur); continue; }
    if (!cur) continue;
    cur.raw.push(l);
    let m;
    if ((m = /^    name:\s*(.*)$/.exec(l))) cur.name = scalar(m[1]);
    else if ((m = /^    server:\s*(.*)$/.exec(l))) cur.server = scalar(m[1]);
    else if ((m = /^    type:\s*(.*)$/.exec(l))) cur.type = scalar(m[1]);
    else if ((m = /^    port:\s*(.*)$/.exec(l))) cur.port = Number(scalar(m[1]));
    else if ((m = /^    udp:\s*(.*)$/.exec(l))) cur.udp = scalar(m[1]);
  }
  const seen = new Set();
  return nodes.filter((n) => {
    if (!n.name || !n.server || !n.type) return false;
    if (seen.has(n.name)) return false;
    seen.add(n.name);
    return true;
  });
}

const { text, from } = await readSource(source);
const block = extractProxies(text);
const nodes = parseNodes(block);
if (!nodes.length) throw new Error('没有解析到任何节点');
const rawNames = block.filter((l) => /^    name:\s*.*$/.test(l)).map((l) => l.replace(/^    name:\s*/, '').trim());
const groupNames = [...new Set(rawNames)];

const mihomo = `mixed-port: 7900
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
ipv6: false
external-controller: 127.0.0.1:9099
secret: ${secret}
unified-delay: true
tcp-concurrent: true
find-process-mode: off
profile:
  store-selected: true
dns:
  enable: true
  ipv6: false
  enhanced-mode: normal
  default-nameserver: [223.5.5.5, 119.29.29.29]
  nameserver: [223.5.5.5, 119.29.29.29]
  proxy-server-nameserver: [223.5.5.5, 119.29.29.29]
listeners:
  - name: probe
    type: mixed
    port: 7901
    listen: 127.0.0.1
proxies:
${nodes.flatMap((n) => n.raw).join('\n')}
proxy-groups:
  - name: ZEN
    type: select
    proxies: [${groupNames.join(', ')}]
  - name: PROBE
    type: select
    proxies: [${groupNames.join(', ')}]
rules:
  - IN-PORT,7901,PROBE
  - MATCH,ZEN
`;

fs.writeFileSync(path.join(DIR, 'mihomo.yaml'), mihomo);
fs.writeFileSync(path.join(DIR, 'meta.json'), JSON.stringify({
  secret,
  builtAt: new Date().toISOString(),
  subscription: from,
  totalNodes: nodes.length,
  nodes: nodes.map((n, i) => ({ i, name: n.name, server: n.server, port: n.port, type: n.type })),
}, null, 1));
console.log('nodes=' + nodes.length + ' uniqueServers=' + new Set(nodes.map((n) => n.server)).size + ' source=' + from);
