// 守护 mihomo + zen-router，并在 3425 不通时拉起 magpie。
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { DIR, MAGPIE, MIHOMO, NODE } from './paths.mjs';

const LOG = path.join(DIR, 'zen-supervisor.log');
const log = (m) => { try { fs.appendFileSync(LOG, new Date().toISOString() + ' ' + m + '\n'); } catch {} };
const started = new Set();

function start(name, file, args) {
  const child = spawn(file, args, { cwd: DIR, stdio: 'ignore', windowsHide: true });
  child.on('exit', (code, sig) => {
    log(name + ' exited code=' + code + ' sig=' + sig + ', restarting in 3s');
    setTimeout(() => start(name, file, args), 3000);
  });
  child.on('error', (e) => {
    log(name + ' spawn error ' + e.message);
    setTimeout(() => start(name, file, args), 5000);
  });
  log(name + ' started pid=' + child.pid);
  started.add(name);
  return child;
}

function portOpen(port, timeout = 1200) {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1');
    const done = (v) => { try { s.destroy(); } catch {} resolve(v); };
    s.setTimeout(timeout);
    s.once('connect', () => done(true));
    s.once('timeout', () => done(false));
    s.once('error', () => done(false));
  });
}

const LOCK = path.join(DIR, 'supervisor.lock');
function pidAlive(pid) { try { process.kill(pid, 0); return true; } catch { return false; } }
let existing = 0;
try { existing = Number(fs.readFileSync(LOCK, 'utf8').trim()); } catch {}
if (existing && existing !== process.pid && pidAlive(existing)) {
  log('supervisor already running pid=' + existing + ', exit');
  process.exit(0);
}
fs.writeFileSync(LOCK, String(process.pid));
const cleanupLock = () => { try { if (Number(fs.readFileSync(LOCK, 'utf8').trim()) === process.pid) fs.unlinkSync(LOCK); } catch {} };
process.on('exit', cleanupLock);
fs.writeFileSync(path.join(DIR, 'supervisor.pid'), String(process.pid));
start('mihomo', MIHOMO, ['-d', DIR, '-f', path.join(DIR, 'mihomo.yaml')]);
start('router', NODE, [path.join(DIR, 'zen-router.mjs')]);

async function ensureMagpie() {
  if (await portOpen(3425)) return;
  if (!fs.existsSync(MAGPIE)) { log('magpie missing: ' + MAGPIE); return; }
  log('gateway down, starting magpie tray');
  const child = spawn(MAGPIE, ['tray'], { cwd: DIR, stdio: 'ignore', windowsHide: true, detached: true });
  child.unref();
}
setTimeout(ensureMagpie, 10_000);
setInterval(ensureMagpie, 30_000);
log('supervisor pid=' + process.pid);
setInterval(() => {}, 1 << 30);
