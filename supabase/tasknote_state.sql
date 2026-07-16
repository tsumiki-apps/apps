-- たすくノート（Notion風タスク管理アプリ）の端末間同期テーブル
-- やることばこ／たびのき等と同じプロジェクト（okbjqtdirrathscctyvx）。
-- 個人利用なので 'kodai' 固定の1行に丸ごと保存する。
-- 実行するまではアプリは「この端末のみ保存」で動き、実行後に iPhone/iPad/Mac で自動同期される。

create table if not exists public.tasknote_state (
  id text primary key,                 -- 'kodai' 固定の1行
  state jsonb,                          -- たすくノートのDB（{tasks,columns,tags,ui}）をそのまま
  updated_at timestamptz default now()
);

alter table public.tasknote_state enable row level security;

-- 個人の複数端末用フルアクセスポリシー（anon キーで読み書き可）
drop policy if exists "tasknote_full_access" on public.tasknote_state;
create policy "tasknote_full_access"
  on public.tasknote_state
  for all
  to anon
  using (true)
  with check (true);

-- リアルタイム配信を有効化（変更が他の端末の画面に即反映される）
alter publication supabase_realtime add table public.tasknote_state;
