import fs from 'node:fs';
import {connect,wait} from './cdp.mjs';
const {send,ev}=await connect();
const OUT=process.argv[2];
const JOBS=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const HOST='http://127.0.0.1:8791/';
const FILE={kanri:'_%E3%83%86%E3%82%B9%E3%83%88%E7%94%A8_senya-kanri.html',
            staff:'_%E3%83%86%E3%82%B9%E3%83%88%E7%94%A8_senya-staff.html'};
let lastUrl=null;
for(const j of JOBS){
  const W=j.w||390, H=j.h||844;
  await send('Emulation.setDeviceMetricsOverride',{width:W,height:H,deviceScaleFactor:2,mobile:W<600});
  if(j.ua==='ios') await send('Network.setUserAgentOverride',{userAgent:'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'});
  else if(j.ua==='android') await send('Network.setUserAgentOverride',{userAgent:'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36'});
  const url=HOST+FILE[j.app]+'?'+(j.q||'');
  await send('Page.navigate',{url}); await wait(j.wait||1900);
  const guard=await ev("location.href.includes('_%E3%83%86%E3%82%B9%E3%83%88%E7%94%A8_')");
  if(!guard){ console.log('ABORT: テスト用の複製ではありません'); process.exit(1); }
  await ev("(function(){var s=document.createElement('style');s.textContent='*{transition:none!important;animation:none!important;caret-color:transparent!important}';document.head.appendChild(s)})()");
  if(j.app==='kanri' && !j.nologin){
    const need=await ev("(function(){var l=document.getElementById('loginView');return !!(l&&!l.hidden)})()");
    if(need){ await ev("document.getElementById('codeInput').value='SAMPLE47'; document.getElementById('loginBtn').click();"); await wait(1500); }
  }
  if(j.js){ await ev(j.js); await wait(j.after||700); }
  if(j.scroll!=null){ await ev('window.scrollTo(0,'+j.scroll+')'); await wait(350); }
  let clip=null;
  if(j.clip){
    const r=await ev(`(function(){
      var a=document.querySelector(${JSON.stringify(j.clip[0])});
      var b=document.querySelector(${JSON.stringify(j.clip[1]||j.clip[0])});
      if(!a||!b) return null;
      var ra=a.getBoundingClientRect(), rb=b.getBoundingClientRect();
      return {x:0,y:Math.min(ra.top,rb.top),w:${W},h:Math.max(ra.bottom,rb.bottom)-Math.min(ra.top,rb.top)};
    })()`);
    if(!r){ console.log('!! clip未検出 '+j.file); process.exit(1); }
    const pad=j.pad==null?10:j.pad;
    const y0=Math.max(0,r.y-pad), hh=Math.min(H-y0, r.h+pad*2);
    if(hh<=20){ console.log('!! clipが画面外 '+j.file+' (top='+Math.round(r.y)+')'); process.exit(1); }
    clip={x:0,y:y0,width:W,height:hh,scale:1};
  }
  const s=await send('Page.captureScreenshot',clip?{format:'png',clip}:{format:'png'});
  fs.writeFileSync(OUT+'/'+j.file,Buffer.from(s.data,'base64'));
  console.log('✓ '+j.file);
}
process.exit(0);
