# -*- coding: utf-8 -*-
"""撮影用のニセ通信を注入した複製を作る。
本番のデータベースには一切つながらない（window.fetch を差し替えて、その場で作った作り話を返すだけ）。
名前・お店・合言葉はすべて架空。"""
import json, datetime, random, pathlib, sys

TOOLS = pathlib.Path.home()/ "tsumiki-tools"
OUT   = pathlib.Path(sys.argv[1])

Y, M = 2026, 10
SHOP = "せんや高崎インター店"
NAMES = ["やまだ はな","さとう けんた","すずき あおい","たなか みなと",
         "いとう さくら","わたなべ りく","こばやし ゆい","なかむら そう","よしだ めい"]
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

ASCENES={"open":amonth(),"kime":amonth(assigned=True),"pub":amonth(published=True,assigned=True),
         "req":amonth(assigned=True,reqs=True),"empty":amonth(submitted=False),
         "nostaff":amonth(staffed=False),"sending":amonth(sending=True),
         "paused":amonth(paused=True)}
ALOGINS={"past":dict(ALOGIN,today=f"{Y}-09-22")}

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
    AMOCK+(TOOLS/"tsumiki-senya-kanri.html").read_text(encoding="utf-8"), encoding="utf-8")

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
    SMOCK+(TOOLS/"tsumiki-senya.html").read_text(encoding="utf-8"), encoding="utf-8")

print("ok  staff=%d avail=%d assign=%d  やまだ:出した%d日 シフト%d日"
      %(len(staff),len(avail),len(assign),len(set(r["d"] for r in mine)),len(set(r["d"] for r in myasg))))
