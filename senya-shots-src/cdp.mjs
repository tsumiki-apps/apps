import fs from 'node:fs';
const base='http://127.0.0.1:9334';
export async function connect(){
  const list=await (await fetch(base+'/json/list')).json();
  const t=list.find(x=>x.type==='page');
  const ws=new WebSocket(t.webSocketDebuggerUrl);
  let id=0; const pend=new Map();
  await new Promise(r=>ws.onopen=r);
  ws.onmessage=e=>{const d=JSON.parse(e.data); if(d.id&&pend.has(d.id)){const[res,rej]=pend.get(d.id);pend.delete(d.id); d.error?rej(new Error(JSON.stringify(d.error))):res(d.result)}};
  const send=(m,p={})=>new Promise((res,rej)=>{const i=++id;pend.set(i,[res,rej]);ws.send(JSON.stringify({id:i,method:m,params:p}))});
  await send('Page.enable');
  const ev=async(x)=>{const r=await send('Runtime.evaluate',{expression:x,awaitPromise:true,returnByValue:true});
    if(r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0,400)); return r.result.value;};
  return {send,ev,ws};
}
export const wait=ms=>new Promise(r=>setTimeout(r,ms));
