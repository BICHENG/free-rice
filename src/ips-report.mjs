import fs from 'node:fs';
import { DIR } from './paths.mjs';
if (!fs.existsSync(DIR + '/node-egress.json')) { console.error('缺少 node-egress.json，先运行 measure.mjs'); process.exit(2); }
const eg=JSON.parse(fs.readFileSync(DIR+'/node-egress.json','utf8'));
let valid={}; try{ valid=JSON.parse(fs.readFileSync(DIR+'/ip-valid.json','utf8')).ips; }catch{}
try{ const part=JSON.parse(fs.readFileSync(DIR+'/ip-valid.partial.json','utf8')).ips; for(const [ip,v] of Object.entries(part)) if(!valid[ip]) valid[ip]=v; }catch{}
const byIp=new Map();
for(const n of Object.values(eg.nodes)){
  if(!n.ip) continue;
  if(!byIp.has(n.ip)) byIp.set(n.ip,[]);
  byIp.get(n.ip).push(n);
}
const regionOf=(name)=>{
  const m=name.match(/香港|台湾|日本|美国|新加坡|韩国|英国|德国|荷兰|法国|加拿大|澳大利亚|俄罗斯|印度|土耳其|越南|泰国|马来|菲律宾|迪拜|阿根廷|巴西|智利|墨西哥|印尼|cn2|hk|tw|jp|us|sg|kr/i);
  if(!m) return '其他';
  const k=m[0].toLowerCase();
  const map={'香港':'香港','hk':'香港','台湾':'台湾','tw':'台湾','日本':'日本','jp':'日本','美国':'美国','us':'美国','新加坡':'新加坡','sg':'新加坡','韩国':'韩国','kr':'韩国'};
  return map[k]||'其他';
};
const rows=[...byIp.entries()].map(([ip,ns])=>{
  const v=valid[ip];
  return {ip, nodes:ns.map(n=>n.name), delay:Math.min(...ns.map(n=>n.delay)), region:regionOf(ns[0].name), verdict: v? v.kind: '未知', status: v? v.status: ''};
}).sort((a,b)=>a.delay-b.delay);
const label={'ok':'可用','limited':'限额','unavailable':'上游不可用','blocked':'拒绝','dead':'不可达','未知':'未测'};
for(const r of rows) r.label = label[r.verdict] || r.verdict;
const count=(k)=>rows.filter(r=>r.verdict===k).length;
const ok=count('ok'), limited=count('limited'), unavailable=count('unavailable'), blocked=count('blocked'), dead=count('dead');
const lines=[];
lines.push('# OpenCode Zen 免费通道可用出口 IP 清单');
lines.push('');
lines.push('- 提取时间：'+new Date().toISOString());
lines.push('- 订阅节点：'+Object.keys(eg.nodes).length+' 个，去重后出口 IP：'+rows.length+' 个');
lines.push('- 实测可用：'+ok+' 个；免费额度已用尽（429）：'+limited+' 个；上游暂不可用（5xx）：'+unavailable+' 个；被拒绝：'+blocked+' 个；不可达：'+dead+' 个');
lines.push('');
lines.push('| 出口 IP | 地区 | 延迟 ms | 实测 | 节点 |');
lines.push('| --- | --- | --- | --- | --- |');
for(const r of rows) lines.push('| '+r.ip+' | '+r.region+' | '+r.delay+' | '+r.label+' | '+r.nodes[0].replace(/\|/g,'/')+' |');
lines.push('');
lines.push('说明：出口 IP 是每个节点真实出网地址，按 Zen 免费额度的计费口径统计。同一 IP 上挂多个节点时共用一个额度，调度器按 IP 聚合消耗。');
fs.writeFileSync(DIR+'/zen-ips.md', lines.join('\n'));
console.log('rows',rows.length,'ok',ok,'blocked',blocked,'dead',dead);