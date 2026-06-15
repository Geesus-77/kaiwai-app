-- ============================================================
-- 09_feed_views.sql  —  피드 조회 (전체 공개 뷰 + 팔로우 피드 함수)
-- ============================================================

-- ------------------------------------------------------------
-- 전체 공개 피드 뷰: 작성자 프로필을 조인하여 최신순 제공
--   security_invoker=true → 호출자 권한으로 RLS 적용 (PG15+ / Supabase)
-- ------------------------------------------------------------
create or replace view public.public_feed
with (security_invoker = true)
as
  select
    p.id,
    p.author_id,
    p.caption,
    p.image_urls,
    p.like_count,
    p.created_at,
    p.updated_at,
    pr.username      as author_username,
    pr.display_name  as author_display_name,
    pr.avatar_url    as author_avatar_url
  from public.posts p
  join public.profiles pr on pr.id = p.author_id
  order by p.created_at desc;

-- ------------------------------------------------------------
-- 팔로우 피드 함수: user_uuid 가 팔로우하는 사람들의 게시물(최신순)
--   security invoker(stable) → 호출자 RLS 적용
-- ------------------------------------------------------------
create or replace function public.following_feed(
  user_uuid uuid,
  _limit    int          default 20,
  _before   timestamptz  default now()
)
returns setof public.public_feed
language sql
stable
security invoker
set search_path = public
as $$
  select f.*
  from public.public_feed f
  where f.author_id in (
    select fl.following_id
    from public.follows fl
    where fl.follower_id = user_uuid
  )
  and f.created_at < _before
  order by f.created_at desc
  limit _limit;
$$;
