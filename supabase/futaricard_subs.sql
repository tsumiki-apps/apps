-- ふたりカード — Web Push の購読情報テーブル
-- push_subs（ゆずごはん日記）と同じ形だが、アプリ専用に分けている
-- （endpoint が主キーなので、共有すると別アプリの登録で上書きされる）。

create table if not exists public.futaricard_subs (
  endpoint   text primary key,   -- 端末ごとに一意（プッシュ送信先URL）
  who        text not null check (who in ('kodai','yuzu')),   -- どちらの端末か（ふたりカードの内部の名前）
  p256dh     text not null,      -- 暗号鍵
  auth       text not null,      -- 認証シークレット
  created_at bigint
);

-- 2人だけのアプリなので、他テーブル同様 anon キーから読み書きを許可する。
alter table public.futaricard_subs enable row level security;

drop policy if exists "futaricard_subs anon all" on public.futaricard_subs;
create policy "futaricard_subs anon all" on public.futaricard_subs
  for all to anon using (true) with check (true);
