-- ゆずごはん: 自動いいねをやめる（自動で付けたいいねも消す。手で付けたいいねは残る）
drop trigger if exists cooking_auto_like on public.records;
drop function if exists public.cooking_auto_like();
delete from public.likes where id like 'auto%' and who = 'こうだい';
