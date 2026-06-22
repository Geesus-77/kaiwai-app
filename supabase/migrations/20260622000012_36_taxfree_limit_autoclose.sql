-- ============================================================
-- 36_taxfree_limit_autoclose.sql  —  [과제5] 면세 한도(goal) 초과 철통방어 + 자동 마감
--
--   목적: 관부가세 폭탄 방지. 공구 총합(엔)이 goal 을 1엔이라도 초과하는 탑승/수량변경을
--         서버에서 강제 차단(B안). 정확히 goal 에 도달(100%)하면 즉시 자동 마감(ordered=true).
--   정합성: 프론트 current = product_price + Σ(riders yen*qty) 이고 '남은 한도 = goal - current'.
--           기존 출발검증(마이그31)도 product_price 를 더해 goal 과 비교. → 본 한도검사도 동일하게
--           '총대 물품가 + 전 탑승자 yen*qty' 총합으로 계산해야 프론트/백/자동마감 시점이 일치.
--   구조: 자동 마감은 SECURITY DEFINER 헬퍼(auto_close_bus_if_full)로 위임 — join_coop_bus 가
--         SECURITY INVOKER 라 탑승자(비방장)는 buses 를 직접 UPDATE 할 RLS 권한이 없기 때문.
--         헬퍼의 UPDATE 는 기존 guard_bus_order_start 트리거를 그대로 태워(목표달성 검증 통과 +
--         총대 수고비 지급) 정상 완료 경로와 동일하게 마감된다.
-- ============================================================

-- 1) 자동 마감 헬퍼 — 총합(총대물품 + 라이더 yen*qty) >= goal 이면 ordered=true
create or replace function public.auto_close_bus_if_full(p_bus_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_goal    integer;
  v_pprice  integer;
  v_ordered boolean;
  v_total   integer;
begin
  select goal, coalesce(product_price, 0), ordered
    into v_goal, v_pprice, v_ordered
    from public.buses where id = p_bus_id for update;
  if not found or v_ordered then return false; end if;

  select v_pprice + coalesce(sum(yen * qty), 0)
    into v_total
    from public.bus_riders where bus_id = p_bus_id;

  if v_total >= v_goal then
    -- guard_bus_order_start 트리거가 목표달성(>=goal) 검증 + 총대 수고비 지급을 처리
    update public.buses set ordered = true where id = p_bus_id;
    return true;
  end if;
  return false;
end;
$$;
revoke all on function public.auto_close_bus_if_full(uuid) from public, anon;
grant execute on function public.auto_close_bus_if_full(uuid) to authenticated;

-- 2) join_coop_bus 재정의 — [방어4] 면세 한도 초과 차단 + INSERT 후 자동 마감
--    (그 외 본문 = 마이그23 과 동일)
create or replace function public.join_coop_bus(
  p_bus_id       uuid,
  p_nick         text,
  p_product_name text,
  p_qty          integer,
  p_yen          integer,
  p_power        text,
  p_method       text,
  p_amount       integer,
  p_real_name    text,
  p_phone        text,
  p_address      text,
  p_payer        text,
  p_memo         text default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_rider_id uuid;
  v_goods    integer;
  v_fee      integer;
  v_balance  integer;
  v_goal     integer;
  v_pprice   integer;
  v_rsum     integer;
  v_total    integer;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  -- [방어 0.5] 잔액 fail-fast (비잠금) — 실제 차감/락은 debit_coop_deposit 이 담당
  select balance into v_balance from public.user_wallets where user_id = v_uid;
  if v_balance is null then raise exception '지갑 정보를 찾을 수 없습니다' using errcode = 'P0001'; end if;
  if v_balance < 300 then
    raise exception '포인트가 부족합니다. (탑승 안심 수수료 300P 필요)' using errcode = 'P0001';
  end if;

  -- [방어 0] 중복 탑승 차단
  if exists (select 1 from public.bus_riders where bus_id = p_bus_id and user_id = v_uid) then
    raise exception '이미 탑승한 버스입니다' using errcode = 'P0001';
  end if;

  -- [방어 1] 데이터 폭탄: 텍스트 길이 상한
  if coalesce(length(p_nick),0)         > 40  then raise exception '닉네임이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_product_name),0) > 200 then raise exception '상품명이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_power),0)        > 60  then raise exception '도수 값이 비정상입니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_real_name),0)    > 40  then raise exception '실명이 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_phone),0)        > 20  then raise exception '전화번호가 비정상입니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_payer),0)        > 40  then raise exception '입금자명이 너무 깁니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_address),0)      > 200 then raise exception '주소가 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_memo),0)         > 100 then raise exception '메모가 너무 깁니다'     using errcode = 'P0001'; end if;

  -- [방어 2] 수량/단가 무결성
  if p_qty <= 0 or p_qty > 100 then raise exception '수량이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if p_yen < 0 or p_yen > 1000000 then raise exception '단가가 올바르지 않습니다' using errcode = 'P0001'; end if;
  if p_method not in ('conv','home','etc') then raise exception '수령방법이 올바르지 않습니다' using errcode = 'P0001'; end if;

  -- [방어 3] 금액 위변조(Zero-Yen) 강제 검증
  v_goods := p_yen * p_qty * 9;
  v_fee   := case p_method when 'conv' then 1800 when 'home' then 3500 else p_amount - v_goods end;
  if p_method in ('conv','home') then
    if p_amount <> v_goods + v_fee then raise exception '금액이 변조되었습니다.' using errcode = 'P0001'; end if;
  else
    if p_amount < v_goods or (p_amount - v_goods) > 100000 then raise exception '금액이 변조되었습니다.' using errcode = 'P0001'; end if;
  end if;

  -- 고스트 라이더 방어: 마감/부재 버스 차단
  if not exists (select 1 from public.buses b where b.id = p_bus_id and b.ordered = false) then
    raise exception '이미 마감되었거나 존재하지 않는 공구입니다' using errcode = 'P0001';
  end if;

  -- [방어 4] 면세 한도(goal) 초과 차단 — 총대 물품가 + 기존 탑승 + 이번 탑승 의 yen*qty 합
  select goal, coalesce(product_price, 0) into v_goal, v_pprice from public.buses where id = p_bus_id;
  select coalesce(sum(yen * qty), 0) into v_rsum from public.bus_riders where bus_id = p_bus_id;
  v_total := v_pprice + v_rsum + (coalesce(p_yen, 0) * coalesce(p_qty, 1));
  if v_total > v_goal then
    raise exception '해당 공구의 남은 한도(엔)를 초과하여 탑승할 수 없습니다.' using errcode = 'P0001';
  end if;

  -- 300P 차감 (락+권위검증+원장 'board' 기록). 잔액부족이면 여기서 롤백.
  perform public.debit_coop_deposit(300, p_bus_id);

  insert into public.bus_riders
    (bus_id, user_id, nick, product_name, qty, yen, power, method, amount, paid, issue, has_addr, memo)
  values
    (p_bus_id, v_uid, p_nick, p_product_name, coalesce(p_qty,1), coalesce(p_yen,0), p_power,
     coalesce(p_method,'conv'), coalesce(p_amount,0), false, null, true, p_memo)
  returning id into v_rider_id;

  insert into public.bus_rider_private
    (rider_id, bus_id, user_id, real_name, phone, address, payer)
  values
    (v_rider_id, p_bus_id, v_uid, p_real_name, p_phone, p_address, p_payer);

  -- 100% 달성 시 자동 마감 (총합 == goal). 초과는 위에서 이미 차단됨.
  perform public.auto_close_bus_if_full(p_bus_id);

  return v_rider_id;
end;
$$;

-- 3) approve_mod_request 재정의 — 수량변경 승인 시 한도 초과 차단 + 자동 마감
--    (그 외 본문 = 마이그35 와 동일)
create or replace function public.approve_mod_request(p_rider_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_bus_id uuid;
  v_owner  uuid;
  v_req    jsonb;
  v_yen    integer;
  v_qty    integer;
  v_power  text;
  v_method text;
  v_goods  integer;
  v_amount integer;
  v_goal   integer;
  v_pprice integer;
  v_others integer;
  v_total  integer;
  v_closed boolean;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  select bus_id, mod_request, yen
    into v_bus_id, v_req, v_yen
    from public.bus_riders where id = p_rider_id for update;
  if not found then raise exception '대상 라이더를 찾을 수 없습니다' using errcode = 'P0001'; end if;

  select owner_id into v_owner from public.buses where id = v_bus_id;
  if v_owner is distinct from v_uid then
    raise exception '방장만 수정 요청을 승인할 수 있습니다' using errcode = '42501';
  end if;
  if v_req is null then raise exception '대기 중인 수정 요청이 없습니다' using errcode = 'P0001'; end if;

  v_qty    := coalesce((v_req->>'qty')::int, 1);
  v_power  := coalesce(v_req->>'power', '');
  v_method := coalesce(v_req->>'method', 'conv');
  if v_qty < 1 or v_qty > 100 then raise exception '수량이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if v_method not in ('conv','home','etc') then raise exception '수령 방법이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if char_length(v_power) > 60 then raise exception '도수 값이 올바르지 않습니다' using errcode = 'P0001'; end if;

  -- [면세 한도 방어] 변경 수량 적용 시 총합(총대물품 + 타 라이더 + 본인 새 수량) > goal 이면 거부
  select goal, coalesce(product_price, 0) into v_goal, v_pprice from public.buses where id = v_bus_id;
  select coalesce(sum(yen * qty), 0) into v_others
    from public.bus_riders where bus_id = v_bus_id and id <> p_rider_id;
  v_total := v_pprice + v_others + (v_yen * v_qty);
  if v_total > v_goal then
    raise exception '수량을 늘리면 공구방의 남은 면세 한도를 초과하게 되어 승인할 수 없습니다.' using errcode = 'P0001';
  end if;

  -- amount 서버 재계산 (단가 yen 불변). 클라/요청 amount 는 신뢰하지 않음.
  v_goods  := v_yen * v_qty * 9;
  v_amount := v_goods + case v_method when 'conv' then 1800 when 'home' then 3500 else 0 end;

  -- 실제 반영 (auth.uid()=방장 → guard_bus_rider_update 트리거 동결 우회)
  update public.bus_riders
     set qty = v_qty, power = v_power, method = v_method, amount = v_amount, mod_request = null
   where id = p_rider_id;

  -- 100% 달성 시 자동 마감
  v_closed := public.auto_close_bus_if_full(v_bus_id);

  return jsonb_build_object('ok', true, 'rider_id', p_rider_id, 'qty', v_qty, 'amount', v_amount, 'closed', coalesce(v_closed, false));
end;
$$;
revoke all on function public.approve_mod_request(uuid) from public, anon;
grant execute on function public.approve_mod_request(uuid) to authenticated;
