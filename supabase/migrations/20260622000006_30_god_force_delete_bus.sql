-- ============================================================
-- 30_god_force_delete_bus.sql  —  God Mode: 관리자 강제 공구 삭제
--
--   문제: 공구 삭제 RLS('방장+미주문(ordered=false)+입금자0')는 관리자도 막는다
--         → 주문 시작/입금자 있는 공구를 관리자가 정리할 방법이 없음.
--   해결: 관리자(ADMIN_IDS) 검증 후 제약 무관 강제 삭제하는 SECURITY DEFINER RPC.
--         탑승자 보호를 위해 보증금(300P)은 전원 자동 환불(원장 'refund' 기록).
--   ※ 클라 'God Override' 토글이 ON 일 때만 이 RPC 를 호출하도록 프론트에서 게이트.
-- ============================================================
create or replace function public.god_force_delete_bus(p_bus_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_deposit  constant integer := 300;
  v_refunded integer := 0;
  v_rrec     record;
begin
  if v_uid is null then raise exception '인증이 필요합니다' using errcode = '28000'; end if;
  if v_uid not in (
    '4a612066-9a5d-4da1-905f-fe276fb73908',
    '82feb4b1-5365-4ff9-b68b-ce1b0805a2b2',
    '6b2482ab-ddde-46a2-bb71-f26880619fd2'
  ) then
    raise exception '관리자 전용 기능입니다' using errcode = '42501';
  end if;

  -- 존재 확인 + 잠금(동시 호출 직렬화)
  perform 1 from public.buses where id = p_bus_id for update;
  if not found then
    raise exception '존재하지 않거나 이미 삭제된 공구입니다' using errcode = 'P0001';
  end if;

  -- 관리자 강제 삭제 → 탑승자 보증금(300P) 전원 자동 환불(유저별 합산, 원장 기록)
  for v_rrec in
    select user_id as uid, count(*)::int as cnt
      from public.bus_riders where bus_id = p_bus_id group by user_id
  loop
    perform public._wallet_apply(v_rrec.uid, v_rrec.cnt * v_deposit, 'refund', p_bus_id, 'god force delete refund');
    v_refunded := v_refunded + 1;
  end loop;

  delete from public.buses where id = p_bus_id;   -- bus_riders / bus_rider_private 는 cascade

  return jsonb_build_object('deleted', true, 'bus_id', p_bus_id, 'refunded_riders', v_refunded);
end;
$$;

revoke all on function public.god_force_delete_bus(uuid) from public, anon;
grant execute on function public.god_force_delete_bus(uuid) to authenticated;
