-- ============================================================
-- ライセンス管理（マスター権限）RPC v1  ─ license_system.sql の上に乗る
-- 2026-07-24 / 設計: Decisions/2026-07-23-license-key-system.md
--
-- 管理ツール（非公開URLの単一HTML）から金庫（licenses/license_devices）を
-- 操作するための、管理パスワード照合つきRPC群。
--   - パスワードの正解は sha256 で admin_config に保存（平文はDBに送らない）
--   - 照合が通った時だけ操作に応じる。誤りは pg_sleep で遅延
--   - ⚠️ 下の secret_hash は本番の実ハッシュを載せない（このファイルはリポに入るため）。
--     実ハッシュは apply 済み。再セットするときは:
--       update public.admin_config set secret_hash = decode('<sha256hex>','hex') where id='master';
--     <sha256hex> は  printf '%s' '<パスワード>' | openssl dgst -sha256  で得る。
-- ============================================================

create table public.admin_config (
  id          text primary key default 'master',
  secret_hash bytea not null
);
alter table public.admin_config enable row level security;
revoke all on public.admin_config from public, anon, authenticated;

-- 初期パスワードのハッシュを投入（下はダミー。本番値は上記 update で設定）
insert into public.admin_config (id, secret_hash)
values ('master', decode('00000000000000000000000000000000000000000000000000000000000000ff','hex'));

create or replace function public.admin_verify(p_secret text) returns boolean
language plpgsql security definer set search_path='' as $$
declare v boolean;
begin
  if coalesce(p_secret,'') = '' or length(p_secret) > 200 then return false; end if;
  select (secret_hash = extensions.digest(p_secret,'sha256')) into v
    from public.admin_config where id = 'master';
  return coalesce(v, false);
end; $$;
revoke execute on function public.admin_verify(text) from public, anon, authenticated;

create or replace function public.admin_list(p_secret text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare res jsonb;
begin
  if not public.admin_verify(p_secret) then perform pg_sleep(0.5); raise exception 'unauthorized'; end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb) into res
  from (
    select l.key, l.customer, l.app, l.active, l.max_devices, l.note, l.created_at,
      (select count(*) from public.license_devices d where d.license_id = l.id) as device_count,
      (select max(d.last_seen) from public.license_devices d where d.license_id = l.id) as last_seen
    from public.licenses l
  ) t;
  return res;
end; $$;
revoke execute on function public.admin_list(text) from public, authenticated;
grant execute on function public.admin_list(text) to anon;

create or replace function public.admin_issue(
  p_secret text, p_customer text, p_app text, p_max_devices int default 3, p_note text default null
) returns text
language plpgsql security definer set search_path='' as $$
begin
  if not public.admin_verify(p_secret) then perform pg_sleep(0.5); raise exception 'unauthorized'; end if;
  return public.license_issue(p_customer, p_app, p_max_devices, p_note);
end; $$;
revoke execute on function public.admin_issue(text, text, text, int, text) from public, authenticated;
grant execute on function public.admin_issue(text, text, text, int, text) to anon;

create or replace function public.admin_set_active(p_secret text, p_key text, p_active boolean) returns boolean
language plpgsql security definer set search_path='' as $$
declare n int;
begin
  if not public.admin_verify(p_secret) then perform pg_sleep(0.5); raise exception 'unauthorized'; end if;
  update public.licenses set active = p_active where key = p_key;
  get diagnostics n = row_count; return n > 0;
end; $$;
revoke execute on function public.admin_set_active(text, text, boolean) from public, authenticated;
grant execute on function public.admin_set_active(text, text, boolean) to anon;

create or replace function public.admin_set_max(p_secret text, p_key text, p_max int) returns boolean
language plpgsql security definer set search_path='' as $$
declare n int;
begin
  if not public.admin_verify(p_secret) then perform pg_sleep(0.5); raise exception 'unauthorized'; end if;
  if p_max < 1 or p_max > 100 then raise exception 'max out of range'; end if;
  update public.licenses set max_devices = p_max where key = p_key;
  get diagnostics n = row_count; return n > 0;
end; $$;
revoke execute on function public.admin_set_max(text, text, int) from public, authenticated;
grant execute on function public.admin_set_max(text, text, int) to anon;

create or replace function public.admin_reset_devices(p_secret text, p_key text) returns int
language plpgsql security definer set search_path='' as $$
declare n int;
begin
  if not public.admin_verify(p_secret) then perform pg_sleep(0.5); raise exception 'unauthorized'; end if;
  delete from public.license_devices d using public.licenses l
   where d.license_id = l.id and l.key = p_key;
  get diagnostics n = row_count; return n;
end; $$;
revoke execute on function public.admin_reset_devices(text, text) from public, authenticated;
grant execute on function public.admin_reset_devices(text, text) to anon;

-- お渡し先名（透かし）・メモの編集
create or replace function public.admin_set_info(
  p_secret text, p_key text, p_customer text, p_note text
) returns boolean
language plpgsql security definer set search_path='' as $$
declare n int;
begin
  if not public.admin_verify(p_secret) then perform pg_sleep(0.5); raise exception 'unauthorized'; end if;
  if coalesce(trim(p_customer),'') = '' then raise exception 'customer required'; end if;
  update public.licenses
     set customer = trim(p_customer),
         note     = nullif(trim(coalesce(p_note,'')), '')
   where key = p_key;
  get diagnostics n = row_count; return n > 0;
end; $$;
revoke execute on function public.admin_set_info(text, text, text, text) from public, authenticated;
grant execute on function public.admin_set_info(text, text, text, text) to anon;

-- ---------- アプリ名簿（発行画面のドロップダウン。ゲート名と発行名の一致をUIで担保） ----------

create table public.apps (
  name       text primary key,
  label      text not null,
  created_at timestamptz not null default now()
);
alter table public.apps enable row level security;
revoke all on public.apps from public, anon, authenticated;
insert into public.apps(name, label) values ('kouban','香盤メーカー') on conflict do nothing;

create or replace function public.admin_apps(p_secret text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare res jsonb;
begin
  if not public.admin_verify(p_secret) then perform pg_sleep(0.5); raise exception 'unauthorized'; end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.label), '[]'::jsonb) into res
  from (
    select a.name, a.label from public.apps a
    union
    select d.app as name, coalesce(a2.label, d.app) as label
      from (select distinct app from public.licenses where app <> '*') d
      left join public.apps a2 on a2.name = d.app
  ) t;
  return res;
end; $$;
revoke execute on function public.admin_apps(text) from public, authenticated;
grant execute on function public.admin_apps(text) to anon;

create or replace function public.admin_app_add(p_secret text, p_name text, p_label text) returns boolean
language plpgsql security definer set search_path='' as $$
declare nm text;
begin
  if not public.admin_verify(p_secret) then perform pg_sleep(0.5); raise exception 'unauthorized'; end if;
  nm := lower(trim(p_name));
  if nm = '' or nm !~ '^[a-z0-9._-]{1,64}$' then raise exception 'invalid app name'; end if;
  insert into public.apps(name, label) values (nm, coalesce(nullif(trim(p_label),''), nm))
    on conflict (name) do update set label = excluded.label;
  return true;
end; $$;
revoke execute on function public.admin_app_add(text, text, text) from public, authenticated;
grant execute on function public.admin_app_add(text, text, text) to anon;
