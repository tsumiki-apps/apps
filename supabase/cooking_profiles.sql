-- ゆずごはん日記（cooking.html）
-- コメントの返信・メンション と、プロフィール（アイコン・表示する名前）
-- 2026-09-06 に本番へ適用ずみ（migration: yuzu_cooking_replies_mentions_profiles）
-- 追加のみ・冪等。何度流しても同じ状態になる。

-- 返信＝親コメントのid、メンション＝呼んだ人の who を並べた配列
alter table public.comments add column if not exists parent_id text;
alter table public.comments add column if not exists mentions jsonb default '[]'::jsonb;

-- who（＝その人を指す鍵。こうだい / ゆずは / 家族が入力した名前）は変えない。
-- 画面に出る名前とアイコンだけをここに置く＝過去のいいね・コメントが迷子にならない。
create table if not exists public.profiles (
  who        text primary key,
  name       text,          -- 表示する名前
  avatar     text,          -- アイコン画像のURL（photosバケット）
  emoji      text,          -- 画像のかわりの絵文字
  updated_at bigint
);
alter table public.profiles enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                 where schemaname='public' and tablename='profiles' and policyname='anon all profiles') then
    create policy "anon all profiles" on public.profiles for all to anon using (true) with check (true);
  end if;
end $$;

-- リアルタイム（相手が名前を変えたら、こちらの画面もすぐ変わる）
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname='supabase_realtime' and schemaname='public' and tablename='profiles') then
    alter publication supabase_realtime add table public.profiles;
  end if;
end $$;
