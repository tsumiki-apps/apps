-- license_system.sql のロールバック（全部を綺麗に撤去する）
-- ⚠️ 発行済みキー・登録端末も消える。実運用開始後は実行前に必ずバックアップ:
--   select * from public.licenses; select * from public.license_devices;

drop function if exists public.license_issue(text, text, int, text);
drop function if exists public.license_verify(text, text, text);
drop function if exists public.license_activate(text, text, text);
drop table if exists public.license_devices;
drop table if exists public.licenses;
