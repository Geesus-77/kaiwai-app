-- ============================================================
-- 05_updated_at.sql  —  updated_at 자동 갱신 공용 트리거
-- ============================================================
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_profiles_touch
  before update on public.profiles
  for each row execute function public.touch_updated_at();

create trigger trg_posts_touch
  before update on public.posts
  for each row execute function public.touch_updated_at();
