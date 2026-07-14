-- いっしょ（issho.html）ふたり共有リストの同期用テーブル
-- たびのき／おつかいカート等と同じプロジェクト（okbjqtdirrathscctyvx）。
-- Supabase ダッシュボード → SQL Editor に貼り付けて一度だけ実行する。
-- id='shared' の1行に全状態（{v, updatedAt, cats:[], lists:[]}）を丸ごと保存し、
-- こうだい／ゆずは の両端末がこの1行を読み書きして共有・リアルタイム同期する。

create table if not exists public.issho_state (
  id text primary key,                 -- ふたり共有なので 'shared' 固定の1行
  state jsonb,                         -- いっしょのDB（{v,updatedAt,cats,lists}）をそのまま
  updated_at timestamptz default now()
);

alter table public.issho_state enable row level security;

-- ふたり共有用のフルアクセスポリシー（anon キーで読み書き可）
create policy "issho_full_access"
  on public.issho_state
  for all
  to anon
  using (true)
  with check (true);

-- リアルタイム配信を有効化（相手の追加・チェックが即こちらの画面に反映される）
alter publication supabase_realtime add table public.issho_state;
