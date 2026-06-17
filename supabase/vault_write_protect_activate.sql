-- vault_state 書き込み保護: 段階2（保護有効化・破壊的）
-- 前提: 段階1適用済み + 新クライアント(save_vault_state RPC経由)を全端末で読み込み済み +
--       ユーザーが1度vaultを開いて write_token_hash が確定済みであること。
-- 効果: anon の直接 insert/update/delete を禁止。SELECT は維持（realtime継続・中身は暗号文）。
--       以後の書き込みは security definer RPC（トークン照合）経由のみ。

-- 適用前チェック（手動）: 実在ポリシー名と write_token_hash 確定を必ず確認すること
--   select policyname, cmd, roles::text from pg_policies where tablename='vault_state';
--   select id, (write_token_hash is not null) as hash_set from public.vault_state;
--   → hash_set が true でない状態でこのSQLを打つと保存できずロックアウトするので中止。

-- 旧「anon all」全許可ポリシーを廃止し、SELECT専用ポリシーに置換（再実行しても安全なよう先にdrop）
drop policy if exists "anon all" on public.vault_state;
drop policy if exists "vault_anon_select" on public.vault_state;
create policy "vault_anon_select" on public.vault_state
  for select to anon using (true);

-- テーブルへの直接書き込み権限を剥奪（SELECTは残す）。RPCはsecurity definerなので影響なし。
revoke insert, update, delete, truncate on public.vault_state from anon;
revoke insert, update, delete, truncate on public.vault_state from authenticated;
revoke insert, update, delete, truncate on public.vault_state from public;
