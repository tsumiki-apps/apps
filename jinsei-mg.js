/* ============================================================
   じんせいすごろく ミニゲーム集（jinsei.html から読み込む）
   window.MG = { META, KEYS, play(stage, key, seed, sfx) => Promise<score> }
   - 全ゲーム スコア制（0〜150点目安）なので 2〜4人どの人数でも成立
   - seed 付き乱数で全員に同じ問題を出す（公平）
   - 必ず制限時間で自動終了する（放置・回線落ちでも詰まらない）
   - アニメは setInterval/<setTimeout> ベース（rAF停止環境でも動く）
   ============================================================ */
window.MG = (function(){
  const META = {
    timing:  { e:'🎯', n:'ぴったりストップ', d:'うごくバーを まんなかで止めよう（3回）' },
    taprush: { e:'⚡', n:'れんだバトル',     d:'5秒間 ボタンをぜんりょく連打！' },
    memory:  { e:'🧠', n:'すうじおぼえ',     d:'6けたの数字を 2秒でおぼえて入力！' },
    highlow: { e:'🃏', n:'ハイ&ロー',        d:'つぎのカードは上か下か？ 5回勝負' },
    janken:  { e:'✊', n:'あとだしじゃんけん', d:'おだい どおりに 勝ち負けしよう（5回）' },
  };
  const KEYS = Object.keys(META);

  function rng(seed){
    let t = (seed >>> 0) || 1;
    return function(){
      t += 0x6D2B79F5;
      let r = Math.imul(t ^ (t >>> 15), 1 | t);
      r ^= r + Math.imul(r ^ (r >>> 7), 61 | r);
      return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
    };
  }
  const esc = s => String(s).replace(/[&<>"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

  /* ---------- 1. ぴったりストップ ---------- */
  function gTiming(stage, seed, sfx){
    return new Promise(resolve=>{
      const R = rng(seed);
      let round = 0, total = 0, pos = 0, dir = 1, iv = null, tmo = null;
      stage.innerHTML = `
        <div class="mg-big" id="mgScore">0てん</div>
        <div class="mg-sub" id="mgRound"></div>
        <div class="mg-barwrap"><div class="mg-barcenter"></div><div class="mg-cursor" id="mgCur"></div></div>
        <button class="mg-tap mg-mainbtn" id="mgStop">ストップ！</button>`;
      const cur = stage.querySelector('#mgCur');
      function startRound(){
        round++;
        if(round > 3){ cleanup(); resolve(total); return; }
        stage.querySelector('#mgRound').textContent = `ラウンド ${round} / 3`;
        pos = R()*100; dir = (R()<0.5?1:-1);
        const speed = 2.2 + round*0.9;
        iv = setInterval(()=>{
          pos += dir*speed;
          if(pos>=100){pos=100;dir=-1;} if(pos<=0){pos=0;dir=1;}
          cur.style.left = pos + '%';
        }, 16);
        tmo = setTimeout(stop, 5000);   // 5秒で自動ストップ
      }
      function stop(){
        clearInterval(iv); clearTimeout(tmo);
        const diff = Math.abs(pos-50);
        const pts = Math.max(0, Math.round(50 - diff*2));
        total += pts;
        stage.querySelector('#mgScore').textContent = total + 'てん';
        if(pts>=44){ sfx.coin(); flash(stage,'✨ ぴったり！ +'+pts); }
        else if(pts>0){ sfx.tick(); flash(stage,'+'+pts); }
        else { sfx.bad(); flash(stage,'ざんねん…'); }
        setTimeout(startRound, 750);
      }
      stage.querySelector('#mgStop').onclick = ()=>{ if(iv){ stop(); } };
      function cleanup(){ clearInterval(iv); clearTimeout(tmo); }
      startRound();
    });
  }

  /* ---------- 2. れんだバトル ---------- */
  function gTaprush(stage, seed, sfx){
    return new Promise(resolve=>{
      let taps = 0, left = 5.0, iv = null, started = false;
      stage.innerHTML = `
        <div class="mg-big" id="mgScore">0かい</div>
        <div class="mg-sub" id="mgTime">のこり 5.0びょう</div>
        <button class="mg-tap mg-rushbtn" id="mgRush">れんだ！！</button>`;
      const btn = stage.querySelector('#mgRush');
      btn.onclick = ()=>{
        if(!started){
          started = true;
          iv = setInterval(()=>{
            left -= 0.1;
            stage.querySelector('#mgTime').textContent = 'のこり ' + Math.max(0,left).toFixed(1) + 'びょう';
            if(left<=0){ clearInterval(iv); btn.disabled = true; sfx.coin(); setTimeout(()=>resolve(taps*3), 600); }
          },100);
        }
        if(left>0){ taps++; sfx.tick(); stage.querySelector('#mgScore').textContent = taps + 'かい'; }
      };
      setTimeout(()=>{ if(!started){ clearInterval(iv); resolve(0); } }, 8000);  // 触らず8秒で0点終了
    });
  }

  /* ---------- 3. すうじおぼえ ---------- */
  function gMemory(stage, seed, sfx){
    return new Promise(resolve=>{
      const R = rng(seed);
      const answer = Array.from({length:6}, ()=>Math.floor(R()*10)).join('');
      let input = '', ended = false, tmo = null;
      stage.innerHTML = `<div class="mg-big" id="mgNum" style="letter-spacing:8px;">${answer}</div><div class="mg-sub">おぼえて！</div>`;
      setTimeout(()=>{
        if(ended) return;
        const keys = [1,2,3,4,5,6,7,8,9,'⌫',0,'OK'];
        stage.innerHTML = `
          <div class="mg-big" id="mgNum" style="letter-spacing:8px;">______</div>
          <div class="mg-sub">さっきの6けたは？（15びょう）</div>
          <div class="mg-pad">${keys.map(k=>`<button class="mg-tap mg-key" data-k="${k}">${k}</button>`).join('')}</div>`;
        const numEl = stage.querySelector('#mgNum');
        stage.querySelectorAll('.mg-key').forEach(b=>b.onclick=()=>{
          const k = b.dataset.k;
          if(k==='OK'){ finish(); return; }
          if(k==='⌫'){ input = input.slice(0,-1); }
          else if(input.length<6){ input += k; sfx.tick(); }
          numEl.textContent = (input + '______').slice(0,6);
          if(input.length===6) finish();
        });
        tmo = setTimeout(finish, 15000);
      }, 2200);
      function finish(){
        if(ended) return; ended = true; clearTimeout(tmo);
        let pts = 0;
        for(let i=0;i<6;i++){ if(input[i]===answer[i]) pts += 25; }
        if(pts>=150) sfx.coin(); else if(pts>0) sfx.tick(); else sfx.bad();
        flash(stage, `こたえ ${answer} → ${pts}てん`);
        setTimeout(()=>resolve(pts), 1100);
      }
    });
  }

  /* ---------- 4. ハイ&ロー ---------- */
  function gHighlow(stage, seed, sfx){
    return new Promise(resolve=>{
      const R = rng(seed);
      const cards = Array.from({length:6}, ()=>1+Math.floor(R()*13));
      const face = v => ({1:'A',11:'J',12:'Q',13:'K'}[v] || String(v));
      let i = 0, score = 0, tmo = null, ended = false;
      function show(){
        if(i>=5){ ended=true; clearTimeout(tmo); setTimeout(()=>resolve(score),500); return; }
        stage.innerHTML = `
          <div class="mg-sub">${i+1}/5 もん ・ いまのカードより…</div>
          <div class="mg-cardface">${face(cards[i])}</div>
          <div class="mg-row">
            <button class="mg-tap mg-hl" data-g="up">⬆️ おおきい</button>
            <button class="mg-tap mg-hl" data-g="down">⬇️ ちいさい</button>
          </div>
          <div class="mg-sub" id="mgHLScore">${score}てん</div>`;
        stage.querySelectorAll('.mg-hl').forEach(b=>b.onclick=()=>pick(b.dataset.g));
        clearTimeout(tmo); tmo = setTimeout(()=>pick(null), 6000);  // 6秒未回答=ハズレ扱い
      }
      function pick(g){
        if(ended) return;
        const a = cards[i], b = cards[i+1];
        const correct = (g==='up' && b>=a) || (g==='down' && b<=a);
        if(correct){ score += 30; sfx.coin(); flash(stage, `${face(b)}！ せいかい ＋30`); }
        else { sfx.bad(); flash(stage, `${face(b)}… はずれ`); }
        i++;
        setTimeout(show, 850);
      }
      show();
    });
  }

  /* ---------- 5. あとだしじゃんけん ---------- */
  function gJanken(stage, seed, sfx){
    return new Promise(resolve=>{
      const R = rng(seed);
      const HANDS = ['✊','✌️','✋'];
      const WIN  = {'✊':'✋','✌️':'✊','✋':'✌️'};  // 相手の手 → 勝てる手
      const LOSE = {'✊':'✌️','✌️':'✋','✋':'✊'};  // 相手の手 → 負ける手
      let i = 0, score = 0, tmo = null, ended = false;
      function show(){
        if(i>=5){ ended=true; clearTimeout(tmo); setTimeout(()=>resolve(score),500); return; }
        const opp = HANDS[Math.floor(R()*3)];
        const mustWin = R() < 0.5;
        stage.innerHTML = `
          <div class="mg-sub">${i+1}/5 もん</div>
          <div class="mg-cardface">${opp}</div>
          <div class="mg-big" style="font-size:26px;">${mustWin?'🔥 かって！':'💧 まけて！'}</div>
          <div class="mg-row">${HANDS.map(h=>`<button class="mg-tap mg-hand" data-h="${h}">${h}</button>`).join('')}</div>
          <div class="mg-sub" id="mgJScore">${score}てん</div>`;
        const need = mustWin ? WIN[opp] : LOSE[opp];
        stage.querySelectorAll('.mg-hand').forEach(b=>b.onclick=()=>pick(b.dataset.h, need));
        clearTimeout(tmo); tmo = setTimeout(()=>pick(null, need), 3500);  // 3.5秒で時間切れ
      }
      function pick(h, need){
        if(ended) return;
        if(h === need){ score += 30; sfx.coin(); flash(stage,'せいかい ＋30'); }
        else { sfx.bad(); flash(stage, h===null?'じかんぎれ…':'まちがい…'); }
        i++;
        setTimeout(show, 800);
      }
      show();
    });
  }

  /* 一瞬のフィードバック表示 */
  function flash(stage, text){
    const f = document.createElement('div');
    f.className = 'mg-flash';
    f.textContent = text;
    stage.appendChild(f);
    setTimeout(()=>f.remove(), 950);
  }

  const GAMES = { timing:gTiming, taprush:gTaprush, memory:gMemory, highlow:gHighlow, janken:gJanken };

  function play(stage, key, seed, sfx){
    const fn = GAMES[key] || gTaprush;
    try{
      return fn(stage, seed, sfx).then(s => Math.max(0, Math.round(s||0)));
    }catch(e){
      return Promise.resolve(0);
    }
  }

  return { META, KEYS, play };
})();
