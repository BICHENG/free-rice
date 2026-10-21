import fs from 'node:fs';
import path from 'node:path';
import { DIR, DSH_HOME } from './paths.mjs';

const profile = process.env.DSH_PROFILE || 'desktop';
const CFG = path.join(DSH_HOME, 'profiles', profile, 'cordis.patch.yml');
const probePath = path.join(DIR, 'model-probe.json');
if (!fs.existsSync(probePath)) { console.error('缺少 model-probe.json，先运行 probe-models.mjs'); process.exit(2); }
if (!fs.existsSync(CFG)) { console.error('找不到 DSH 配置: ' + CFG); process.exit(2); }
const probe = JSON.parse(fs.readFileSync(probePath, 'utf8'));
const limits = {};
const report = [];
for (const [id, rec] of Object.entries(probe.models)) {
  const declared = rec.declaredContext || 0;
  const effective = rec.effectiveContext || 0;
  const context = Math.min(effective > 0 ? effective : declared, 800000);
  limits[id] = { declaredContext: declared, declaredOutput: rec.declaredOutput || 0, effectiveContext: effective, contextWindow: context, available: rec.available, checkedAt: probe.checkedAt };
  report.push(id + ' ctx=' + context);
}
fs.writeFileSync(path.join(DIR, 'model-limits.json'), JSON.stringify(limits, null, 1));
// DSH 的模型列表由 magpie 同步，这里只写上限缓存，供面板与文档使用。
console.log(report.join('\n'));
console.log('wrote ' + path.join(DIR, 'model-limits.json'));
