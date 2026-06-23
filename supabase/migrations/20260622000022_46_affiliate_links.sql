-- ============================================================
-- 46_affiliate_links.sql  —  [Step 9] 제휴사 커미션 링크 변환 파이프라인
--
--   확정 스펙:
--   ① affiliate_partners 시드: lenslala.com / lenslala3.com → partner_id=kaiwai
--   ② 비제휴 도메인은 에러 없이 원본 URL 그대로 저장(무변환)
--   ③ 트래킹 파라미터 삭제/위조(partner_id=other 등)는 enforce_affiliate_url 트리거가
--      감지해 강제로 partner_id=kaiwai 로 치환/재주입(Zero-Trust: 클라 값 불신)
--   ④ buses.product_url 에 변환 링크 저장 → 프론트 '주문 바로가기' 가 이 링크 사용
-- ============================================================

-- ── 1. 제휴사 설정(동적) ──
create table if not exists public.affiliate_partners (
  domain      text primary key,          -- 매칭 호스트(소문자, www 제거)
  param_key   text not null,             -- 트래킹 파라미터 키
  param_value text not null,             -- 값
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table public.affiliate_partners enable row level security;
drop policy if exists "제휴사: 활성 조회" on public.affiliate_partners;
create policy "제휴사: 활성 조회" on public.affiliate_partners
  for select to authenticated using (is_active = true);
-- 쓰기 정책 없음 = 운영자(service_role/대시보드)만 관리

insert into public.affiliate_partners(domain, param_key, param_value) values
  ('lenslala.com',  'partner_id', 'kaiwai'),
  ('lenslala3.com', 'partner_id', 'kaiwai')
on conflict (domain) do nothing;

-- ── 2. buses 변환 링크 컬럼 ──
alter table public.buses add column if not exists product_url text;
comment on column public.buses.product_url is '제휴 트래킹 코드가 강제 주입된 주문 링크(서버 트리거가 보증).';

-- ── 3. URL 파라미터 주입 헬퍼 (IMMUTABLE, 멱등) ──
--    프래그먼트(#) 보존 / 기존 key 제거 후 key=val 재부착 / 여러 번 적용해도 동일.
create or replace function public.inject_affiliate_param(p_url text, p_key text, p_val text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v_base text; v_frag text := ''; v_qpos int; v_path text; v_query text; v_clean text;
begin
  if coalesce(p_url, '') = '' then return p_url; end if;

  -- 1) 프래그먼트 분리
  v_base := p_url;
  if position('#' in p_url) > 0 then
    v_base := split_part(p_url, '#', 1);
    v_frag := '#' || substr(p_url, position('#' in p_url) + 1);
  end if;

  -- 2) path ? query 분리
  v_qpos := position('?' in v_base);
  if v_qpos = 0 then
    v_path := v_base; v_query := '';
  else
    v_path := left(v_base, v_qpos - 1); v_query := substr(v_base, v_qpos + 1);
  end if;

  -- 3) 기존 key 토큰 제거 (대소문자 무시). 앞에 '&' 를 붙여 첫 파라미터도 일관 처리.
  v_clean := regexp_replace('&' || v_query, '&' || p_key || '=[^&]*', '', 'gi');
  v_clean := ltrim(v_clean, '&');

  -- 4) key=val 재부착
  if v_clean = '' then
    v_clean := p_key || '=' || p_val;
  else
    v_clean := v_clean || '&' || p_key || '=' || p_val;
  end if;

  return v_path || '?' || v_clean || v_frag;
end;
$$;

-- ── 4. 강제 주입 트리거 (BEFORE INSERT/UPDATE of product_url) ──
--    호스트가 제휴사면 트래킹 코드 강제 주입. 비제휴면 원본 유지(무변환·무에러).
create or replace function public.enforce_affiliate_url()
returns trigger
language plpgsql
security definer            -- affiliate_partners 조회를 RLS 무관하게 보장(Zero-Trust)
set search_path = public
as $$
declare
  v_host text; v_p record;
begin
  if coalesce(new.product_url, '') = '' then return new; end if;

  -- 호스트 추출(스킴/ www 제거, 소문자) — 프론트 _domainOf 와 동일 규칙
  v_host := lower(regexp_replace(new.product_url, '^[a-z]+://', '', 'i'));   -- 스킴 제거
  v_host := regexp_replace(v_host, '^www\.', '');                            -- www 제거
  v_host := split_part(split_part(split_part(v_host, '/', 1), '?', 1), '#', 1);  -- 호스트만

  select * into v_p from public.affiliate_partners where domain = v_host and is_active;
  if found then
    -- 클라가 보낸 product_url 의 트래킹 값은 신뢰하지 않고 우리 값으로 강제 치환/재주입
    new.product_url := public.inject_affiliate_param(new.product_url, v_p.param_key, v_p.param_value);
  end if;
  -- 비제휴 도메인: 원본 그대로 통과(무변환)
  return new;
end;
$$;

drop trigger if exists trg_enforce_affiliate_url on public.buses;
create trigger trg_enforce_affiliate_url
  before insert or update of product_url on public.buses
  for each row execute function public.enforce_affiliate_url();
