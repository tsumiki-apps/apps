-- ============================================================
-- health_daily.sql — からだ帳（health.html）の日ごとの値。2026-09-23 に当てた（migration: health_daily_locked）
-- ・anon / authenticated からテーブルは一切見えない（RLS 有効・ポリシー0・権限も剥がす）
-- ・読むのは合言葉つきRPC health_list だけ（鍵は Work アプリ共通の 'kodai'＝app_lock_wave1.sql の app_token_ok）
-- ・書き込みは画面からはしない。取り込みは health_import.py の出力を管理者権限で入れる
-- ============================================================
create table if not exists public.health_daily (
  day        date        not null,
  metric     text        not null,   -- sleep / hrv / rhr / exercise / vo2 / weight / walk
  value      numeric     not null,
  source     text        not null default 'export',
  updated_at timestamptz not null default now(),
  primary key (day, metric)
);
alter table public.health_daily enable row level security;
revoke all on table public.health_daily from anon, authenticated;

create or replace function public.health_list(p_token text, p_from date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.app_token_ok('kodai', p_token) then raise exception 'unauthorized'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('d', day, 'm', metric, 'v', value) order by day)
      from public.health_daily
     where day >= coalesce(p_from, current_date - 400)
  ), '[]'::jsonb);
end $$;

revoke all on function public.health_list(text, date) from public;
grant execute on function public.health_list(text, date) to anon;

-- ------------------------------------------------------------
-- health_probe（2026-09-23・migration: health_probe_locked）
-- ショートカットの「送信テスト版」が届けた形だけ（数字は伏せ字）。受け口 health-ingest（service role）だけが書く。
-- ------------------------------------------------------------
create table if not exists public.health_probe (
  id     bigserial primary key,
  at     timestamptz not null default now(),
  metric text not null,
  info   jsonb not null
);
alter table public.health_probe enable row level security;
revoke all on table public.health_probe from anon, authenticated;
revoke all on sequence public.health_probe_id_seq from anon, authenticated;
