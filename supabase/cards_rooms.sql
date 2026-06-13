-- トランプ3D（trump.html）オンライン対戦用の部屋テーブル
-- じんせいすごろくと同じプロジェクト（okbjqtdirrathscctyvx）で、
-- Supabase ダッシュボード → SQL Editor に貼り付けて一度だけ実行する。
-- 部屋コード1つにつき1行。選択中のゲーム・手札・場・手番などの全状態を state(jsonb) に丸ごと保存する。

create table if not exists public.cards_rooms (
  code text primary key,               -- 4桁の部屋コード
  state jsonb,                          -- ゲーム全状態（バージョン v / 選択ゲーム / 手札 / 場 / 手番など）
  updated_at timestamptz default now()
);

alter table public.cards_rooms enable row level security;

-- ふたり共有用のフルアクセスポリシー（anon キーで読み書き可）
create policy "cards_rooms_full_access"
  on public.cards_rooms
  for all
  to anon
  using (true)
  with check (true);

-- リアルタイム配信を有効化（相手の操作が即こちらの画面に反映される）
alter publication supabase_realtime add table public.cards_rooms;
