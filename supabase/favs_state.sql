-- つみきハブ（index.html）の「よく使う（お気に入り）」の端末間同期用テーブル。
-- tsugi_state / recognition_state と同じ「個人用フルアクセス」方式。
-- プロジェクト: okbjqtdirrathscctyvx（career_log などと同じ）

create table if not exists public.favs_state (
  id text primary key,                 -- 個人用なので 'kodai' 固定の1行
  state jsonb,                         -- { favs: ["credit","yuzuwari", ...] }
  updated_at timestamptz default now() -- Last-Write-Wins 用の最終更新時刻
);

alter table public.favs_state enable row level security;

-- 完全に個人用途のためのフルアクセスポリシー（anon キーで読み書き可）
create policy "favs_personal_full_access"
  on public.favs_state
  for all
  to anon
  using (true)
  with check (true);
