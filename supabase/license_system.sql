-- ============================================================
-- 配布アプリのプロダクトキー（ライセンス）検証システム v1
-- 2026-07-23 / 設計: Decisions/2026-07-23-license-key-system.md
--
-- 方針（vault_write_protect.sql のパターン踏襲）:
--   - 台帳テーブルは完全非公開: RLS有効・ポリシー0件＋直接権限を全revoke
--   - クライアントは security definer RPC 経由でのみ照合できる
--   - トークンはサーバー側で生成し sha256 のみDB保存（平文トークンは端末だけ）
--   - キー本体は平文保存（テーブル自体が非公開なので可。お客様への再案内のため）
-- ロールバック: license_system_rollback.sql
-- ============================================================

-- ---------- 台帳 ----------

create table public.licenses (
  id          uuid primary key default gen_random_uuid(),
  key         text not null unique,          -- 例: TSUMIKI-XXXX-XXXX-XXXX
  app         text not null,                 -- 対象アプリ名（'*' なら全アプリ有効）
  customer    text not null,                 -- お客様名（透かし表示に使う）
  max_devices int  not null default 3,
  active      boolean not null default true, -- false にすると失効
  note        text,
  created_at  timestamptz not null default now()
);

create table public.license_devices (
  id          uuid primary key default gen_random_uuid(),
  license_id  uuid not null references public.licenses(id) on delete cascade,
  device_id   text not null,                 -- 端末側で生成するUUID
  token_hash  bytea not null,                -- sha256(トークン)
  created_at  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  unique (license_id, device_id)
);

-- 完全非公開（RPC以外から触れない）
alter table public.licenses enable row level security;
alter table public.license_devices enable row level security;
revoke all on public.licenses from public, anon, authenticated;
revoke all on public.license_devices from public, anon, authenticated;

-- ---------- RPC: キー入力→端末登録（anonに公開） ----------

create or replace function public.license_activate(
  p_key text, p_app text, p_device_id text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key   text;
  v_lic   public.licenses%rowtype;
  v_token text;
  v_count int;
begin
  -- 入力の正規化と門前チェック（空・過長はゴミ行対策で弾く）
  v_key := upper(regexp_replace(coalesce(p_key, ''), '[\s-]', '', 'g'));
  if length(v_key) < 8 or length(v_key) > 64
     or coalesce(p_device_id, '') = '' or length(p_device_id) > 64
     or coalesce(p_app, '') = '' or length(p_app) > 64 then
    return jsonb_build_object('ok', false, 'code', 'invalid');
  end if;

  -- ハイフン抜きで照合（お客様がハイフン無しで打っても通す）
  select * into v_lic
    from public.licenses
   where replace(key, '-', '') = v_key
     and active
     and (app = p_app or app = '*')
   for update;
  if not found then
    perform pg_sleep(0.3);  -- 総当たりをわずかに遅くする
    return jsonb_build_object('ok', false, 'code', 'invalid');
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  -- 同じ端末からの再入力はトークン再発行（台数を消費しない）
  update public.license_devices
     set token_hash = extensions.digest(v_token, 'sha256'),
         last_seen  = now()
   where license_id = v_lic.id and device_id = p_device_id;
  if not found then
    select count(*) into v_count
      from public.license_devices where license_id = v_lic.id;
    if v_count >= v_lic.max_devices then
      return jsonb_build_object('ok', false, 'code', 'device_limit');
    end if;
    insert into public.license_devices (license_id, device_id, token_hash)
    values (v_lic.id, p_device_id, extensions.digest(v_token, 'sha256'));
  end if;

  return jsonb_build_object('ok', true, 'token', v_token, 'customer', v_lic.customer);
end;
$$;

revoke execute on function public.license_activate(text, text, text) from public, authenticated;
grant execute on function public.license_activate(text, text, text) to anon;

-- ---------- RPC: 起動時のトークン照合（anonに公開） ----------

create or replace function public.license_verify(
  p_token text, p_app text, p_device_id text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dev_id   uuid;
  v_customer text;
begin
  if coalesce(p_token, '') = '' or length(p_token) > 128
     or coalesce(p_device_id, '') = '' or length(p_device_id) > 64
     or coalesce(p_app, '') = '' or length(p_app) > 64 then
    return jsonb_build_object('ok', false, 'code', 'invalid');
  end if;

  select d.id, l.customer into v_dev_id, v_customer
    from public.license_devices d
    join public.licenses l on l.id = d.license_id
   where d.token_hash = extensions.digest(p_token, 'sha256')
     and d.device_id = p_device_id
     and l.active
     and (l.app = p_app or l.app = '*');
  if not found then
    return jsonb_build_object('ok', false, 'code', 'revoked');
  end if;

  update public.license_devices set last_seen = now() where id = v_dev_id;
  return jsonb_build_object('ok', true, 'customer', v_customer);
end;
$$;

revoke execute on function public.license_verify(text, text, text) from public, authenticated;
grant execute on function public.license_verify(text, text, text) to anon;

-- ---------- キー発行（anonに出さない・SQLエディタ/MCP専用） ----------

create or replace function public.license_issue(
  -- 台数の既定は 20。「端末に紐づけない」運用（Decisions/2026-08-17-license-operation-and-support-scope）
  -- を実装改修なしで満たすため。license_devices は上限ではなく「使われ方の記録」として使う。
  p_customer text, p_app text, p_max_devices int default 20, p_note text default null
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- 紛らわしい文字（I/O/0/1）を除いた32文字 → 12桁で約2^60通り
  chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  bytes bytea;
  v_key text;
  i int;
begin
  if coalesce(p_customer, '') = '' or coalesce(p_app, '') = '' then
    raise exception 'customer と app は必須';
  end if;
  bytes := extensions.gen_random_bytes(12);
  v_key := 'TSUMIKI';
  for i in 0..11 loop
    if i % 4 = 0 then v_key := v_key || '-'; end if;
    v_key := v_key || substr(chars, 1 + (get_byte(bytes, i) % 32), 1);
  end loop;
  insert into public.licenses (key, app, customer, max_devices, note)
  values (v_key, p_app, p_customer, p_max_devices, p_note);
  return v_key;
end;
$$;

revoke execute on function public.license_issue(text, text, int, text)
  from public, anon, authenticated;
