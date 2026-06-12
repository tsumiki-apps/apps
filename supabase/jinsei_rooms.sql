-- じんせいすごろく（jinsei.html）オンライン対戦用の部屋テーブル
-- ゆずごはん日記などと同じプロジェクト（okbjqtdirrathscctyvx）で、
-- Supabase ダッシュボード → SQL Editor に貼り付けて一度だけ実行する。
-- 部屋コード1つにつき1行。ゲームの全状態を state(jsonb) に丸ごと保存する。

create table if not exists public.jinsei_rooms (
  code text primary key,               -- 4桁の部屋コード
  state jsonb,                         -- ゲーム全状態（プレイヤー・位置・所持金・手番など）
  updated_at timestamptz default now()
);

alter table public.jinsei_rooms enable row level security;

-- ふたり共有用のフルアクセスポリシー（anon キーで読み書き可）
create policy "jinsei_rooms_full_access"
  on public.jinsei_rooms
  for all
  to anon
  using (true)
  with check (true);

-- リアルタイム配信を有効化（相手の操作が即こちらの画面で再生される）
alter publication supabase_realtime add table public.jinsei_rooms;
