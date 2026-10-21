// 按 config.json 过滤免费模型，并把结果写回 magpie 的可见列表。
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { DIR, GATEWAY, MAGPIE } from './paths.mjs';

let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(path.join(DIR, 'config.json'), 'utf8')); } catch {}
const policy = cfg.models || {};
const minContext = Number(policy.minContextTokens == null ? 200000 : policy.minContextTokens);
const allow = new Set(policy.allow || []);
const deny = new Set(policy.deny || []);

async function getModels() {
  for (let i = 0; i < 20; i++) {
    try {
      const r = await fetch(GATEWAY + '/v1/models', { headers: { authorization: 'Bearer magpie' } });
      if (r.ok) return (await r.json()).data;
    } catch {}
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error('网关模型列表不可用: ' + GATEWAY);
}

const models = (await getModels()).filter((m) => String(m.id).startsWith('opencode-zen-free/'));
const keep = [];
const hidden = [];
for (const m of models) {
  const id = String(m.id);
  const bare = id.slice('opencode-zen-free/'.length);
  const ctx = Number(m.max_input_tokens || m.context_length || 0);
  if (deny.has(id)) { hidden.push(bare + ' (deny)'); continue; }
  if (allow.has(id) || ctx > minContext) { keep.push(bare); continue; }
  hidden.push(bare + ' (ctx=' + ctx + ')');
}
if (!keep.length) { console.error('过滤后没有可用模型，检查 config.models'); process.exit(3); }

const args = ['provider', 'models', 'opencode-zen-free', ...keep];
const r = spawnSync(MAGPIE, args, { stdio: 'inherit' });
if (r.status !== 0) process.exit(r.status || 1);
console.log('exposed: ' + keep.join(', '));
if (hidden.length) console.log('hidden:  ' + hidden.join(', '));
