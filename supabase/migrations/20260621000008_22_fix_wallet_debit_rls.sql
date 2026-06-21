-- ============================================================
-- 22_fix_wallet_debit_rls.sql
--   [Slice 4 핫픽스] join_coop_bus 의 지갑 차감 RLS 결함 수정
--
--   문제: join_coop_bus 는 SECURITY INVOKER(장부/PII INSERT 를 RLS 로 통제하기 위함)인데,
--         user_wallets 에는 [B안] 설계상 UPDATE 정책이 없다(쓰기는 RPC/service_role 전용).
--         그 결과 invoker 권한의 `SELECT ... FOR UPDATE` 가 UPDATE 정책 부재로 행을 잠그지
--         못해 "지갑 정보를 찾을 수 없습니다"로 실패 → 탑승 자체가 막힘.
--
--   해결: 지갑 차감을 SECURITY DEFINER 헬퍼(debit_coop_deposit)로 위임한다.
--         · 헬퍼는 호출자(auth.uid()) 본인 지갑만 잠그고(FOR UPDATE) 차감 → RLS 우회 합법화.
--         · join_coop_bus 는 INVOKER 유지 → 장부/PII INSERT 는 여전히 RLS 통제(방어선 유지).
--         · 단일 트랜잭션이라 이후 INSERT 실패 시 차감도 함께 롤백(원자성 유지).
--   (기존 verify_host_securely / rpc_cancel_coop_by_host 도 DEFINER 로 지갑·통계를 쓰는
--    동일 패턴이므로 아키텍처 일관성도 유지된다.)
-- ============================================================

-- ── 1. 보증금 차감 헬퍼 (SECURITY DEFINER) ──
--   본인 지갑 행을 잠그고(FOR UPDATE) 잔액을 검증한 뒤 차감한다.
--   잔액 부족/지갑 부재 시 예외 → 호출한 트랜잭션 전체 롤백.
--   직접 호출돼도 '본인 잔액 감소'만 가능(타인·증액 불가)하여 악용 가치가 없다.
create or replace function public.debit_coop_deposit(p_amount integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_balance integer;
begin
  if v_uid is null then
    raise exception '인증이 필요합니다' using errcode = '28000';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception '차감액이 올바르지 않습니다' using errcode = 'P0001';
  end if;

  -- 본인 지갑 행 잠금(동시 차감 직렬화 = 동시성·이중차감 방어선)
  select balance into v_balance
    from public.user_wallets
   where user_id = v_uid
   for update;
  if not found then
    raise exception '지갑 정보를 찾을 수 없습니다' using errcode = 'P0001';
  end if;
  if v_balance < p_amount then
    raise exception '포인트가 부족합니다. (탑승 안심 수수료 % P 필요)', p_amount using errcode = 'P0001';
  end if;

  update public.user_wallets
     set balance = balance - p_amount
   where user_id = v_uid;

  return v_balance - p_amount;
end;
$$;

revoke all on function public.debit_coop_deposit(integer) from public, anon;
grant execute on function public.debit_coop_deposit(integer) to authenticated;


-- ── 2. join_coop_bus 재정의 (지갑 차감을 DEFINER 헬퍼로 위임) ──
--   변경점만:
--     · 기존 인라인 `SELECT balance ... FOR UPDATE`(RLS로 실패) → 비잠금 SELECT 로 fail-fast 만.
--     · 기존 인라인 `UPDATE user_wallets ... balance-300` → `perform debit_coop_deposit(300)`.
--   그 외 검증(중복탑승·길이폭탄·수량/단가·Zero-Yen·마감) 및 원자적 2단 INSERT 는 동일.
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
begin
  if v_uid is null then
    raise exception '인증이 필요합니다' using errcode = '28000';
  end if;

  -- ── [방어 0.5] 포인트 잔액 fail-fast (비잠금 읽기) ──
  --   실제 차감/락은 아래 debit_coop_deposit(DEFINER)이 담당. 여기선 조기 거부만.
  select balance into v_balance from public.user_wallets where user_id = v_uid;
  if v_balance is null then
    raise exception '지갑 정보를 찾을 수 없습니다' using errcode = 'P0001';
  end if;
  if v_balance < 300 then
    raise exception '포인트가 부족합니다. (탑승 안심 수수료 300P 필요)' using errcode = 'P0001';
  end if;

  -- ── [방어 0] 중복 탑승(1인 다역) 차단 ──
  if exists (select 1 from public.bus_riders where bus_id = p_bus_id and user_id = v_uid) then
    raise exception '이미 탑승한 버스입니다' using errcode = 'P0001';
  end if;

  -- ── [방어 1] 데이터 폭탄(Data Bombing): 텍스트 길이 상한 ──
  if coalesce(length(p_nick),0)         > 40  then raise exception '닉네임이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_product_name),0) > 200 then raise exception '상품명이 너무 깁니다'   using errcode = 'P0001'; end if;
  if coalesce(length(p_power),0)        > 60  then raise exception '도수 값이 비정상입니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_real_name),0)    > 40  then raise exception '실명이 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_phone),0)        > 20  then raise exception '전화번호가 비정상입니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_payer),0)        > 40  then raise exception '입금자명이 너무 깁니다' using errcode = 'P0001'; end if;
  if coalesce(length(p_address),0)      > 200 then raise exception '주소가 너무 깁니다'     using errcode = 'P0001'; end if;
  if coalesce(length(p_memo),0)         > 100 then raise exception '메모가 너무 깁니다'     using errcode = 'P0001'; end if;

  -- ── [방어 2] 수량/단가 무결성: 음수·0·과다 차단 ──
  if p_qty <= 0 or p_qty > 100 then
    raise exception '수량이 올바르지 않습니다' using errcode = 'P0001';
  end if;
  if p_yen < 0 or p_yen > 1000000 then
    raise exception '단가가 올바르지 않습니다' using errcode = 'P0001';
  end if;
  if p_method not in ('conv','home','etc') then
    raise exception '수령방법이 올바르지 않습니다' using errcode = 'P0001';
  end if;

  -- ── [방어 3] 금액 위변조(Zero-Yen Hack) 강제 검증 ──
  v_goods := p_yen * p_qty * 9;
  v_fee   := case p_method when 'conv' then 1800
                           when 'home' then 3500
                           else p_amount - v_goods end;
  if p_method in ('conv','home') then
    if p_amount <> v_goods + v_fee then
      raise exception '금액이 변조되었습니다.' using errcode = 'P0001';
    end if;
  else
    if p_amount < v_goods or (p_amount - v_goods) > 100000 then
      raise exception '금액이 변조되었습니다.' using errcode = 'P0001';
    end if;
  end if;

  -- ── 고스트 라이더 방어: 마감/부재 버스엔 탑승 불가 ──
  if not exists (select 1 from public.buses b where b.id = p_bus_id and b.ordered = false) then
    raise exception '이미 마감되었거나 존재하지 않는 공구입니다' using errcode = 'P0001';
  end if;

  -- ── 포인트 300P 실제 차감 (DEFINER 헬퍼 = 락 + 권위적 재검증) ──
  --   잔액 부족이면 여기서 예외 → 트랜잭션 전체 롤백(장부 미생성·미차감).
  perform public.debit_coop_deposit(300);

  -- ① 투명 장부 INSERT
  insert into public.bus_riders
    (bus_id, user_id, nick, product_name, qty, yen, power, method, amount, paid, issue, has_addr, memo)
  values
    (p_bus_id, v_uid, p_nick, p_product_name, coalesce(p_qty,1), coalesce(p_yen,0), p_power,
     coalesce(p_method,'conv'), coalesce(p_amount,0), false, null, true, p_memo)
  returning id into v_rider_id;

  -- ② 개인정보 INSERT (실패 시 ①·차감까지 함께 롤백 = 원자성)
  insert into public.bus_rider_private
    (rider_id, bus_id, user_id, real_name, phone, address, payer)
  values
    (v_rider_id, p_bus_id, v_uid, p_real_name, p_phone, p_address, p_payer);

  return v_rider_id;
end;
$$;
