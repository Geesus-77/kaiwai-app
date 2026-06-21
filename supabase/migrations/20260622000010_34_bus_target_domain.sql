-- ============================================================
-- 34_bus_target_domain.sql  —  [구매처 도메인 강제화] buses.target_domain
--
--   목적: 공구 개설 시 총대가 입력한 상품 링크의 도메인(예: lenslala3.com)을 저장해 두고,
--         탑승자가 다른 사이트(예: 파스비/타 쇼핑몰) 상품 링크로 엉뚱한 물건을 담는 것을
--         방지(도메인 락). 검증의 1차 책임은 프론트지만 데이터는 서버(SSOT)에 보관.
--   컬럼: target_domain text (nullable) — 'www.' 제거한 호스트명. null = 잠금 없음.
-- ============================================================
alter table public.buses
  add column if not exists target_domain text;

comment on column public.buses.target_domain is
  '구매처 도메인 락 — 개설 링크의 호스트(소문자, www 제거). null 이면 제한 없음.';
