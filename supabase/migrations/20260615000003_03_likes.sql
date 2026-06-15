-- ============================================================
-- 03_likes.sql  —  좋아요 = 즐겨찾기 (통합)
--   공개 반응이자, 동시에 "내가 저장한 OOTD" 목록 역할.
--   복합 PK (post_id, user_id) 로 중복 좋아요 방지.
-- ============================================================
create table public.post_likes (
  post_id    uuid        not null references public.posts(id) on delete cascade,
  user_id    uuid        not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- "내 저장 목록"을 created_at 역순으로 빠르게 조회
create index post_likes_user_idx on public.post_likes (user_id, created_at desc);

-- ------------------------------------------------------------
-- posts.like_count 자동 유지
-- ------------------------------------------------------------
create or replace function public.sync_like_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'INSERT') then
    update public.posts set like_count = like_count + 1 where id = new.post_id;
  elsif (tg_op = 'DELETE') then
    update public.posts set like_count = like_count - 1 where id = old.post_id;
  end if;
  return null;
end;
$$;

create trigger trg_sync_like_count
  after insert or delete on public.post_likes
  for each row execute function public.sync_like_count();
