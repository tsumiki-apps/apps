-- vault_state 書き込み保護: 段階1（非破壊・追加のみ）
-- 目的: 暗号化ブロブ(vault)はSELECT開放のままrealtime維持。書き込みだけ
--       マスターパスワード由来の write_token を必須にし、第三者の悪意ある上書き/削除を防ぐ。
-- この段階では権限をrevokeしない（旧クライアントもそのまま動く）。

alter table public.vault_state add column if not exists write_token_hash bytea;
alter table public.vault_state add column if not exists version bigint not null default 0;

-- 保存用RPC（security definer）。トークン平文はDBに保存せず、sha256ハッシュのみ照合。
-- 【重要】write_token_hash は SELECT/realtime で第三者に見える。p_token は必ずクライアント側で
--   暗号鍵と同等の遅いKDF(PBKDF2 15万回・別ソルト)で導出した高エントロピー値にすること。
--   sha256(pw) のような速いハッシュだと、これがMPWの高速検証器になり暗号強度を激減させる。
create or replace function public.save_vault_state(
  p_id text,
  p_token text,
  p_state jsonb,
  p_expected_version bigint default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.vault_state%rowtype;
  v_token_hash bytea;
  v_new_version bigint;
begin
  -- vaultは単一行運用。任意idでのゴミ行量産を防ぐため固定idのみ許可（nullも弾く）
  if p_id is distinct from 'kodai' then
    raise exception 'invalid id';
  end if;
  if p_token is null or length(p_token) < 16 then
    raise exception 'invalid token';
  end if;
  v_token_hash := extensions.digest(p_token, 'sha256');

  select * into v_existing from public.vault_state where id = p_id for update;

  if not found then
    -- 新規行: 初回書き込みのトークンでhashを確定（TOFU）
    insert into public.vault_state(id, state, updated_at, write_token_hash, version)
      values (p_id, p_state, now(), v_token_hash, 1);
    return 1;
  end if;

  -- 既存行: hash未設定なら初回のtokenで確定（TOFU）、設定済みなら一致必須
  if v_existing.write_token_hash is not null
     and v_existing.write_token_hash <> v_token_hash then
    raise exception 'token mismatch';
  end if;

  -- 楽観ロック（任意）: 期待versionが指定され、現versionと食い違えば競合
  if p_expected_version is not null and v_existing.version <> p_expected_version then
    raise exception 'version conflict';
  end if;

  v_new_version := v_existing.version + 1;
  update public.vault_state
    set state = p_state,
        updated_at = now(),
        version = v_new_version,
        write_token_hash = coalesce(write_token_hash, v_token_hash)
    where id = p_id;
  return v_new_version;
end;
$$;

-- 実行権限は anon だけに絞る（public既定の付与は外す）
revoke execute on function public.save_vault_state(text, text, jsonb, bigint) from public;
grant execute on function public.save_vault_state(text, text, jsonb, bigint) to anon;
