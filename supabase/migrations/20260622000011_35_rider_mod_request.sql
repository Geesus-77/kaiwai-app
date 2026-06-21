-- ============================================================
-- 35_rider_mod_request.sql  —  [수정 요청-승인 워크플로우] bus_riders.mod_request + RPC
--
--   배경: guard_bus_rider_update 트리거가 파티원 본인의 qty/yen/amount 직접수정을 동결한다
--         (Zero-Yen 위변조 방어). 그래서 탑승자가 '수량/도수'를 바꾸려면 총대 승인이 필요.
--   설계:
--     · bus_riders.mod_request (jsonb) = 승인 대기 중인 변경안 { qty, power, method, requested_at }.
--       ⚠️ bus_riders 는 공개 SELECT(using true) 이므로 mod_request 에는 PII 를 절대 넣지 않는다
--         (이름/전화/주소 등 개인정보는 bus_rider_private 로 즉시 반영 — 본 컬럼엔 비-PII 만).
--     · 탑승자는 자기 행의 mod_request 만 set (트리거는 mod_request 를 건드리지 않으므로 통과).
--     · 총대가 approve_mod_request 로 승인 → 실제 qty/power/method/amount 덮어쓰고 mod_request=null.
--       이 RPC 안의 UPDATE 는 auth.uid()=방장 → 트리거 is_owner 분기로 동결이 풀려 반영된다(=우회).
--       amount 는 서버가 재계산(yen 불변)하여 클라/요청값 위변조를 무시(Zero-Yen 방어 유지).
-- ============================================================

-- 1) 컬럼 추가
alter table public.bus_riders
  add column if not exists mod_request jsonb;

comment on column public.bus_riders.mod_request is
  '승인 대기 수정안(비-PII): { qty, power, method, requested_at }. 승인 시 null 로 초기화.';

-- 2) 승인 RPC — 방장만, qty/power/method 적용 + amount 서버 재계산 + mod_request 초기화
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
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;

  -- 대상 행 잠금 + 버스/요청 로드
  select bus_id, mod_request, yen
    into v_bus_id, v_req, v_yen
    from public.bus_riders where id = p_rider_id for update;
  if not found then raise exception '대상 라이더를 찾을 수 없습니다' using errcode = 'P0001'; end if;

  select owner_id into v_owner from public.buses where id = v_bus_id;
  if v_owner is distinct from v_uid then
    raise exception '방장만 수정 요청을 승인할 수 있습니다' using errcode = '42501';
  end if;
  if v_req is null then raise exception '대기 중인 수정 요청이 없습니다' using errcode = 'P0001'; end if;

  -- 요청 파싱 + 서버 검증
  v_qty    := coalesce((v_req->>'qty')::int, 1);
  v_power  := coalesce(v_req->>'power', '');
  v_method := coalesce(v_req->>'method', 'conv');
  if v_qty < 1 or v_qty > 100 then raise exception '수량이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if v_method not in ('conv','home','etc') then raise exception '수령 방법이 올바르지 않습니다' using errcode = 'P0001'; end if;
  if char_length(v_power) > 60 then raise exception '도수 값이 올바르지 않습니다' using errcode = 'P0001'; end if;

  -- amount 서버 재계산 (단가 yen 은 변경 불가 → 기존값 사용). 클라/요청 amount 는 신뢰하지 않음.
  v_goods  := v_yen * v_qty * 9;
  v_amount := v_goods + case v_method when 'conv' then 1800 when 'home' then 3500 else 0 end;

  -- 실제 반영 (auth.uid()=방장 → guard_bus_rider_update 트리거 동결 우회)
  update public.bus_riders
     set qty = v_qty, power = v_power, method = v_method, amount = v_amount, mod_request = null
   where id = p_rider_id;

  return jsonb_build_object('ok', true, 'rider_id', p_rider_id, 'qty', v_qty, 'amount', v_amount);
end;
$$;
revoke all on function public.approve_mod_request(uuid) from public, anon;
grant execute on function public.approve_mod_request(uuid) to authenticated;

-- 3) 거절 RPC — 방장만, 적용 없이 mod_request 만 초기화
create or replace function public.reject_mod_request(p_rider_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_bus_id uuid;
  v_owner  uuid;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  select bus_id into v_bus_id from public.bus_riders where id = p_rider_id for update;
  if not found then raise exception '대상 라이더를 찾을 수 없습니다' using errcode = 'P0001'; end if;
  select owner_id into v_owner from public.buses where id = v_bus_id;
  if v_owner is distinct from v_uid then
    raise exception '방장만 처리할 수 있습니다' using errcode = '42501';
  end if;
  update public.bus_riders set mod_request = null where id = p_rider_id;
  return jsonb_build_object('ok', true, 'rejected', true);
end;
$$;
revoke all on function public.reject_mod_request(uuid) from public, anon;
grant execute on function public.reject_mod_request(uuid) to authenticated;
