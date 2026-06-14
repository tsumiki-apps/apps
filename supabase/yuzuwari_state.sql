-- ゆずわり（ふたりの立て替え精算）の端末間・ふたり同期用テーブル
-- おつかいカート／クレジット明細マネージャー等と同じプロジェクト（okbjqtdirrathscctyvx）。
-- Supabase ダッシュボード → SQL Editor に貼り付けて一度だけ実行する。
-- 実行するまではアプリは「この端末のみ保存」で動き、実行後にこうだい・ゆずはの端末で自動同期される。

create table if not exists public.yuzuwari_state (
  id text primary key,                 -- ふたり共有の1行に丸ごと保存（'kodai' 固定）
  state jsonb,                         -- ゆずわりの DB（{names,projects}）をそのまま
  updated_at timestamptz default now()
);

alter table public.yuzuwari_state enable row level security;

-- フルアクセスポリシー（anon キーで読み書き可）
create policy "yuzuwari_full_access"
  on public.yuzuwari_state
  for all
  to anon
  using (true)
  with check (true);

-- リアルタイム配信を有効化（変更が相手の端末の画面に即反映される）
alter publication supabase_realtime add table public.yuzuwari_state;
