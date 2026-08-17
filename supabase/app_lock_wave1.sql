-- ============================================================
-- app_lock_wave1.sql — 段階1：鍵置き場とRPCを用意する（まだ閉めない）
-- ------------------------------------------------------------
-- 対象（P1 のうち realtime を使っていない4つ）
--   recognition_state / grownote_state / team5whys_state / career_log
--
-- この段階では既存の "anon all" ポリシーには触りません。
-- ＝当てても今までどおり動きます。ロックアウトは起きません。
--
-- 順番（vault のときと同じ・逆にすると自分が締め出される）
--   ① このファイルを当てる
--   ② クライアント（career.js ほか）を公開する
--   ③ app_tokens に token_hash が入ったことを DB で確認する
--   ④ app_lock_wave1_activate.sql を当てて初めて閉じる
-- ============================================================

-- ------------------------------------------------------------
-- 1) 鍵置き場
--    RLS 有効かつポリシーを1つも作らない＝anon からは一切見えない。
--    SECURITY DEFINER の関数だけが読み書きできる。
-- ------------------------------------------------------------
create table if not exists public.app_tokens (
  app         text primary key,           -- 鍵の単位（'kodai' / 'futari' など）
  token_hash  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.app_tokens enable row level security;
revoke all on table public.app_tokens from anon, authenticated;


-- ------------------------------------------------------------
-- 2) 鍵の照合（内部関数・anon には公開しない）
--    ・token_hash が未設定なら、その端末の鍵で確定させる（TOFU）
--    ・以降は一致しないと false
--    ・token は クライアント側で PBKDF2 15万回して作った文字列を想定。
--      攻撃者はオンラインで1回試すたびに PBKDF2 を回す必要があり、
--      総当たりが現実的でなくなる（vault と同じ考え方）
-- ------------------------------------------------------------
create or replace function public.app_token_ok(p_app text, p_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  h   text;
  cur text;
  hit boolean;
begin
  if p_app is null or p_app = '' then return false; end if;
  if p_token is null or length(p_token) < 32 then return false; end if;

  h := encode(sha256(convert_to(p_token, 'UTF8')), 'hex');

  select token_hash, true into cur, hit
    from public.app_tokens where app = p_app;

  if hit is not true then
    insert into public.app_tokens(app, token_hash) values (p_app, h);
    return true;
  end if;

  if cur is null then
    update public.app_tokens set token_hash = h, updated_at = now() where app = p_app;
    return true;
  end if;

  return cur = h;
end $$;


-- ------------------------------------------------------------
-- 3) 触ってよいテーブルの許可リスト
--    動的SQLはここを通ったものだけ。名前は format('%I') で必ずクォートする。
-- ------------------------------------------------------------
create or replace function public.app_state_table(p_key text)
returns text
language sql
immutable
as $$
  select case p_key
    when 'recognition' then 'recognition_state'
    when 'grownote'    then 'grownote_state'
    when 'team5whys'   then 'team5whys_state'
    else null
  end
$$;


-- ------------------------------------------------------------
-- 4) state 系の読み書き（3テーブル共通・形が同じなので1組で足りる）
-- ------------------------------------------------------------
create or replace function public.app_state_load(p_key text, p_id text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t text;
  r jsonb;
begin
  t := public.app_state_table(p_key);
  if t is null then raise exception 'unknown app'; end if;
  if not public.app_token_ok('kodai', p_token) then raise exception 'unauthorized'; end if;

  execute format('select state from public.%I where id = $1', t) into r using p_id;
  return r;
end $$;


create or replace function public.app_state_save(p_key text, p_id text, p_token text, p_state jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  t text;
begin
  t := public.app_state_table(p_key);
  if t is null then raise exception 'unknown app'; end if;
  if p_id is null or p_id = '' or length(p_id) > 64 then raise exception 'bad id'; end if;
  if not public.app_token_ok('kodai', p_token) then raise exception 'unauthorized'; end if;

  execute format(
    'insert into public.%I(id, state, updated_at) values ($1, $2, now())
       on conflict (id) do update set state = excluded.state, updated_at = now()', t)
    using p_id, p_state;
end $$;


-- ------------------------------------------------------------
-- 5) career_log（追記ログなので形が違う。3本用意する）
-- ------------------------------------------------------------
create or replace function public.career_log_list(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.app_token_ok('kodai', p_token) then raise exception 'unauthorized'; end if;

  return coalesce(
    (select jsonb_agg(to_jsonb(x) order by x.created_at desc)
       from (select * from public.career_log order by created_at desc limit 5000) x),
    '[]'::jsonb);
end $$;


create or replace function public.career_log_add(p_token text, p_row jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.app_token_ok('kodai', p_token) then raise exception 'unauthorized'; end if;
  if p_row->>'id' is null then raise exception 'bad row'; end if;

  insert into public.career_log(id, app, app_label, action, summary, meta, genre, created_at)
  values (
    p_row->>'id',
    left(p_row->>'app', 64),
    left(p_row->>'app_label', 128),
    left(p_row->>'action', 64),
    left(p_row->>'summary', 2000),
    p_row->'meta',
    left(p_row->>'genre', 64),
    coalesce((p_row->>'created_at')::timestamptz, now())
  )
  on conflict (id) do nothing;
end $$;


create or replace function public.career_log_remove(p_token text, p_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.app_token_ok('kodai', p_token) then raise exception 'unauthorized'; end if;
  delete from public.career_log where id = p_id;
end $$;


-- ------------------------------------------------------------
-- 6) 実行権限
--    ・関数は既定で PUBLIC に execute が付くので、まず剥がしてから anon に付け直す
--    ・照合と許可リストは内部用。anon には渡さない（鍵の総当たり口を増やさない）
-- ------------------------------------------------------------
revoke all on function public.app_token_ok(text, text)              from public, anon, authenticated;
revoke all on function public.app_state_table(text)                 from public, anon, authenticated;

revoke all on function public.app_state_load(text, text, text)        from public;
revoke all on function public.app_state_save(text, text, text, jsonb) from public;
revoke all on function public.career_log_list(text)                   from public;
revoke all on function public.career_log_add(text, jsonb)             from public;
revoke all on function public.career_log_remove(text, text)           from public;

grant execute on function public.app_state_load(text, text, text)        to anon;
grant execute on function public.app_state_save(text, text, text, jsonb) to anon;
grant execute on function public.career_log_list(text)                   to anon;
grant execute on function public.career_log_add(text, jsonb)             to anon;
grant execute on function public.career_log_remove(text, text)           to anon;
