-- 独立ロードマップ（進捗トラッカー dokuritsu.html）の端末間同期テーブル
-- yarukoto_state / grownote_state と同じ個人用フルアクセス方式。
-- id='kodai' 固定の1行に state（triggers/weeks/kpis/prospects）を丸ごと保存。
-- 2026-07-28 に Supabase MCP で適用済み（プロジェクト okbjqtdirrathscctyvx）。この .sql は記録用。

create table if not exists public.tsumiki_roadmap_state (
  id text primary key,
  state jsonb,
  updated_at timestamptz default now()
);

alter table public.tsumiki_roadmap_state enable row level security;

create policy "tsumiki_roadmap_full_access"
  on public.tsumiki_roadmap_state
  for all
  to anon
  using (true)
  with check (true);

-- リアルタイム配信（他端末へ即反映）
alter publication supabase_realtime add table public.tsumiki_roadmap_state;
