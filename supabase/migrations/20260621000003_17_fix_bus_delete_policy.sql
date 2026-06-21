-- ============================================================
-- 17_fix_bus_delete_policy.sql
--   16의 buses DELETE 정책 버그 수정.
--   서브쿼리 `where r.bus_id = id` 에서 bare `id` 가 내부 테이블
--   bus_riders.id 로 해석되어(컬럼명 충돌) NOT EXISTS 가 항상 true →
--   입금자가 있어도 방 삭제가 통과되던 결함. `buses.id` 로 명시해 수정.
-- ============================================================
drop policy if exists "방 삭제: 방장+미주문+입금자0" on public.buses;
create policy "방 삭제: 방장+미주문+입금자0" on public.buses
  for delete to authenticated
  using (
    owner_id = auth.uid()
    and ordered = false
    and not exists (
      select 1 from public.bus_riders r
      where r.bus_id = buses.id and r.paid = true
    )
  );
