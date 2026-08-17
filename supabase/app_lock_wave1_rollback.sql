-- ============================================================
-- app_lock_wave1_rollback.sql — 緊急復旧
-- ------------------------------------------------------------
-- 「閉じたら自分も入れなくなった」ときにこれを当てると元に戻る。
-- 元に戻す＝また誰でも読める状態に戻る、ということなので、
-- 落ち着いたら原因を直して段階2をやり直すこと。
-- ============================================================

-- 1) テーブル権限を戻す
grant all on table public.recognition_state to anon, authenticated;
grant all on table public.grownote_state    to anon, authenticated;
grant all on table public.team5whys_state   to anon, authenticated;
grant all on table public.career_log        to anon, authenticated;

-- 2) 全開放ポリシーを戻す（元と同じ名前・同じ内容）
create policy "recognition_personal_full_access" on public.recognition_state
  for all to anon using (true) with check (true);

create policy "grownote_personal_full_access" on public.grownote_state
  for all to anon using (true) with check (true);

create policy "team5whys_personal_full_access" on public.team5whys_state
  for all to anon using (true) with check (true);

create policy "career_log anon all" on public.career_log
  for all to anon using (true) with check (true);

-- 3) 鍵を捨ててやり直したいとき（合言葉を忘れた場合など）
--    ⚠️ これを実行すると次に保存した端末の鍵で確定し直される
-- delete from public.app_tokens where app = 'kodai';
