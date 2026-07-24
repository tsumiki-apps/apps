-- license_system.sql のロールバック（全部を綺麗に撤去する）
-- ⚠️ 発行済みキー・登録端末も消える。実運用開始後は実行前に必ずバックアップ:
--   select * from public.licenses; select * from public.license_devices;

-- 管理RPC（license_admin.sql）も撤去
drop function if exists public.admin_reset_devices(text, text);
drop function if exists public.admin_set_max(text, text, int);
drop function if exists public.admin_set_active(text, text, boolean);
drop function if exists public.admin_issue(text, text, text, int, text);
drop function if exists public.admin_list(text);
drop function if exists public.admin_verify(text);
drop table if exists public.admin_config;

drop function if exists public.license_issue(text, text, int, text);
drop function if exists public.license_verify(text, text, text);
drop function if exists public.license_activate(text, text, text);
drop table if exists public.license_devices;
drop table if exists public.licenses;
