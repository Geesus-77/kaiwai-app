-- ============================================================
-- 16_bus_slice2.sql  —  렌즈 버스 Slice 2 (주문완료/운송장/이슈/취소)
--   ① bus_riders 컬럼 추가: tracking_number, courier_name, issue_text
--   ② guard 트리거 보강: 비방장은 위 3컬럼도 변경 불가(운송장·문제사유=방장 전용)
--   ③ [분쟁 방어] DELETE RLS 전면 강화:
--      - 방 삭제: 방장 + 미주문(ordered=false) + 입금자(paid) 0명일 때만
--      - 탑승 취소: 본인 + 부모버스 미주문 + 본인 미입금(paid=false)일 때만
--      → 돈 받았거나 주문 시작 후엔 증거 인멸식 삭제 원천 차단
-- ============================================================

-- ── ① 컬럼 추가 ─────────────────────────────────────────────
alter table public.bus_riders add column if not exists tracking_number text;
alter table public.bus_riders add column if not exists courier_name    text;
alter table public.bus_riders add column if not exists issue_text       text;

-- ── ② guard 트리거 보강 (비방장 동결 컬럼 확장) ──────────────
create or replace function public.guard_bus_rider_update()
returns trigger
language plpgsql
as $$
declare
  is_owner boolean;
begin
  select (b.owner_id = auth.uid())
    into is_owner
    from public.buses b
   where b.id = new.bus_id;

  if not coalesce(is_owner, false) then
    -- 결제/이슈 상태: 방장 전용
    new.paid            := old.paid;
    new.issue           := old.issue;
    new.issue_text      := old.issue_text;
    -- 금융·상품 데이터: 무결성
    new.product_name    := old.product_name;
    new.qty             := old.qty;
    new.yen             := old.yen;
    new.power           := old.power;
    new.amount          := old.amount;
    -- 운송장: 방장만 등록/수정
    new.tracking_number := old.tracking_number;
    new.courier_name    := old.courier_name;
  end if;
  return new;
end;
$$;

-- ── ③ DELETE RLS 강화 ───────────────────────────────────────

-- 방 삭제: 방장 + 미주문 + 입금자 0명
drop policy if exists "방장만 방 삭제" on public.buses;
create policy "방 삭제: 방장+미주문+입금자0" on public.buses
  for delete to authenticated
  using (
    owner_id = auth.uid()
    and ordered = false
    and not exists (
      select 1 from public.bus_riders r
      where r.bus_id = id and r.paid = true
    )
  );

-- 탑승 취소: 본인 + 부모버스 미주문 + 본인 미입금
drop policy if exists "장부 삭제: 본인 또는 방장" on public.bus_riders;
create policy "탑승취소: 본인+미주문+미입금" on public.bus_riders
  for delete to authenticated
  using (
    user_id = auth.uid()
    and paid = false
    and exists (
      select 1 from public.buses b
      where b.id = bus_id and b.ordered = false
    )
  );
