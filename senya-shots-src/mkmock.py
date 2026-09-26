# -*- coding: utf-8 -*-
"""撮影用のニセ通信を注入した複製を作る。
本番のデータベースには一切つながらない（window.fetch を差し替えて、その場で作った作り話を返すだけ）。
名前・お店・合言葉はすべて架空。"""
import json, datetime, random, pathlib, sys

TOOLS = pathlib.Path.home()/ "tsumiki-tools"
OUT   = pathlib.Path(sys.argv[1])

Y, M = 2026, 10
SHOP = "みなみ食堂"   # 架空のお店（実在のお客様の店名は絶対に使わない。説明書は公開ページ）
NAMES = ["やまだ はな","さとう けんた","すずき あおい","たなか みなと",
         "いとう さくら","わたなべ りく","こばやし みお","なかむら そう","よしだ めい"]
CODES = ["SAMPLE","SAMPL2","SAMPL3","SAMPL4","SAMPL5","SAMPL6","SAMPL7","SAMPL8","SAMPL9"]
SLOTS = [{"k":"day","label":"昼","from":660,"to":870,"need":2},
         {"k":"night","label":"夜","from":1050,"to":1260,"need":3}]
CLOSED = [1]                    # 月曜定休
SHORT_DAYS = [8,9,10,13,30]     # 夜が1人足りない日

last = (datetime.date(Y,M,1) + datetime.timedelta(days=32)).replace(day=1) - datetime.timedelta(days=1)
LAST = last.day
def dow(d): return (datetime.date(Y,M,d).weekday()+1)%7   # 0=日
def key(d): return f"{Y}-{M:02d}-{d:02d}"

rnd = random.Random(20261031)
staff=[{"id":f"s{i+1}","name":n,"code":c,"active":True,"sent":True,
        "days":0,"done":True,"fixed_days":0,"fixed_min":0}
       for i,(n,c) in enumerate(zip(NAMES,CODES))]

avail=[]; per={s["id"]:set() for s in staff}
for d in range(1,LAST+1):
    if dow(d)==1: continue
    ids=[s["id"] for s in staff]; rnd.shuffle(ids)
    n_night = 2 if d in SHORT_DAYS else rnd.choice([3,3,4,4,5])
    n_day   = rnd.choice([2,3,3,4])
    night=ids[:n_night]; day=ids[n_night:n_night+n_day]
    if d%4==0 and night and day: day=day[:-1]+[night[0]]
    for sid in night:
        avail.append({"d":key(d),"staff_id":sid,"k":"night","from":1050,"to":1260,"mark":"o"}); per[sid].add(d)
    for sid in day:
        avail.append({"d":key(d),"staff_id":sid,"k":"day","from":660,"to":870,"mark":"o"}); per[sid].add(d)
    rest=[i for i in ids if i not in night and i not in day]
    for sid in rest[:(1 if d%3 else 2)]:
        k="night" if d%2 else "day"; sl=SLOTS[1] if k=="night" else SLOTS[0]
        avail.append({"d":key(d),"staff_id":sid,"k":k,"from":sl["from"],"to":sl["to"],"mark":"t"}); per[sid].add(d)
for s in staff: s["days"]=len(per[s["id"]])

# 決まったシフト
assign=[]; fx={s["id"]:[0,0] for s in staff}; by={}
for a in avail:
    if a["mark"]!="o": continue
    by.setdefault((a["d"],a["k"]),[]).append(a)
for d in range(1,LAST+1):
    if dow(d)==1: continue
    for sl in SLOTS:
        cand=sorted(by.get((key(d),sl["k"]),[]),key=lambda a:(fx[a["staff_id"]][0],a["staff_id"]))
        for a in cand[:sl["need"]]:
            assign.append({"d":key(d),"staff_id":a["staff_id"],"k":sl["k"],"from":sl["from"],"to":sl["to"]})
            fx[a["staff_id"]][0]+=1; fx[a["staff_id"]][1]+=sl["to"]-sl["from"]
staff_fx=[dict(s,fixed_days=fx[s["id"]][0],fixed_min=fx[s["id"]][1]) for s in staff]

REQUESTS=[
 {"id":"r1","staff_id":"s2","name":"さとう けんた","d":key(9), "k":"night","kind":"drop","note":"急な用ができてしまいました"},
 {"id":"r2","staff_id":"s5","name":"いとう さくら","d":key(13),"k":"night","kind":"add", "note":""},
]

# ================= 店長アプリ =================
ALOGIN={"mode":"shop","is_master":False,"shop_id":"demo-shop","name":SHOP,
        "deadline_day":20,"slots":SLOTS,"closed_wdays":CLOSED,
        "open_month":f"{Y}-{M:02d}","today":f"{Y}-09-18"}

def amonth(published=False, assigned=False, reqs=False, submitted=True,
           staffed=True, sending=False, paused=False):
    st = staff_fx if assigned else staff
    if not submitted: st=[dict(s,days=0,done=False,fixed_days=0,fixed_min=0) for s in staff]
    if sending:
        st=[dict(s,days=0,done=False,fixed_days=0,fixed_min=0,sent=(i<5)) for i,s in enumerate(staff)]
    if paused: st=[dict(s, active=(s["id"]!="s4")) for s in st]
    if not staffed: st=[]
    return {"month":f"{Y}-{M:02d}","deadline":f"{Y}-09-20","published":published,
            "assign_updated":"2026-09-19 02:10" if published else None,
            "staff":st,"avail":avail if (submitted and staffed and not sending) else [],
            "dayneeds":[],"assign":assign if assigned else [],
            "requests":REQUESTS if reqs else []}


# ===== 月まるごと入れた直後（○の希望を全部シフトに入れた状態・減らす前） =====
assign_all=[]; fx2={s["id"]:[0,0] for s in staff}
for a in avail:
    if a["mark"]!="o": continue
    assign_all.append({"d":a["d"],"staff_id":a["staff_id"],"k":a["k"],"from":a["from"],"to":a["to"]})
    fx2[a["staff_id"]][1]+=a["to"]-a["from"]
for s in staff:
    fx2[s["id"]][0]=len({a["d"] for a in assign_all if a["staff_id"]==s["id"]})
staff_all=[dict(s,fixed_days=fx2[s["id"]][0],fixed_min=fx2[s["id"]][1]) for s in staff]
MARU={"month":f"{Y}-{M:02d}","deadline":f"{Y}-09-20","published":False,"assign_updated":None,
      "staff":staff_all,"avail":avail,"dayneeds":[],"assign":assign_all,"requests":[]}

# ===== ご相談用：時間帯4つ（昼①昼②・夜①夜②が重なる）で、同じ方が両方に出している =====
FOUR=[{"k":"s1","label":"昼①","from":570,"to":870,"need":1},{"k":"day","label":"昼②","from":600,"to":870,"need":2},
      {"k":"s3","label":"夜①","from":1020,"to":1260,"need":1},{"k":"night","label":"夜②","from":1050,"to":1260,"need":2}]
PAT4=[("s1","s1"),("s1","day"),("s2","day"),("s3","s3"),("s3","night"),("s4","night")]
av4=[]
for d in range(1,LAST+1):
    if dow(d)==1: continue
    for sid,k in PAT4:
        sl=[x for x in FOUR if x["k"]==k][0]
        av4.append({"d":key(d),"staff_id":sid,"k":k,"from":sl["from"],"to":sl["to"],"mark":"o"})
st4=[dict(s,days=(len(range(1,LAST+1))-5 if s["id"] in ("s1","s2","s3","s4") else 0),done=s["id"] in ("s1","s2","s3","s4"),fixed_days=0,fixed_min=0) for s in staff]
FOURM={"month":f"{Y}-{M:02d}","deadline":f"{Y}-09-20","published":False,"assign_updated":None,
       "staff":st4,"avail":av4,"dayneeds":[],"assign":[],"requests":[]}
# ===== ご相談用：昼・夜の2つにまとめ、何時から入るかを1人ずつ変えた形 =====
TWO=[{"k":"day","label":"昼","from":570,"to":870,"need":3},{"k":"night","label":"夜","from":1020,"to":1260,"need":3}]
PAT2=[("s1","day",570),("s2","day",600),("s3","day",600),("s4","night",1020),("s5","night",1050),("s6","night",1050)]
av2=[];as2=[]
for d in range(1,LAST+1):
    if dow(d)==1: continue
    for sid,k,f in PAT2:
        t=870 if k=="day" else 1260
        av2.append({"d":key(d),"staff_id":sid,"k":k,"from":f,"to":t,"mark":"o"})
        as2.append({"d":key(d),"staff_id":sid,"k":k,"from":f,"to":t})
st2=[dict(s,days=(26 if s["id"] in ("s1","s2","s3","s4","s5","s6") else 0),done=True,fixed_days=(26 if s["id"] in ("s1","s2","s3","s4","s5","s6") else 0),fixed_min=0) for s in staff]
TWOM={"month":f"{Y}-{M:02d}","deadline":f"{Y}-09-20","published":False,"assign_updated":None,
      "staff":st2,"avail":av2,"dayneeds":[],"assign":as2,"requests":[]}

# ===== ご相談用：昼だけ・夜だけ・両方足りない日がまざる（昼・夜の2つ、どちらも3人） =====
avm=[]
for d in range(1,LAST+1):
    if dow(d)==1: continue
    nd = 2 if d%5 in (1,3) else 3          # 昼が足りない日
    nn = 2 if d%7 in (2,5) else 3          # 夜が足りない日
    for i in range(nd): avm.append({"d":key(d),"staff_id":f"s{i+1}","k":"day","from":570,"to":870,"mark":"o"})
    for i in range(nn): avm.append({"d":key(d),"staff_id":f"s{i+4}","k":"night","from":1020,"to":1260,"mark":"o"})
MIXM={"month":f"{Y}-{M:02d}","deadline":f"{Y}-09-20","published":False,"assign_updated":None,
      "staff":[dict(s,days=20,done=True) for s in staff],"avail":avm,"dayneeds":[],"assign":[],"requests":[]}

ASCENES={"mix":MIXM,"four":FOURM,"two":TWOM,"maru":MARU,"open":amonth(),"kime":amonth(assigned=True),"pub":amonth(published=True,assigned=True),
         "req":amonth(assigned=True,reqs=True),"empty":amonth(submitted=False),
         "nostaff":amonth(staffed=False),"sending":amonth(sending=True),
         "paused":amonth(paused=True)}
ALOGINS={"past":dict(ALOGIN,today=f"{Y}-09-22"),"now":dict(ALOGIN,today=f"{Y}-09-25"),"four":dict(ALOGIN,slots=FOUR,today=f"{Y}-09-26"),"two":dict(ALOGIN,slots=TWO,today=f"{Y}-09-26")}

AMOCK = """<script>
/* ===== 撮影用のニセの通信（本番のデータベースには一切つながらない。名前もお店も架空） ===== */
(function(){
  var LOGIN=%s, SCENES=%s, LOGINS=%s, SHOP=%s;
  var q=new URLSearchParams(location.search);
  var scene=q.get('scene')||'open';
  var login=LOGINS[q.get('login')]||LOGIN;
  try{
    if(q.get('lic')==='1'){ localStorage.removeItem('tsumiki-lic-token:tsumiki-senya'); }
    else{ localStorage.setItem('tsumiki-lic-token:tsumiki-senya','DEMO');
          localStorage.setItem('tsumiki-lic-customer:tsumiki-senya',SHOP); }
    if(q.get('tut')==='1'){ localStorage.removeItem('tsumiki_senya_ktut_demo-shop');
                            localStorage.removeItem('tsumiki_senya_ktut2_demo-shop'); }
    else{ localStorage.setItem('tsumiki_senya_ktut_demo-shop','done');
          localStorage.setItem('tsumiki_senya_ktut2_demo-shop','done');
          localStorage.setItem('tsumiki_senya_ktip_demo-shop','req,publish'); }
    localStorage.setItem('tsumiki_senya_ka2hs','1');
    if(q.get('anon')==='1'){ localStorage.removeItem('tsumiki_senya_admin');
                             localStorage.removeItem('tsumiki_senya_shop'); }
    else{ localStorage.setItem('tsumiki_senya_admin','SAMPLE47');
          localStorage.setItem('tsumiki_senya_shop','demo-shop'); }
  }catch(e){}
  var real=window.fetch;
  window.fetch=function(u,o){
    var url=String(u);
    if(url.indexOf('/rest/v1/rpc/')<0) return real.apply(this,arguments);
    var fn=url.split('/rest/v1/rpc/')[1], body={ok:true};
    if(fn==='kibo_admin_login') body=login;
    else if(fn==='kibo_admin_month') body=SCENES[scene];
    else if(fn==='license_verify') body={ok:true,customer:SHOP};
    else if(fn==='license_activate') body={ok:true,token:'DEMO',customer:SHOP};
    return Promise.resolve(new Response(JSON.stringify(body),
      {status:200, headers:{'Content-Type':'application/json'}}));
  };
})();
</script>
""" % (json.dumps(ALOGIN,ensure_ascii=False), json.dumps(ASCENES,ensure_ascii=False),
       json.dumps(ALOGINS,ensure_ascii=False), json.dumps(SHOP,ensure_ascii=False))

(OUT/"_テスト用_senya-kanri.html").write_text(
    '<meta charset="utf-8">\n'+AMOCK+(TOOLS/"tsumiki-senya-kanri.html").read_text(encoding="utf-8"), encoding="utf-8")

# ================= スタッフアプリ（やまだ はな＝s1） =================
ME="s1"
mine=[{"d":a["d"],"k":a["k"],"from":a["from"],"to":a["to"],"mark":a["mark"]}
      for a in avail if a["staff_id"]==ME]
myasg=[{"d":a["d"],"k":a["k"],"from":a["from"],"to":a["to"]} for a in assign if a["staff_id"]==ME]
USUAL=[{"wday":2,"k":"night","mark":"o"},{"wday":4,"k":"night","mark":"o"},
       {"wday":6,"k":"day","mark":"o"},{"wday":6,"k":"night","mark":"o"}]

SLOGIN={"staff_id":ME,"name":"やまだ はな","shop_name":SHOP,"deadline_day":20,
        "slots":SLOTS,"closed_wdays":CLOSED,"open_month":f"{Y}-{M:02d}","today":f"{Y}-09-18"}

def smonth(av=None,usual=None,submitted=False,published=False,editable=True,
           asg=None,reqs=None,today=f"{Y}-09-18"):
    return {"month":f"{Y}-{M:02d}","deadline":f"{Y}-09-20","editable":editable,"today":today,
            "submitted":submitted,"published":published,
            "assign_updated":"2026-09-19 02:10" if published else None,
            "avail":av or [],"usual":usual or [],"assign":asg or [],"requests":reqs or []}

SREQ=[{"id":"q1","d":key(9),"k":"night","kind":"drop","status":"open","note":""}]
SSCENES={
 "empty":  smonth(),
 "sheet":  smonth(av=mine,submitted=True),
 "time":   smonth(av=mine,submitted=True),
 "filled": smonth(av=mine,submitted=True),
 "usual":  smonth(av=mine,usual=USUAL,submitted=True),
 "usual0": smonth(usual=USUAL),
 "done":   smonth(av=mine,usual=USUAL,submitted=True,published=True,asg=myasg),
 "locked": smonth(av=mine,submitted=True,editable=False,today=f"{Y}-09-22"),
 "req":    smonth(av=mine,submitted=True,editable=False,today=f"{Y}-09-22",reqs=SREQ),
}
SMOCK = """<script>
/* ===== 撮影用のニセの通信（本番のデータベースには一切つながらない。名前もお店も架空） ===== */
(function(){
  var LOGIN=%s, SCENES=%s;
  var q=new URLSearchParams(location.search);
  var scene=q.get('scene')||'filled';
  try{
    if(q.get('a2hs')==='1'){ localStorage.removeItem('tsumiki_senya_a2hs'); }
    else{ localStorage.setItem('tsumiki_senya_a2hs','1'); }
    localStorage.setItem('tsumiki_senya_code','SAMPLE');
    if(q.get('tut')==='1'){ localStorage.removeItem('tsumiki_senya_tut_s1'); }
    else{ localStorage.setItem('tsumiki_senya_tut_s1','done');
          localStorage.setItem('tsumiki_senya_visit_s1','9');
          localStorage.setItem('tsumiki_senya_tip_s1','locked,kakutei,done,fill,a2hs'); }
  }catch(e){}
  var real=window.fetch;
  window.fetch=function(u,o){
    var url=String(u);
    if(url.indexOf('/rest/v1/rpc/')<0) return real.apply(this,arguments);
    var fn=url.split('/rest/v1/rpc/')[1];
    var body = fn==='kibo_staff_login' ? LOGIN
             : fn==='kibo_staff_month' ? SCENES[scene] : {ok:true};
    return Promise.resolve(new Response(JSON.stringify(body),
      {status:200, headers:{'Content-Type':'application/json'}}));
  };
})();
</script>
""" % (json.dumps(SLOGIN,ensure_ascii=False), json.dumps(SSCENES,ensure_ascii=False))

(OUT/"_テスト用_senya-staff.html").write_text(
    '<meta charset="utf-8">\n'+SMOCK+(TOOLS/"tsumiki-senya.html").read_text(encoding="utf-8"), encoding="utf-8")

print("ok  staff=%d avail=%d assign=%d  やまだ:出した%d日 シフト%d日"
      %(len(staff),len(avail),len(assign),len(set(r["d"] for r in mine)),len(set(r["d"] for r in myasg))))
