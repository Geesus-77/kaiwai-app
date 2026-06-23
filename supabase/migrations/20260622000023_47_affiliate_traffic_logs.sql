-- ============================================================
-- 47_affiliate_traffic_logs.sql  —  [Step 9] 제휴 협상용 트래픽 트래킹 파이프라인
--
--   배경: 렌즈라라 공식 제휴 코드 발급 전. 추후 본사 역제안에 쓸 'KAIWAI 경유
--         구매 전환 트래픽 증명' 데이터를 사전 적재.
--   ※ mig46(affiliate_partners·buses.product_url·enforce_affiliate_url) 은 이미 적용됨.
--     본 마이그는 그 위에 ①시드 임시 식별자(kaiwai_test) 전환 ②트래픽 로그 테이블/RPC 추가.
--
--   확정 스펙:
--   ① affiliate_traffic_logs: id·bus_id·user_id(null 허용)·target_domain·click_type·created_at
--   ② RLS: INSERT 누구나(anon+authenticated) / SELECT 관리자만(클릭 조작·유출 차단)
--   ③ log_affiliate_click(p_bus_id, p_click_type) SECURITY DEFINER + search_path 하드닝
--   ④ 확장성: param_value 를 임시값 'kaiwai_test' 로 → 공식 코드 발급 시 UPDATE 한 줄로 교체
-- ============================================================

-- ── 1. 시드 임시 식별자 전환 (공식 코드 발급 시 이 값만 UPDATE 하면 즉시 반영) ──
update public.affiliate_partners set param_value = 'kaiwai_test' where param_value = 'kaiwai';

-- ── 2. 트래픽 로그 테이블 ──
create table if not exists public.affiliate_traffic_logs (
  id            bigint generated always as identity primary key,
  bus_id        uuid not null references public.buses(id) on delete cascade,
  user_id       uuid references auth.users(id) on delete set null,   -- 비로그인 아웃바운드 대비 null 허용
  target_domain text,
  click_type    text not null check (click_type in ('product_view','order_intent')),
  created_at    timestamptz not null default now()
);
create index if not exists idx_aff_traffic_bus  on public.affiliate_traffic_logs(bus_id, created_at desc);
create index if not exists idx_aff_traffic_type on public.affiliate_traffic_logs(click_type, created_at desc);
comment on table public.affiliate_traffic_logs is 'KAIWAI 경유 아웃바운드 클릭 트래픽(제휴 협상 증빙). 적재는 누구나, 조회는 관리자만.';

alter table public.affiliate_traffic_logs enable row level security;
-- INSERT: 누구나(anon+authenticated). 서버 파생필드는 log_affiliate_click 이 채움.
drop policy if exists "트래픽: 누구나 적재" on public.affiliate_traffic_logs;
create policy "트래픽: 누구나 적재" on public.affiliate_traffic_logs
  for insert to anon, authenticated with check (true);
-- SELECT: 관리자만 (Zero-Trust: 클릭 조작/유출 차단)
drop policy if exists "트래픽: 관리자만 조회" on public.affiliate_traffic_logs;
create policy "트래픽: 관리자만 조회" on public.affiliate_traffic_logs
  for select to authenticated using (public.is_app_admin(auth.uid()));
-- UPDATE/DELETE 정책 없음 = 불변 로그

-- ── 3. 로깅 RPC (SECURITY DEFINER + search_path 하드닝) ──
--    외부 링크 이동 직전 호출. 서버가 user_id(auth.uid, 비로그인=null)·target_domain(버스에서) 파생.
create or replace function public.log_affiliate_click(p_bus_id uuid, p_click_type text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_domain text;
  v_id     bigint;
begin
  if p_click_type not in ('product_view','order_intent') then
    raise exception '허용되지 않은 click_type 입니다' using errcode = 'P0001';
  end if;
  select target_domain into v_domain from public.buses where id = p_bus_id;
  if not found then raise exception '존재하지 않는 공구입니다' using errcode = 'P0001'; end if;

  insert into public.affiliate_traffic_logs(bus_id, user_id, target_domain, click_type)
  values (p_bus_id, auth.uid(), v_domain, p_click_type)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.log_affiliate_click(uuid, text) from public;
grant execute on function public.log_affiliate_click(uuid, text) to anon, authenticated;
