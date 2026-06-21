-- ============================================================
-- 21_slice4_points.sql
--   지갑/포인트 서버화 (Slice 4)
--   0. user_wallets.points_synced 플래그 (로컬 포인트 1회 동기화 멱등 가드)
--   1. 타인 신뢰도 조회용 RPC (get_host_trust_score)
--   2. 로컬 포인트 1회 동기화용 RPC (sync_local_points)
--   3. join_coop_bus RPC 수정 (300P 자동 차감 로직 추가)
-- ============================================================

-- ── 0. 로컬 포인트 1회 동기화 가드 컬럼 ──
--   잔액(balance==0)으로 "이미 동기화함"을 판정하면, 포인트를 0까지 소진한 뒤
--   sync RPC 를 재호출해 무한 발행이 가능하다(어뷰징). 별도 플래그로 1회 멱등 보장.
alter table public.user_wallets
  add column if not exists points_synced boolean not null default false;

-- ── 1. 타인 신뢰도 안전 조회용 RPC (SECURITY DEFINER) ──
create or replace function public.get_host_trust_score(p_host_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trust integer;
  v_suspended boolean;
begin
  select trust_score, is_host_suspended
    into v_trust, v_suspended
    from public.user_coop_stats
   where user_id = p_host_id;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'trust_score', v_trust,
    'is_host_suspended', v_suspended
  );
end;
$$;

revoke all on function public.get_host_trust_score(uuid) from public, anon;
grant execute on function public.get_host_trust_score(uuid) to authenticated;


-- ── 2. 기존 로컬 포인트 서버 1회 마이그레이션용 ──
create or replace function public.sync_local_points(p_points integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_balance integer;
  v_synced  boolean;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if p_points <= 0 then p_points := 0; end if;

  -- 어뷰징 방지: 1회 최대 인정 한도를 10,000 포인트로 제한
  if p_points > 10000 then p_points := 10000; end if;

  -- 지갑 행 잠금(동시 호출 직렬화) + 동기화 여부 확인
  select balance, points_synced
    into v_balance, v_synced
    from public.user_wallets
   where user_id = v_uid
   for update;

  if not found then
    insert into public.user_wallets (user_id, balance, points_synced)
      values (v_uid, p_points, true);
    return p_points;
  end if;

  -- ★ 플래그 기반 멱등: 이미 1회 동기화했다면 추가 적립 없음(무한 발행 차단).
  --   잔액을 0까지 소진한 뒤 재호출해도 points_synced=true 라 거부됨.
  if v_synced then
    return v_balance;
  end if;

  update public.user_wallets
     set balance = balance + p_points,
         points_synced = true
   where user_id = v_uid;

  return v_balance + p_points;
end;
$$;

revoke all on function public.sync_local_points(integer) from public, anon;
grant execute on function public.sync_local_points(integer) to authenticated;


-- ── 3. join_coop_bus RPC 수정 (포인트 300P 차감) ──
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

  -- ── [방어 0.5] 포인트 300P 차감 (Zero Trust) ──
  -- 잔액 부족 검증을 우선 처리하여 트랜잭션 롤백
  select balance into v_balance from public.user_wallets where user_id = v_uid for update;
  if not found then
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

  -- 포인트 300P 실제 차감
  update public.user_wallets set balance = balance - 300 where user_id = v_uid;

  -- ① 투명 장부 INSERT
  insert into public.bus_riders
    (bus_id, user_id, nick, product_name, qty, yen, power, method, amount, paid, issue, has_addr, memo)
  values
    (p_bus_id, v_uid, p_nick, p_product_name, coalesce(p_qty,1), coalesce(p_yen,0), p_power,
     coalesce(p_method,'conv'), coalesce(p_amount,0), false, null, true, p_memo)
  returning id into v_rider_id;

  -- ② 개인정보 INSERT (실패 시 ①까지 함께 롤백 = 원자성)
  insert into public.bus_rider_private
    (rider_id, bus_id, user_id, real_name, phone, address, payer)
  values
    (v_rider_id, p_bus_id, v_uid, p_real_name, p_phone, p_address, p_payer);

  return v_rider_id;
end;
$$;
