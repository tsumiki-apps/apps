-- みんなわり（minnawari.html）＝グループ割り勘アプリのグループ置き場。
-- 2026-08-02 に Supabase MCP 経由で適用済み（マイグレーション名: minnawari_groups）。
-- 1グループ＝1行。全状態（メンバー・立替・設定）を state(jsonb) に丸ごと持つ。
--
-- 設計のキモ：お金と人の名前が入るので、他アプリの rooms テーブルのような
-- 「anon フルアクセス」にはしない。RLS を有効にしつつ anon 向けポリシーを
-- 一切作らないことで REST からの直接アクセス（＝全行ダンプ）を封じ、
-- 下の SECURITY DEFINER 関数だけを唯一の入口にする。
--   ・読む   → warikan_read(id)                 … 推測困難な id を知っていれば読める＝閲覧URL
--   ・書く   → warikan_write(id, edit_key, ...) … edit_key も知っていないと書けない＝編集URL

create table if not exists public.warikan_groups (
  id          text primary key,
  edit_key    text not null,
  v           integer not null default 1,
  state       jsonb   not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.warikan_groups enable row level security;
revoke all on table public.warikan_groups from anon, authenticated;

create or replace function public.warikan_read(p_id text)
returns table(v integer, state jsonb, updated_at timestamptz)
language sql security definer set search_path = public as $$
  select g.v, g.state, g.updated_at from public.warikan_groups g where g.id = p_id;
$$;

create or replace function public.warikan_create(p_id text, p_key text, p_state jsonb)
returns integer language plpgsql security definer set search_path = public as $$
begin
  if p_id is null or length(p_id) < 8 or p_key is null or length(p_key) < 6 then return -3; end if;
  if pg_column_size(p_state) > 400000 then return -4; end if;
  insert into public.warikan_groups(id, edit_key, v, state) values (p_id, p_key, 1, p_state);
  return 1;
exception when unique_violation then return -1;
end; $$;

-- 戻り値: 新しい版番号 / -1=版が古い / -2=編集キー違い・未存在 / -4=サイズ超過
create or replace function public.warikan_write(p_id text, p_key text, p_expect integer, p_state jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare newv integer;
begin
  if pg_column_size(p_state) > 400000 then return -4; end if;
  if not exists (select 1 from public.warikan_groups g where g.id = p_id and g.edit_key = p_key) then return -2; end if;
  update public.warikan_groups g set state = p_state, v = g.v + 1, updated_at = now()
   where g.id = p_id and g.edit_key = p_key and g.v = p_expect returning g.v into newv;
  if newv is null then return -1; end if;
  return newv;
end; $$;

revoke all on function public.warikan_read(text)                        from public;
revoke all on function public.warikan_create(text, text, jsonb)         from public;
revoke all on function public.warikan_write(text, text, integer, jsonb) from public;
grant execute on function public.warikan_read(text)                        to anon;
grant execute on function public.warikan_create(text, text, jsonb)         to anon;
grant execute on function public.warikan_write(text, text, integer, jsonb) to anon;
