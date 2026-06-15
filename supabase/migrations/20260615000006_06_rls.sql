-- ============================================================
-- 06_rls.sql  —  Row Level Security 정책
-- ============================================================

-- profiles ----------------------------------------------------
alter table public.profiles enable row level security;

create policy "프로필 공개 조회" on public.profiles
  for select using (true);

create policy "본인 프로필만 수정" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);


-- posts -------------------------------------------------------
alter table public.posts enable row level security;

create policy "피드 공개 조회" on public.posts
  for select using (true);

create policy "본인만 작성" on public.posts
  for insert with check (auth.uid() = author_id);

create policy "본인 글만 수정" on public.posts
  for update using (auth.uid() = author_id) with check (auth.uid() = author_id);

create policy "본인 글만 삭제" on public.posts
  for delete using (auth.uid() = author_id);


-- post_likes (좋아요=공개 반응) -------------------------------
alter table public.post_likes enable row level security;

create policy "좋아요 공개 조회" on public.post_likes
  for select using (true);

create policy "본인 계정으로만 좋아요" on public.post_likes
  for insert with check (auth.uid() = user_id);

create policy "본인 좋아요만 취소" on public.post_likes
  for delete using (auth.uid() = user_id);


-- follows -----------------------------------------------------
alter table public.follows enable row level security;

create policy "팔로우 공개 조회" on public.follows
  for select using (true);

create policy "본인만 팔로우" on public.follows
  for insert with check (auth.uid() = follower_id);

create policy "본인만 언팔로우" on public.follows
  for delete using (auth.uid() = follower_id);
