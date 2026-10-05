-- ゆずごはん: ゆずはの投稿に「こうだいのいいね」を、投稿の1〜4時間後にこっそり付ける
-- ・見分けが付かないこと：likes に入る行は手のいいねと同じ形（id = 'l'+ミリ秒+英数4字、created_at = 付けた時刻）。
--   付けたら、手のいいねと同じく相手に通知（notify-reaction）も送る。
-- ・どれを自動で付けたかの控えは private スキーマ（アプリの鍵からは読めない）にだけ残す。
-- ・夜中（1時〜7時台）に当たったら、朝8時〜9時半にずらす。
-- ・付ける時点で、こうだいが手でいいね済み／記録が消えた／投稿者がゆずはでなくなった物は付けない。
-- 前提：pg_cron・pg_net。通知に使う鍵は vault の 'cooking_anon_key'（このファイルには書かない）。

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.cooking_like_queue (
  record_id  text primary key,
  due_at     timestamptz not null,
  done_at    timestamptz,
  like_id    text,               -- 付けたいいねの id（戻すときに使う）
  result     text                -- liked / skipped
);

-- 手のいいねと同じ形の id（cooking.html の toggleLike と同じ）
create or replace function private.cooking_like_id(ms bigint) returns text
language sql volatile as $$
  select 'l' || ms || string_agg(substr('0123456789abcdefghijklmnopqrstuvwxyz', 1 + floor(random()*36)::int, 1), '')
  from generate_series(1, 4)
$$;

-- 基準の時刻から1〜4時間後。夜中（日本時間 1:00〜7:59）なら同じ日の8:00〜9:30へ
create or replace function private.cooking_like_due(base timestamptz) returns timestamptz
language plpgsql volatile as $$
declare t timestamptz := base + make_interval(mins => 60 + floor(random()*180)::int);
        h int := extract(hour from t at time zone 'Asia/Tokyo');
begin
  if h between 1 and 7 then
    t := (date_trunc('day', t at time zone 'Asia/Tokyo') + interval '8 hours'
          + make_interval(mins => floor(random()*90)::int)) at time zone 'Asia/Tokyo';
  end if;
  return t;
end $$;

-- 記録が増えたら（または投稿者がゆずはに変わったら）予約する
drop trigger if exists cooking_auto_like on public.records;
drop function if exists public.cooking_auto_like();
create or replace function private.cooking_like_enqueue()
returns trigger language plpgsql security definer set search_path = public, private as $$
begin
  if new.who = 'ゆずは'
     and (tg_op = 'INSERT' or old.who is distinct from new.who)
     and not exists (select 1 from likes where record_id = new.id and who = 'こうだい') then
    insert into private.cooking_like_queue (record_id, due_at)
    values (new.id, private.cooking_like_due(now()))
    on conflict (record_id) do nothing;
  end if;
  return null;
end $$;
create trigger cooking_auto_like
  after insert or update of who on public.records
  for each row execute function private.cooking_like_enqueue();

-- 5分ごと：時刻が来た予約に、いいねを付けて通知を送る
create or replace function private.cooking_like_run() returns int
language plpgsql security definer set search_path = public, private as $$
declare q record; ms bigint; lid text; rname text; aname text; key text; n int := 0;
begin
  select decrypted_secret into key from vault.decrypted_secrets where name = 'cooking_anon_key';
  select coalesce(nullif(name, ''), 'こうだい') into aname from profiles where who = 'こうだい';
  aname := coalesce(aname, 'こうだい');
  for q in select * from private.cooking_like_queue where done_at is null and due_at <= now()
           order by due_at for update skip locked loop
    select name into rname from records where id = q.record_id and who = 'ゆずは';
    if not found or exists (select 1 from likes where record_id = q.record_id and who = 'こうだい') then
      update private.cooking_like_queue set done_at = now(), result = 'skipped' where record_id = q.record_id;
      continue;
    end if;
    ms  := (extract(epoch from clock_timestamp()) * 1000)::bigint;
    lid := private.cooking_like_id(ms);
    insert into likes (id, record_id, who, created_at) values (lid, q.record_id, 'こうだい', ms);
    update private.cooking_like_queue set done_at = now(), result = 'liked', like_id = lid where record_id = q.record_id;
    if key is not null then
      perform net.http_post(
        url := 'https://okbjqtdirrathscctyvx.supabase.co/functions/v1/notify-reaction',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || key),
        body := jsonb_build_object('kind', 'like', 'actor', 'こうだい', 'recordId', q.record_id,
                                   'recordName', coalesce(rname, ''), 'body', '', 'emoji', '',
                                   'to', '[]'::jsonb, 'actorName', aname));
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on all functions in schema private from public, anon, authenticated;

select cron.unschedule('cooking-auto-like') where exists (select 1 from cron.job where jobname = 'cooking-auto-like');
select cron.schedule('cooking-auto-like', '*/5 * * * *', 'select private.cooking_like_run()');

-- 2026-10-05：最初の版（すぐ付ける・id が auto 始まり）で一括で付けた32件は、一度だけ
-- id を手の形に、時刻を投稿の1〜4時間後に直し、控えを cooking_like_queue に入れた（Supabase の migration 履歴に残る）。
