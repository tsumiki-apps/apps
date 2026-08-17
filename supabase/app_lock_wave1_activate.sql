-- ============================================================
-- app_lock_wave1_activate.sql — 段階2：ここで初めて閉じる
-- ------------------------------------------------------------
-- ⚠️ 当てる前に必ず確認すること（順番を守らないと自分も締め出される）
--
--   select app, (token_hash is not null) as hash_set, updated_at
--     from public.app_tokens where app = 'kodai';
--   → hash_set = true になっていること
--
--   さらに、新しいクライアントで実際に読み書きできたことを確認してから当てる。
-- ============================================================

-- ------------------------------------------------------------
-- 1) anon 全開放ポリシーを撤去（RLS は有効のまま＝ポリシー無し＝拒否）
-- ------------------------------------------------------------
drop policy if exists "recognition_personal_full_access" on public.recognition_state;
drop policy if exists "grownote_personal_full_access"    on public.grownote_state;
drop policy if exists "team5whys_personal_full_access"   on public.team5whys_state;
drop policy if exists "career_log anon all"              on public.career_log;

-- ------------------------------------------------------------
-- 2) テーブル権限そのものも剥がす
--    （ポリシーだけでも止まるが、二重にしておく）
-- ------------------------------------------------------------
revoke all on table public.recognition_state from anon, authenticated;
revoke all on table public.grownote_state    from anon, authenticated;
revoke all on table public.team5whys_state   from anon, authenticated;
revoke all on table public.career_log        from anon, authenticated;

-- ------------------------------------------------------------
-- 3) realtime の配信対象からも外す
--    この4つは購読していないので影響なし。残すと anon 向けの経路が残る。
-- ------------------------------------------------------------
-- （4つとも supabase_realtime パブリケーションに未登録なので操作不要。
--   将来登録されていた場合に備えて確認用のクエリだけ置いておく）
-- select tablename from pg_publication_tables
--  where pubname = 'supabase_realtime' and schemaname = 'public'
--    and tablename in ('recognition_state','grownote_state','team5whys_state','career_log');

-- ------------------------------------------------------------
-- 4) 確認
-- ------------------------------------------------------------
-- select tablename, policyname, roles::text
--   from pg_policies where schemaname='public'
--    and tablename in ('recognition_state','grownote_state','team5whys_state','career_log');
--   → 0行になること
--
-- select has_table_privilege('anon','public.recognition_state','SELECT');
--   → false になること
