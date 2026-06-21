-- ============================================================
-- 31_goal_include_host_product.sql  —  [집계 버그픽스] 목표 달성 검증에 총대 물품가 포함
--
--   문제: 출발(ordered) 목표 검증이 bus_riders 합산(sum(yen*qty))만 봐서
--         총대가 개설 시 입력한 본인 물품가(buses.product_price)가 빠졌다.
--         프론트 current 도 동일하게 누락 → 달성률이 총대 몫만큼 과소 집계.
--   해결: 프론트 _mapBus 는 (product_price + 라이더 합산)으로 수정,
--         백엔드 트리거의 목표 검증도 동일하게 new.product_price 를 더해 정합성 유지.
--   (그 외 guard_bus_order_start 본문 = 마이그29 와 동일: 조기출발 차단 + 총대 수고비 50%)
-- ============================================================
create or replace function public.guard_bus_order_start()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current  integer;
  v_count    integer;
  v_is_admin boolean;
  v_reward   constant integer := 150;   -- 300P 수수료의 50%
begin
  if new.ordered = true and coalesce(old.ordered, false) = false then
    v_is_admin := auth.uid() in (
      '4a612066-9a5d-4da1-905f-fe276fb73908',
      '82feb4b1-5365-4ff9-b68b-ce1b0805a2b2',
      '6b2482ab-ddde-46a2-bb71-f26880619fd2'
    );

    -- 조기 출발 차단(관리자 우회) — 달성 = 총대 본인 물품가 + 탑승자 장부 합산
    if not v_is_admin then
      select coalesce(sum(yen * qty), 0) into v_current
        from public.bus_riders where bus_id = new.id;
      v_current := v_current + coalesce(new.product_price, 0);   -- ★ 총대 물품가 포함
      if v_current < new.goal then
        raise exception '목표 금액 달성 후 출발할 수 있습니다. (현재 %엔 / 목표 %엔)', v_current, new.goal
          using errcode = 'P0001';
      end if;
    end if;

    -- 총대 수고비: 수수료(300P)의 50% = 150P × 탑승 인원, 완료 시 1회 지급
    select count(*) into v_count from public.bus_riders where bus_id = new.id;
    if v_count > 0 then
      perform public._wallet_apply(new.owner_id, v_count * v_reward, 'host_reward', new.id,
                                   'coop completion reward 50% x ' || v_count);
    end if;
  end if;
  return new;
end;
$$;
