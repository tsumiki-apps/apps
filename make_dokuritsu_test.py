#!/usr/bin/env python3
"""dokuritsu.html から「検証用の複製」を作る。
   ・Supabase を切る（sb=null）  ・localStorage のキーを別にする＋data:URL用にメモリ差し替え
   ・作り話のデータを流し込む      → 本物のデータには一切触れない
"""
import json, re, sys

SRC = '/Users/ko_dai/制作物/dokuritsu.html'
DST = '/Users/ko_dai/制作物/dokuritsu_test.html'
src = open(SRC, encoding='utf-8').read()

src2 = src.replace(
    "const sb = (window.supabase && window.supabase.createClient) ? supabase.createClient(SUPABASE_URL, SUPABASE_ANON) : null;",
    "const sb = null; /* TEST: クラウド同期は切ってある */", 1)
assert src2 != src, 'sb'
src = src2

shim = """const KEY = 'tsumiki_dokuritsu_TESTCOPY';
/* TEST ONLY：data: URL では localStorage が使えないので、その場合だけメモリ上の入れ物に差し替える */
try{ localStorage.getItem('__probe__'); }catch(e){
  const _mem={};
  Object.defineProperty(window,'localStorage',{value:{
    getItem:k=>(k in _mem ? _mem[k] : null),
    setItem:(k,v)=>{ _mem[k]=String(v); },
    removeItem:k=>{ delete _mem[k]; },
    clear:()=>{ Object.keys(_mem).forEach(k=>delete _mem[k]); }
  }});
}"""
src2 = src.replace("const KEY = 'tsumiki_dokuritsu_v3';", shim, 1)
assert src2 != src, 'KEY'
src = src2


def act(i, text, due, dueTo='', done=False, ask=False, thread=None):
    a = {"id": "a%02d" % i, "text": text, "done": done, "due": due, "dueTo": dueTo,
         "draftId": "", "thread": thread or []}
    if ask:
        a["ask"] = True
    return a


data = {
 "v": 3,
 "vision": {"slogan": "カチカチ → 勝ち価値 → 勝って価値をつくる", "title": "（テスト）卒業して事業へ移る", "deadline": "2026-12-31"},
 "months": [
  {"ym": "2026-08", "goal": "有料の1件目を取る", "status": "", "note": "", "phase": "Phase 1 ｜ 需要の証明",
   "must": [{"id": "m1", "text": "見積りを1本送る", "done": True}, {"id": "m2", "text": "会う日を1つ決める", "done": False}],
   "want": [{"id": "m3", "text": "名簿を50件にする", "done": False}]},
  {"ym": "2026-09", "goal": "保守の話を1件出す", "status": "", "note": "", "phase": "Phase 1 ｜ 需要の証明", "must": [], "want": []},
  {"ym": "2026-10", "goal": "月商10万を超える", "status": "", "note": "", "phase": "Phase 2 ｜ 現金化と床づくり", "must": [], "want": []},
  {"ym": "2026-11", "goal": "保守を3件そろえる", "status": "", "note": "", "phase": "Phase 2 ｜ 現金化と床づくり", "must": [], "want": []},
  {"ym": "2026-12", "goal": "独立の可否を決める", "status": "", "note": "", "phase": "Phase 3 ｜ 独立判断", "must": [], "want": []}],
 "meters": {"paid": {"v": 1, "goal": 5}, "floor": {"v": 0, "goal": 3}, "sales": {"v": 8, "goal": 40}, "cash": {"v": 15, "goal": 100}},
 "moves": {"2026-08-11": 2, "2026-08-13": 1, "2026-08-16": 1},
 "weeks": {
  "2026-08-09": {"win": {"text": "たたき台を1本送る", "done": True}, "review": None, "tasks": [
    {"id": "t1", "text": "見積りの型をつくる", "target": 2, "count": 1, "actions": [
      act(1, "たたき台をA社へ送る", "2026-08-11", done=True),
      act(2, "返事をもらって直す", "2026-08-13")]}]},
  "2026-08-16": {"win": {"text": "金額を書いた見積りを1本送った", "done": False}, "review": None, "tasks": [
    {"id": "t2", "text": "金額を書いた見積りを送る", "target": 3, "count": 0, "actions": [
      act(3, "A社へ金額入りで送る", "2026-08-16"),
      act(4, "B社へ送る（先方の休みを避ける）", "2026-08-17", "2026-08-19"),
      act(5, "請求書テンプレートを見てOKする", "2026-08-18", ask=True,
          thread=[{"id": "m1", "who": "me", "text": "請求書のひな形を3案つくってほしい", "tag": "", "at": "2026-08-15", "seen": True}])]},
    {"id": "t3", "text": "名簿をつくる", "target": 1, "count": 0, "actions": [
      act(6, "20件まで書き出す", "2026-08-19", "2026-08-21")]}]},
  "2026-08-23": {"win": {"text": "会って次の約束まで取る", "done": False}, "review": None, "tasks": [
    {"id": "t4", "text": "会って話す", "target": 2, "count": 0, "actions": [
      act(7, "C社と会う", "2026-08-23"),
      act(8, "お礼と提案を送る", "2026-08-24", "2026-08-25")]}]},
  "2026-09-06": {"win": None, "review": None, "tasks": [
    {"id": "t5", "text": "9月の設計", "target": 1, "count": 0, "actions": [
      act(9, "保守の案内を送る", "2026-09-08", "2026-09-12")]}]},
  "2026-10-04": {"win": None, "review": None, "tasks": [
    {"id": "t6", "text": "秋の販路をひらく", "target": 1, "count": 0, "actions": [
      act(10, "紹介まわりを一巡する", "2026-10-06", "2026-10-20")]}]}},
 "drafts": [], "jiyuIn": True, "settings": {"reviewHour": 17}}

seed = ("\n/* ===== TEST ONLY：作り話のデータを、テスト用キーが空のときだけ入れる ===== */\n"
        "if(!localStorage.getItem(KEY)) localStorage.setItem(KEY, JSON.stringify(%s));\nloadLocal();"
        % json.dumps(data, ensure_ascii=False))
src2 = src.replace("\nloadLocal();\nrender();", seed + "\nrender();", 1)
assert src2 != src, 'seed'
src = src2

open(DST, 'w', encoding='utf-8').write(src)
print('wrote', DST, len(src))
