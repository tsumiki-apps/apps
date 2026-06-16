-- ちりつも（使ったお金をサッと記録）の端末間同期用テーブル
-- ゆずわり／おつかいカート等と同じプロジェクト（okbjqtdirrathscctyvx）。
-- Supabase ダッシュボード → SQL Editor に貼り付けて一度だけ実行する。
-- 実行するまではアプリは「この端末のみ保存」で動き、実行後に複数端末で自動同期される。

create table if not exists public.chiritsumo_state (
  id text primary key,                 -- 個人用の1行に丸ごと保存（'kodai' 固定）
  state jsonb,                         -- ちりつもの DB（{entries,updatedAt}）をそのまま
  updated_at timestamptz default now()
);

alter table public.chiritsumo_state enable row level security;

-- フルアクセスポリシー（anon キーで読み書き可）
create policy "chiritsumo_full_access"
  on public.chiritsumo_state
  for all
  to anon
  using (true)
  with check (true);

-- リアルタイム配信を有効化（変更が他の端末の画面に即反映される）
alter publication supabase_realtime add table public.chiritsumo_state;
