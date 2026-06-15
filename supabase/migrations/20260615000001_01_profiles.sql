-- ============================================================
-- 01_profiles.sql  —  공개 프로필 (auth.users 1:1)
--   + 회원가입 시 소셜 user_metadata → profiles 자동 매핑
-- ============================================================
create table public.profiles (
  id           uuid        primary key references auth.users(id) on delete cascade,
  username     text        unique not null,
  display_name text,
  avatar_url   text,
  bio          text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint username_format check (username ~ '^[a-zA-Z0-9_]{3,20}$')
);

comment on table public.profiles is 'auth.users와 1:1 매핑되는 공개 프로필';

-- ------------------------------------------------------------
-- 신규 유저 생성 시 프로필 자동 생성
--   Google/Kakao/Email/Naver(Edge Function) 모두 공통 동작.
--   raw_user_meta_data 키는 공급자마다 다르므로 폴백 체인으로 처리.
--     - user_name / preferred_username / nickname → username
--     - full_name / name / nickname             → display_name
--     - avatar_url / picture / profile_image     → avatar_url
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  meta        jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  _username   text;
begin
  -- username 후보: 메타데이터 → 없으면 id 앞 8자리 기반 기본값
  _username := coalesce(
    nullif(meta->>'user_name', ''),
    nullif(meta->>'preferred_username', ''),
    nullif(meta->>'nickname', ''),
    'user_' || substr(replace(new.id::text, '-', ''), 1, 8)
  );

  -- username_format(영문/숫자/_ 3~20자) 위반 또는 중복 시 안전한 기본값으로 대체
  if _username !~ '^[a-zA-Z0-9_]{3,20}$'
     or exists (select 1 from public.profiles where username = _username) then
    _username := 'user_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;

  insert into public.profiles (id, username, display_name, avatar_url)
  values (
    new.id,
    _username,
    coalesce(meta->>'full_name', meta->>'name', meta->>'nickname'),
    coalesce(meta->>'avatar_url', meta->>'picture', meta->>'profile_image')
  );

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
