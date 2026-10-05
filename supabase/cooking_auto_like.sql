-- ゆずごはん: ゆずはの投稿に「こうだいのいいね」を自動で付ける
-- records.who は投稿者（'ゆずは' = ゆずはが投稿）。
-- 自動のいいねは id を 'auto' で始める（手で付けたいいねと見分けて、戻すときに使う）。
-- こうだいが手で外したいいねは付け直さない（投稿者が 'ゆずは' に変わったときだけ付ける）。

create or replace function public.cooking_auto_like()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.who = 'ゆずは'
     and (tg_op = 'INSERT' or old.who is distinct from new.who)
     and not exists (select 1 from likes where record_id = new.id and who = 'こうだい') then
    insert into likes (id, record_id, who, created_at)
    values ('auto' || (extract(epoch from clock_timestamp()) * 1000)::bigint || substr(md5(random()::text), 1, 4),
            new.id, 'こうだい', (extract(epoch from clock_timestamp()) * 1000)::bigint);
  end if;
  return null;
end $$;

drop trigger if exists cooking_auto_like on public.records;
create trigger cooking_auto_like
  after insert or update of who on public.records
  for each row execute function public.cooking_auto_like();

-- 過去の分（ゆずはの投稿で、こうだいのいいねがまだ無い物）
insert into public.likes (id, record_id, who, created_at)
select 'auto' || (extract(epoch from now()) * 1000)::bigint || substr(md5(r.id), 1, 6),
       r.id, 'こうだい', (extract(epoch from now()) * 1000)::bigint
from public.records r
where r.who = 'ゆずは'
  and not exists (select 1 from public.likes l where l.record_id = r.id and l.who = 'こうだい');
