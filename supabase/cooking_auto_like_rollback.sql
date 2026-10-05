-- ゆずごはん: 自動いいねをやめる（自動で付けたいいねも消す。手で付けたいいねは残る）
select cron.unschedule('cooking-auto-like') where exists (select 1 from cron.job where jobname = 'cooking-auto-like');
drop trigger if exists cooking_auto_like on public.records;
delete from public.likes where id in (select like_id from private.cooking_like_queue where result = 'liked');
drop table if exists private.cooking_like_queue;
drop function if exists private.cooking_like_run();
drop function if exists private.cooking_like_enqueue();
drop function if exists private.cooking_like_due(timestamptz);
drop function if exists private.cooking_like_id(bigint);
