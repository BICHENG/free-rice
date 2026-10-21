import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import tls from 'node:tls';
import tls2 from 'node:tls';
import { DIR } from './paths.mjs';

if (!fs.existsSync(DIR + '/node-egress.json')) { console.error('缺少 node-egress.json，先运行 measure.mjs'); process.exit(2); }
const META=JSON.parse(fs.readFileSync(DIR+'/meta.json','utf8'));
const SEC=META.secret;
const EGRESS=JSON.parse(fs.readFileSync(DIR+'/node-egress.json','utf8'));
const ALPHABET='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
let counter=0, lastStamp=0;
function id(prefix, descending=false){
  const now=Date.now();
  if(now!==lastStamp){lastStamp=now;counter=0;}
  counter++;
  const cur=BigInt(now)*0x1000n+BigInt(counter);
  const v=((descending?~cur:cur)&0xffffffffffffn).toString(16).padStart(12,'0');
  let tail=''; const rb=Buffer.from(Array.from({length:14},()=>Math.floor(Math.random()*62)));
  for(const b of rb) tail+=ALPHABET[b%62];
  return prefix+'_'+v+tail;
}
const TOOLS=[['bash','command'],['edit','filePath'],['glob','pattern'],['grep','pattern'],['read','filePath']].map(([name,key])=>({type:'function',function:{name,description:'Not available. Never call this tool.',parameters:{type:'object',properties:{[key]:{type:'string'}},additionalProperties:false}}}));
function body(){return Buffer.from(JSON.stringify({model:'deepseek-v4.1-flash-free',stream:true,max_tokens:1,messages:[{role:'user',content:'ok'}],tools:TOOLS,stream_options:{include_usage:true}}));}
async function api(path,opt={}){const r=await fetch('http://127.0.0.1:9099'+path,{...opt,headers:{authorization:'Bearer '+SEC,'content-type':'application/json'}});const t=await r.text();if(r.status>=400)throw new Error('api '+r.status);return t;}
async function probe(ip,nodeName){
  await api('/proxies/PROBE',{method:'PUT',body:JSON.stringify({name:nodeName})});
  const sock=net.connect({host:'127.0.0.1',port:7901});
  await new Promise((res,rej)=>{sock.once('connect',res);sock.once('error',rej);});
  sock.write('CONNECT opencode.ai:443 HTTP/1.1\r\nHost: opencode.ai:443\r\n\r\n');
  let b='';
  await new Promise((res,rej)=>{const h=(d)=>{b+=d.toString('latin1');if(b.includes('\r\n\r\n')){sock.off('data',h);if(/ 200/.test(b.split('\r\n')[0]))res();else rej(new Error(b.split('\r\n')[0]));}};sock.on('data',h);sock.once('error',rej);});
  const t=tls.connect({socket:sock,servername:'opencode.ai'});
  await new Promise((res,rej)=>{
    const timer=setTimeout(()=>{t.destroy();rej(new Error('tls timeout'));},10000);
    t.once('secureConnect',()=>{clearTimeout(timer);res();});
    t.once('error',(e)=>{clearTimeout(timer);rej(e);});
  });
  const sid=id('ses',true);
  const headers={'content-type':'application/json',accept:'*/*','user-agent':'opencode/1.19.0 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14','x-opencode-project':'global','x-opencode-session':sid,'x-opencode-request':id('msg',false),'x-opencode-client':'cli','x-opencode-session-id':sid,authorization:'Bearer public'};
  const data=body(); headers['content-length']=String(data.length);
  const res=await new Promise((resolve,reject)=>{
    const agent=new http.Agent({keepAlive:false}); agent.createConnection=()=>t;
    const req=http.request({host:'opencode.ai',port:443,method:'POST',path:'/inference/v1/chat/completions',headers,agent},resolve);
    req.setTimeout(15000,()=>req.destroy(new Error('timeout')));
    req.on('error',reject); req.write(data); req.end();
  });
  let out=''; res.on('data',d=>out+=d); await new Promise(r=>res.on('end',r));
  try{t.destroy();}catch{}
  return { status:res.statusCode, body:out.slice(0,300) };
}

const nodes=Object.values(EGRESS.nodes).filter(n=>n.delay!=null&&n.ip);
const byIp=new Map();
for(const n of nodes){ if(!byIp.has(n.ip)) byIp.set(n.ip,n); }
const result={checkedAt:new Date().toISOString(), ips:{}};
try { const prev=JSON.parse(fs.readFileSync(DIR+'/ip-valid.partial.json','utf8')); Object.assign(result.ips, prev.ips||{}); } catch {}
const savePartial=()=>{ try{ fs.writeFileSync(DIR+'/ip-valid.partial.json', JSON.stringify(result,null,1)); }catch{} };
let i=0;
for(const [ip,node] of [...byIp.entries()].sort((a,b)=>a[1].delay-b[1].delay)){
  i++;
  const prev = result.ips[ip];
  if (prev && Date.now()-Date.parse(prev.at||0) < 6*3600*1000 && (prev.ok || prev.kind==='blocked')) { process.stdout.write(prev.ok?'.':'x'); continue; }
  let rec = { node: node.name, delay: node.delay, ok: false, kind: 'dead', status: 0, body: '', at: new Date().toISOString() };
  let last = null, lastErr = '';
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await probe(ip, node.name);
      last = r;
      if (r.status === 200 || r.status === 429 || /FreeTierError|within OpenCode/i.test(r.body)) break;
    } catch (e) { lastErr = e.message; }
    await new Promise((res) => setTimeout(res, 1200));
  }
  if (last) {
    const ok = last.status === 200;
    const kind = ok ? 'ok' : (/FreeTierError|within OpenCode/i.test(last.body) ? 'blocked' : (last.status === 429 ? 'limited' : 'unavailable'));
    rec = { node: node.name, delay: node.delay, ok, kind, status: last.status, body: last.body, at: new Date().toISOString() };
  } else rec.error = lastErr || 'no answer';
  result.ips[ip]=rec;
  process.stdout.write(rec.ok?'.':'x');
  if (i % 5 === 0) savePartial();
}
savePartial();
fs.writeFileSync(DIR+'/ip-valid.json',JSON.stringify(result,null,1));
console.log('\nvalidated', Object.keys(result.ips).length, 'ok', Object.values(result.ips).filter(x=>x.ok).length, 'blocked', Object.values(result.ips).filter(x=>x.kind==='blocked').length, 'dead', Object.values(result.ips).filter(x=>x.kind==='dead').length);
