-- つみ木（曜日ごとの「幸せなこと」）の端末間同期用テーブル
-- 2026-09-15 に Supabase MCP から適用ずみ（okbjqtdirrathscctyvx）。控えとして置いている。

create table if not exists public.tsumigi_state (
  id text primary key,                          -- 個人利用なので 'kodai' 固定の1行
  state jsonb not null default '{}'::jsonb,     -- {items:{id:{...}}, dels:{id:時刻}, done:{日付|id:{on,upd}}}
  updated_at timestamptz not null default now()
);

-- 書くたびに1つ増える版番号。「読んだ版のままなら書く」で、2台の同時書き込みで片方が消えるのを防ぐ
alter table public.tsumigi_state add column if not exists rev bigint not null default 0;

alter table public.tsumigi_state enable row level security;

create policy "tsumigi_state anon all"
  on public.tsumigi_state for all to anon using (true) with check (true);

-- ほかの端末の変更を受け取る（受け取ったら中身は select で取り直す。写真入りで大きくなるため）
alter publication supabase_realtime add table public.tsumigi_state;
