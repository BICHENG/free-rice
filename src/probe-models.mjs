// Probe free models through magpie: availability + usable context limit.
// Usage: node probe-models.mjs [bareModel ...]   (no args = all free models)
import fs from 'node:fs';
import { DIR, GATEWAY } from './paths.mjs';
const OUT = DIR + '/model-probe.json';
const UNIT = 'The quick brown fox jumps over the lazy dog. ';
const only = process.argv.slice(2);

let result = { checkedAt: new Date().toISOString(), models: {} };
try { result = JSON.parse(fs.readFileSync(OUT, 'utf8')); } catch {}
result.checkedAt = new Date().toISOString();

async function models() {
  const r = await fetch(GATEWAY + '/v1/models', { headers: { authorization: 'Bearer magpie' } });
  return (await r.json()).data;
}
function classify(status, text) {
  if (status === 200) return 'ok';
  if (status === 429) return 'limited';
  if (status === 403 && /FreeTierError|within OpenCode/i.test(text)) return 'blocked';
  if (/context|exceed|too (long|large)|maximum|token limit|length/i.test(text)) return 'context';
  if (status >= 500 || /unavailable|server_error/i.test(text)) return 'unavailable';
  return 'error';
}
async function ask(modelId, tokens) {
  const content = tokens > 0 ? UNIT.repeat(Math.ceil((tokens * 4.2) / UNIT.length)) : 'Reply with exactly: OK';
  const body = JSON.stringify({ model: modelId, stream: false, max_tokens: 8, messages: [{ role: 'user', content }] });
  const t0 = Date.now();
  try {
    const r = await fetch(GATEWAY + '/v1/chat/completions', {
      method: 'POST', headers: { authorization: 'Bearer magpie', 'content-type': 'application/json' },
      body, signal: AbortSignal.timeout(100000),
    });
    const text = await r.text();
    return { status: r.status, kind: classify(r.status, text), ms: Date.now() - t0, note: text.replace(/\s+/g, ' ').slice(0, 200) };
  } catch (e) { return { status: 0, kind: 'error', ms: Date.now() - t0, note: e.message.slice(0, 200) }; }
}

const list = (await models()).filter((m) => String(m.id).startsWith('opencode-zen-free/'));
for (const m of list) {
  const id = String(m.id);
  const bare = id.slice('opencode-zen-free/'.length);
  if (only.length && !only.includes(bare)) continue;
  const declared = Number(m.max_input_tokens || m.context_length || 0);
  const declaredOut = Number(m.max_output_tokens || 0);
  const rec = { declaredContext: declared, declaredOutput: declaredOut, available: false, tests: [] };
  const small = await ask(id, 0);
  rec.tests.push({ size: 0, ...small });
  rec.available = small.kind === 'ok';
  let largestOk = 0;
  if (rec.available) {
    const sizes = [];
    const base = Math.min(declared, 200000);
    if (base > 0) sizes.push(base);
    if (declared > 300000) sizes.push(400000);
    if (declared > 600000) sizes.push(800000);
    for (const size of sizes) {
      const t = await ask(id, size);
      rec.tests.push({ size, ...t });
      if (t.kind === 'ok') largestOk = Math.max(largestOk, size);
      if (t.kind !== 'ok') break;
    }
  }
  rec.largestOk = largestOk;
  rec.effectiveContext = largestOk || (rec.available ? Math.min(declared, 32000) : 0);
  result.models[id] = rec;
  console.log(bare, 'available=' + rec.available, 'declared=' + declared, 'largestOk=' + largestOk, 'tests=' + rec.tests.map((t) => t.size + ':' + t.kind + '(' + t.status + ')').join(','));
  fs.writeFileSync(OUT, JSON.stringify(result, null, 1));
}
console.log('done');
