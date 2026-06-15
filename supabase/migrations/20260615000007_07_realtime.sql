-- ============================================================
-- 07_realtime.sql  —  기기 간 실시간 동기화 (Realtime publication)
-- ============================================================
-- supabase_realtime publication 은 Supabase 프로젝트에 기본 존재.
-- 중복 add 에러 방지를 위해 미등록일 때만 추가.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'posts'
  ) then
    alter publication supabase_realtime add table public.posts;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'post_likes'
  ) then
    alter publication supabase_realtime add table public.post_likes;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'follows'
  ) then
    alter publication supabase_realtime add table public.follows;
  end if;
end$$;

-- DELETE/UPDATE 이벤트에서 이전 row 데이터를 받으려면 REPLICA IDENTITY FULL 필요
alter table public.posts      replica identity full;
alter table public.post_likes replica identity full;
alter table public.follows    replica identity full;
