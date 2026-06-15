-- ============================================================
-- 04_follows.sql  —  팔로우 관계 (팔로우 피드 탭용)
-- ============================================================
create table public.follows (
  follower_id  uuid        not null references public.profiles(id) on delete cascade,
  following_id uuid        not null references public.profiles(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (follower_id, following_id),
  constraint no_self_follow check (follower_id <> following_id)  -- 자기 자신 팔로우 금지
);

create index follows_following_idx on public.follows (following_id); -- 팔로워 수 집계용
create index follows_follower_idx  on public.follows (follower_id);  -- 팔로우 피드 조회용
