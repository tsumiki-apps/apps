-- vault_state 書き込み保護: 緊急ロールバック
-- 問題が出てユーザーがvaultを保存できなくなった場合、元の「anon全許可」状態に即戻す。
-- （セキュリティは元の弱い状態に戻るが、データ保存の復旧を最優先する用）

-- 直接書き込み権限を復活（anon/authenticated復旧のみ。元がpublicロールにもgrantされていた場合は別途）
grant select, insert, update, delete on public.vault_state to anon;
grant select, insert, update, delete on public.vault_state to authenticated;

-- SELECT専用ポリシーがあれば外し、元の全許可ポリシーを復元
drop policy if exists "vault_anon_select" on public.vault_state;
drop policy if exists "anon all" on public.vault_state;
create policy "anon all" on public.vault_state
  for all using (true) with check (true);

-- 追加した列・RPCはそのまま残してよい（無害）。完全に消す場合は以下を実行:
-- drop function if exists public.save_vault_state(text, text, jsonb, bigint);
-- alter table public.vault_state drop column if exists write_token_hash;
-- alter table public.vault_state drop column if exists version;
