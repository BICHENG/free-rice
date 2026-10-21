import fs from 'node:fs';
import path from 'node:path';

const winHome = process.env.USERPROFILE || process.env.HOME || '.';
export const DIR = process.env.ZEN_IP_HOME || path.join(winHome, '.zen-ip');
export const CONFIG_PATH = path.join(DIR, 'config.json');

let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')); } catch {}

// v1 端口固定，文档和托盘都按这组端口工作。
export const GATEWAY_PORT = 3425;
export const ROUTER_PORT = 7999;
export const PROXY_PORT = 7900;
export const PROBE_PORT = 7901;
export const API_PORT = 9099;
export const GATEWAY = `http://127.0.0.1:${GATEWAY_PORT}`;
export const ROUTER_URL = `http://127.0.0.1:${ROUTER_PORT}`;
export const DSH_HOME = process.env.DSH_HOME || path.join(winHome, '.dsh');
export const MAGPIE = process.env.MAGPIE_BIN || path.join(DIR, 'bin', 'magpie.exe');
export const MIHOMO = path.join(DIR, 'bin', 'mihomo.exe');
export const NODE = process.env.ZEN_NODE || path.join(DIR, 'bin', 'node.exe');
export const config = cfg;
export const UA = 'clash-verge/v2.2.3 mihomo/v1.19.0';
