/* ============================================================================
 * クレジット明細マネージャー — Amazon注文 ワンタップ取り込み ブックマークレット
 * ----------------------------------------------------------------------------
 * 使い方（Macでの取り込み前提）:
 *   1. amazon.co.jp にログインし「注文履歴」ページを開く
 *      （https://www.amazon.co.jp/gp/css/order-history など）
 *   2. このブックマークレットをタップ
 *   3. 「今表示中のページ」の注文を読み取り、Supabase(credit_state)へ
 *      注文番号ベースで追記マージ（既存は消さない）。確認ダイアログで件数表示。
 *   4. credit.html を開く/再読込すると（同期で）注文一覧に反映される。
 *
 * 重要な前提と限界:
 *   - 1ページに表示されている注文だけを取り込みます（ページ送り/年フィルタは都度実行）。
 *     取り込み後に「対象期間」を確認し、抜けがあれば別ページでも実行してください。
 *   - 取り込み中は credit.html を閉じておくと安全です（読込→書戻しの間に
 *     アプリ側が同じデータを更新すると、後勝ちで上書きが起き得るため）。
 *   - Amazonのページ構造が変わると拾えない可能性があります。0件や不正確なら
 *     注文履歴ページのHTMLをClaudeに渡してセレクタを直してもらってください。
 *   - 取り込みは追記マージのみ。読み込み(GET)が失敗したら書き込みは中止します
 *     （＝失敗時に既存データを空で潰しません）。
 *
 * ブックマークレット化:
 *   末尾の MINIFIED 1行（javascript:...）をブックマークのURLに貼り付け。
 *   ※ソース版とMINIFIED版は同じロジック。どちらを使ってもOK。
 * ========================================================================== */
(function(){
  var SUPABASE_URL='https://okbjqtdirrathscctyvx.supabase.co';
  var SUPABASE_ANON='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rYmpxdGRpcnJhdGhzY2N0eXZ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMjI4NTIsImV4cCI6MjA5NTg5ODg1Mn0.T-1AOK6vCD6uGdqrVGXjPui3L6WPSNrnygS-IHyfZ6Y';
  var STATE_ID='kodai';

  function hashStr(s){var h=0;for(var i=0;i<s.length;i++)h=((h<<5)-h+s.charCodeAt(i))|0;return Math.abs(h).toString(36);}
  function toHalf(s){return String(s||'').replace(/[０-９]/g,function(c){return String.fromCharCode(c.charCodeAt(0)-0xFEE0);});}
  function yen(s){var m=toHalf(s).replace(/[^0-9]/g,'');return m?parseInt(m,10):NaN;}

  function getCards(){
    var sels=['.order-card.js-order-card','.js-order-card','.order-card','[class*="order-card"]','.a-box-group.a-spacing-base'];
    for(var i=0;i<sels.length;i++){var n=document.querySelectorAll(sels[i]);if(n&&n.length)return [].slice.call(n);}
    var all=[].slice.call(document.querySelectorAll('div')).filter(function(d){return /注文番号|Order\s*#/.test(d.textContent||'')&&d.querySelector('a[href*="/dp/"],a[href*="/gp/product/"],a[href*="/product/"]');});
    return all.filter(function(d){return !all.some(function(o){return o!==d&&o.contains(d);});});
  }
  function parseCard(card){
    var txt=card.innerText||card.textContent||'';
    var dm=txt.match(/注文日[\s\S]{0,12}?(\d{4})年\s*(\d{1,2})月\s*(\d{1,2})日/)||txt.match(/(\d{4})年\s*(\d{1,2})月\s*(\d{1,2})日/);
    var orderDate='';
    if(dm){orderDate=toHalf(dm[1])+'/'+('0'+toHalf(dm[2])).slice(-2)+'/'+('0'+toHalf(dm[3])).slice(-2);}
    var om=txt.match(/注文番号[\s:：]*([0-9０-９\-]{10,})/)||txt.match(/Order\s*#\s*([0-9\-]{10,})/);
    var orderId=om?toHalf(om[1]).trim():'';
    var amount=NaN;
    var tm=txt.match(/(?:合計|注文合計|order\s*total)[\s\S]{0,12}?[￥¥]\s*([0-9,０-９]+)/i);
    if(tm)amount=yen(tm[1]);
    if(isNaN(amount)){var all=(txt.match(/[￥¥]\s*[0-9,０-９]+/g)||[]).map(yen).filter(function(n){return !isNaN(n);});if(all.length)amount=Math.max.apply(null,all);}
    var links=[].slice.call(card.querySelectorAll('a[href*="/dp/"],a[href*="/gp/product/"],a[href*="/product/"]'));
    var titles=[];
    links.forEach(function(a){var t=(a.innerText||a.textContent||'').replace(/\s+/g,' ').trim();if(t&&t.length>=3&&titles.indexOf(t)<0)titles.push(t);});
    var productName=titles.join(' / ');
    if(!orderDate||isNaN(amount)||!productName)return null;
    if(!orderId)orderId=orderDate+'__'+productName.slice(0,10)+'__'+amount;
    return {id:'ao_'+hashStr(orderId),orderId:orderId,orderDate:orderDate,productName:productName,amount:amount,deliveryTo:'',memo:''};
  }

  var cards=getCards(),orders=[],seen={};
  cards.forEach(function(c){var o=parseCard(c);if(o&&!seen[o.id]){seen[o.id]=1;orders.push(o);}});
  if(!orders.length){alert('Amazon注文を読み取れませんでした。\n\n・「注文履歴」ページで実行していますか？\n・ログイン済みですか？\n\n改善するには、このページのHTMLをClaudeに渡してセレクタを直してください。');return;}

  var ds=orders.map(function(o){return o.orderDate;}).sort();
  if(!confirm('このページから '+orders.length+' 件の注文を読み取りました。\n対象期間: '+ds[0]+' 〜 '+ds[ds.length-1]+'\n\nSupabaseへ取り込みますか？（既存データは消さず追記マージ）\n※取り込み中は credit.html を閉じておくと安全です。'))return;

  var H={'apikey':SUPABASE_ANON,'Authorization':'Bearer '+SUPABASE_ANON,'Content-Type':'application/json'};
  // 読込(GET)→直後に書戻し(POST)。GETが失敗したら書き込み中止＝既存を潰さない。
  fetch(SUPABASE_URL+'/rest/v1/credit_state?id=eq.'+STATE_ID+'&select=state',{headers:H})
    .then(function(r){if(!r.ok)throw new Error('既存データの読込に失敗（HTTP '+r.status+'）。書き込みを中止しました。');return r.json();})
    .then(function(rows){
      if(!Array.isArray(rows))throw new Error('予期しない応答のため書き込みを中止しました。');
      var row=rows[0],state;
      if(row){ // 行が存在するのにstateが読めない＝破損の恐れ→潰さず中止
        if(row.state&&typeof row.state==='object')state=row.state;
        else throw new Error('既存データが正しく読めません。書き込みを中止しました。');
      } else { // 行が無い初回のみ空で初期化
        state={months:{},amazonOrders:[],loans:[],payments:[],people:[]};
      }
      if(!Array.isArray(state.amazonOrders))state.amazonOrders=[];
      var map={};state.amazonOrders.forEach(function(o){map[o.id]=o;});
      var added=0,updated=0;
      orders.forEach(function(o){if(map[o.id]){map[o.id].orderDate=o.orderDate;map[o.id].productName=o.productName;map[o.id].amount=o.amount;updated++;}else{state.amazonOrders.push(o);map[o.id]=o;added++;}});
      state.updatedAt=Date.now();
      return fetch(SUPABASE_URL+'/rest/v1/credit_state?on_conflict=id',{method:'POST',headers:Object.assign({},H,{'Prefer':'resolution=merge-duplicates,return=minimal'}),body:JSON.stringify({id:STATE_ID,state:state,updated_at:new Date().toISOString()})})
        .then(function(res){if(!res.ok)throw new Error('保存に失敗（HTTP '+res.status+'）');alert('取り込み完了！\n新規 '+added+' 件 / 更新 '+updated+' 件\n\ncredit.html を開く（または再読込）と反映されます。');});
    })
    .catch(function(e){alert(e.message||('エラー: '+e));});
})();

/* ===== MINIFIED（この1行をブックマークのURLに貼る／ソース版と同一ロジック） =====
javascript:(function(){var U='https://okbjqtdirrathscctyvx.supabase.co',K='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rYmpxdGRpcnJhdGhzY2N0eXZ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMjI4NTIsImV4cCI6MjA5NTg5ODg1Mn0.T-1AOK6vCD6uGdqrVGXjPui3L6WPSNrnygS-IHyfZ6Y',I='kodai';function h(s){var x=0;for(var i=0;i<s.length;i++)x=((x<<5)-x+s.charCodeAt(i))|0;return Math.abs(x).toString(36);}function hf(s){return String(s||'').replace(/[０-９]/g,function(c){return String.fromCharCode(c.charCodeAt(0)-0xFEE0);});}function y(s){var m=hf(s).replace(/[^0-9]/g,'');return m?parseInt(m,10):NaN;}function gc(){var S=['.order-card.js-order-card','.js-order-card','.order-card','[class*="order-card"]','.a-box-group.a-spacing-base'];for(var i=0;i<S.length;i++){var n=document.querySelectorAll(S[i]);if(n&&n.length)return[].slice.call(n);}var a=[].slice.call(document.querySelectorAll('div')).filter(function(d){return /注文番号|Order\s*#/.test(d.textContent||'')&&d.querySelector('a[href*="/dp/"],a[href*="/gp/product/"],a[href*="/product/"]');});return a.filter(function(d){return!a.some(function(o){return o!==d&&o.contains(d);});});}function pc(c){var t=c.innerText||c.textContent||'';var dm=t.match(/注文日[\s\S]{0,12}?(\d{4})年\s*(\d{1,2})月\s*(\d{1,2})日/)||t.match(/(\d{4})年\s*(\d{1,2})月\s*(\d{1,2})日/);var od='';if(dm){od=hf(dm[1])+'/'+('0'+hf(dm[2])).slice(-2)+'/'+('0'+hf(dm[3])).slice(-2);}var om=t.match(/注文番号[\s:：]*([0-9０-９\-]{10,})/)||t.match(/Order\s*#\s*([0-9\-]{10,})/);var oid=om?hf(om[1]).trim():'';var am=NaN;var tm=t.match(/(?:合計|注文合計|order\s*total)[\s\S]{0,12}?[￥¥]\s*([0-9,０-９]+)/i);if(tm)am=y(tm[1]);if(isNaN(am)){var al=(t.match(/[￥¥]\s*[0-9,０-９]+/g)||[]).map(y).filter(function(n){return!isNaN(n);});if(al.length)am=Math.max.apply(null,al);}var L=[].slice.call(c.querySelectorAll('a[href*="/dp/"],a[href*="/gp/product/"],a[href*="/product/"]')),ti=[];L.forEach(function(a){var x=(a.innerText||a.textContent||'').replace(/\s+/g,' ').trim();if(x&&x.length>=3&&ti.indexOf(x)<0)ti.push(x);});var pn=ti.join(' / ');if(!od||isNaN(am)||!pn)return null;if(!oid)oid=od+'__'+pn.slice(0,10)+'__'+am;return{id:'ao_'+h(oid),orderId:oid,orderDate:od,productName:pn,amount:am,deliveryTo:'',memo:''};}var C=gc(),O=[],s={};C.forEach(function(c){var o=pc(c);if(o&&!s[o.id]){s[o.id]=1;O.push(o);}});if(!O.length){alert('Amazon注文を読み取れませんでした。注文履歴ページでログイン済みか確認してください。');return;}var ds=O.map(function(o){return o.orderDate;}).sort();if(!confirm('このページから '+O.length+' 件読み取り。\n期間 '+ds[0]+'〜'+ds[ds.length-1]+'\n取り込みますか？（追記マージ。取込中はcredit.htmlを閉じると安全）'))return;var H={'apikey':K,'Authorization':'Bearer '+K,'Content-Type':'application/json'};fetch(U+'/rest/v1/credit_state?id=eq.'+I+'&select=state',{headers:H}).then(function(r){if(!r.ok)throw new Error('読込失敗(HTTP '+r.status+')のため書込中止');return r.json();}).then(function(rw){if(!Array.isArray(rw))throw new Error('予期しない応答のため書込中止');var row=rw[0],st;if(row){if(row.state&&typeof row.state=='object')st=row.state;else throw new Error('既存データが読めないため書込中止');}else{st={months:{},amazonOrders:[],loans:[],payments:[],people:[]};}if(!Array.isArray(st.amazonOrders))st.amazonOrders=[];var m={};st.amazonOrders.forEach(function(o){m[o.id]=o;});var a=0,u=0;O.forEach(function(o){if(m[o.id]){m[o.id].orderDate=o.orderDate;m[o.id].productName=o.productName;m[o.id].amount=o.amount;u++;}else{st.amazonOrders.push(o);m[o.id]=o;a++;}});st.updatedAt=Date.now();return fetch(U+'/rest/v1/credit_state?on_conflict=id',{method:'POST',headers:Object.assign({},H,{'Prefer':'resolution=merge-duplicates,return=minimal'}),body:JSON.stringify({id:I,state:st,updated_at:new Date().toISOString()})}).then(function(res){if(!res.ok)throw new Error('保存失敗(HTTP '+res.status+')');alert('取り込み完了！新規 '+a+' 件 / 更新 '+u+' 件。credit.htmlを再読込で反映。');});}).catch(function(e){alert(e.message||('エラー:'+e));});})();
===== */
