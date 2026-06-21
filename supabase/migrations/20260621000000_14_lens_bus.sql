-- ============================================================
-- 14_lens_bus.sql  —  안심 렌즈 공구(렌즈 버스) 백엔드 (Slice 1)
--   공구방 / 투명 장부 / 개인정보 분리 + 블랙컨슈머 방어 RLS
--
--   설계 원칙
--   ① PII(실명/전화/주소)는 bus_rider_private 로 물리 분리 → 컬럼 유출 원천 차단
--   ② verified_host 셀프 승격 차단: 일반 UPDATE 로는 변경 불가,
--      SECURITY DEFINER RPC verify_host_securely() 로만 승격
--   ③ 고스트 라이더 방어: 버스 ordered=true 이면 신규 탑승 INSERT 차단
--   ④ PII 수정 잠금: ordered=true 또는 본인 paid=true 면 주소 수정 불가
--   ⑤ 자가 입금승인 차단: 방장이 아니면 paid/issue 변경 불가(트리거)
-- ============================================================

-- ── 0. profiles.verified_host ───────────────────────────────
alter table public.profiles
  add column if not exists verified_host boolean not null default false;

-- verified_host 셀프 승격 방지 트리거 ─────────────────────────
--   일반 경로(클라이언트 UPDATE)로는 verified_host 변경을 무시(되돌림).
--   verify_host_securely() RPC 만 트랜잭션-로컬 GUC(app.allow_host_verify)
--   를 '1' 로 세팅하므로, 그 경로에서만 변경이 허용됨.
create or replace function public.protect_verified_host()
returns trigger
language plpgsql
as $$
begin
  if new.verified_host is distinct from old.verified_host
     and coalesce(current_setting('app.allow_host_verify', true), '') <> '1' then
    new.verified_host := old.verified_host;   -- 비인가 변경은 조용히 되돌림
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_verified_host on public.profiles;
create trigger trg_protect_verified_host
  before update on public.profiles
  for each row execute function public.protect_verified_host();

-- 안전한 총대 승격 RPC (클라이언트는 오직 이것만 호출) ─────────
create or replace function public.verify_host_securely()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception '인증이 필요합니다';
  end if;
  -- 트랜잭션-로컬 플래그: 이 호출에서만 verified_host 변경 허용
  perform set_config('app.allow_host_verify', '1', true);
  update public.profiles
     set verified_host = true
   where id = auth.uid();
end;
$$;

revoke all on function public.verify_host_securely() from public;
grant execute on function public.verify_host_securely() to authenticated;


-- ── 1. buses (공구방 원장) ──────────────────────────────────
create table if not exists public.buses (
  id            uuid        primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  owner_id      uuid        not null references public.profiles(id) on delete cascade,
  captain       text        not null,                         -- 방장 닉 스냅샷(표시용)
  tier          text        not null default 'beginner',      -- 'pro' | 'beginner'
  title         text        not null,
  notice        text,
  goal          integer     not null default 0,               -- 목표 금액(엔)
  product_name  text        not null,
  product_img   text,
  product_price integer     not null default 0,               -- 단가(엔)
  host_account  jsonb,                                         -- { bankName, accountNumber, realName }
  ordered       boolean     not null default false            -- 주문 완료 → 탑승/수정 잠금
);
create index if not exists idx_buses_owner   on public.buses(owner_id);
create index if not exists idx_buses_created on public.buses(created_at desc);

-- ── 2. bus_riders (투명 장부 · PII 없음) ────────────────────
create table if not exists public.bus_riders (
  id           uuid        primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  bus_id       uuid        not null references public.buses(id) on delete cascade,
  user_id      uuid        not null references public.profiles(id) on delete cascade,
  nick         text        not null,
  product_name text        not null,
  qty          integer     not null default 1,
  yen          integer     not null default 0,                -- 단가(엔)
  power        text,
  method       text        not null default 'conv',           -- 'conv' | 'home' | 'etc'
  amount       integer     not null default 0,                -- 총 결제액(원)
  paid         boolean     not null default false,            -- 방장 입금 승인
  issue        text,                                          -- soldout | short | address | etc | null
  has_addr     boolean     not null default true,
  memo         text
);
create index if not exists idx_bus_riders_bus  on public.bus_riders(bus_id);
create index if not exists idx_bus_riders_user on public.bus_riders(user_id);

-- 자가 입금승인 + 금액 위변조 차단 트리거 ────────────────────
--   방장(buses.owner_id)이 아닌 사람(=파티원 본인)이 자기 행을 UPDATE 할 때
--   ① 결제상태(paid/issue)  ② 금융/상품 데이터(product_name/qty/yen/power/amount)
--   를 절대 변경하지 못하도록 OLD 값으로 강제 복원한다.
--   (Zero-Yen Hack: 악성 파티원이 yen/qty/amount 를 0 으로 조작하는 공격 차단)
--   파티원이 바꿀 수 있는 건 method/has_addr/memo 등 비금융 필드뿐.
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
    new.paid         := old.paid;
    new.issue        := old.issue;
    -- 금융·상품 데이터: 제출 후 본인도 변경 불가 (무결성 보장)
    new.product_name := old.product_name;
    new.qty          := old.qty;
    new.yen          := old.yen;
    new.power        := old.power;
    new.amount       := old.amount;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_bus_rider_update on public.bus_riders;
create trigger trg_guard_bus_rider_update
  before update on public.bus_riders
  for each row execute function public.guard_bus_rider_update();

-- ── 3. bus_rider_private (개인정보 · 잠금) ──────────────────
create table if not exists public.bus_rider_private (
  rider_id   uuid primary key references public.bus_riders(id) on delete cascade,
  bus_id     uuid not null references public.buses(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  real_name  text,
  phone      text,
  address    text,
  payer      text
);
create index if not exists idx_bus_rider_private_bus  on public.bus_rider_private(bus_id);
create index if not exists idx_bus_rider_private_user on public.bus_rider_private(user_id);


-- ============================================================
--  RLS
-- ============================================================

-- buses ──────────────────────────────────────────────────────
alter table public.buses enable row level security;

create policy "공구방 공개 조회" on public.buses
  for select using (true);

-- 개설은 '본인 소유 + verified_host=true' 일 때만 (총대 인증 DB 강제)
create policy "인증 총대만 개설" on public.buses
  for insert to authenticated
  with check (
    auth.uid() = owner_id
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.verified_host = true
    )
  );

create policy "방장만 방 수정" on public.buses
  for update to authenticated
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

create policy "방장만 방 삭제" on public.buses
  for delete to authenticated
  using (auth.uid() = owner_id);

-- bus_riders ─────────────────────────────────────────────────
alter table public.bus_riders enable row level security;

create policy "장부 공개 조회" on public.bus_riders
  for select using (true);

-- 탑승: 본인 + 해당 버스가 아직 마감(ordered) 전일 때만 (고스트 라이더 방어)
create policy "탑승은 본인+마감전" on public.bus_riders
  for insert to authenticated
  with check (
    auth.uid() = user_id
    and exists (
      select 1 from public.buses b
      where b.id = bus_id and b.ordered = false
    )
  );

-- 수정: 본인(내 정보 수정) 또는 방장(승인/이슈). 결제상태 변경은 트리거가 추가 통제.
create policy "장부 수정: 본인 또는 방장" on public.bus_riders
  for update to authenticated
  using (
    auth.uid() = user_id
    or exists (select 1 from public.buses b where b.id = bus_id and b.owner_id = auth.uid())
  )
  with check (
    auth.uid() = user_id
    or exists (select 1 from public.buses b where b.id = bus_id and b.owner_id = auth.uid())
  );

create policy "장부 삭제: 본인 또는 방장" on public.bus_riders
  for delete to authenticated
  using (
    auth.uid() = user_id
    or exists (select 1 from public.buses b where b.id = bus_id and b.owner_id = auth.uid())
  );

-- bus_rider_private ──────────────────────────────────────────
alter table public.bus_rider_private enable row level security;

-- 조회: 본인 또는 그 방의 방장만 (PII 보호 핵심)
create policy "개인정보 본인+방장만 조회" on public.bus_rider_private
  for select to authenticated
  using (
    auth.uid() = user_id
    or exists (select 1 from public.buses b where b.id = bus_id and b.owner_id = auth.uid())
  );

-- 입력: 본인 + 마감 전 (고스트 라이더 방어)
create policy "개인정보 본인 입력+마감전" on public.bus_rider_private
  for insert to authenticated
  with check (
    auth.uid() = user_id
    and exists (select 1 from public.buses b where b.id = bus_id and b.ordered = false)
  );

-- 수정 잠금: 본인 + (버스 ordered=false) + (본인 paid=false)
create policy "개인정보 수정 잠금" on public.bus_rider_private
  for update to authenticated
  using (
    auth.uid() = user_id
    and exists (select 1 from public.buses b where b.id = bus_id and b.ordered = false)
    and exists (select 1 from public.bus_riders r where r.id = rider_id and r.paid = false)
  )
  with check (auth.uid() = user_id);

-- 삭제: 본인 또는 방장 (탑승 취소/방 정리)
create policy "개인정보 삭제: 본인 또는 방장" on public.bus_rider_private
  for delete to authenticated
  using (
    auth.uid() = user_id
    or exists (select 1 from public.buses b where b.id = bus_id and b.owner_id = auth.uid())
  );


-- ============================================================
--  원자적 탑승 RPC  join_coop_bus
--    클라이언트가 bus_riders + bus_rider_private 를 두 번의 HTTP INSERT 로
--    나눠 보내면 트랜잭션이 보장되지 않아 '좀비 데이터'(장부만 있고 PII 없음)가
--    생길 수 있다. plpgsql 함수는 단일 트랜잭션으로 실행되므로, 두 INSERT 중
--    하나라도 실패하면 함수 전체가 원자적으로 롤백된다.
--    SECURITY INVOKER → 내부 INSERT 도 RLS(본인 + ordered=false)의 통제를 받음.
-- ============================================================
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
  v_goods    integer;   -- 상품가(원) = yen × qty × 9
  v_fee      integer;   -- 수령방법별 배송비(원)
begin
  if v_uid is null then
    raise exception '인증이 필요합니다' using errcode = '28000';
  end if;

  -- ── [방어 1] 데이터 폭탄(Data Bombing) 방어: 텍스트 길이 상한 ──
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

  -- ── [방어 3] 금액 위변조(Zero-Yen Hack) 강제 검증: 서버가 직접 재계산 ──
  --   상품가 = 단가 × 수량 × 9(YEN_TO_KRW). 배송비는 수령방법별 고정값으로 검증.
  --   conv/home 은 1원이라도 다르면 차단. etc(직접입력)는 음수/과다(10만원↑)만 차단.
  v_goods := p_yen * p_qty * 9;
  v_fee   := case p_method when 'conv' then 1800
                           when 'home' then 3500
                           else p_amount - v_goods end;   -- etc: 클라가 보낸 배송비 역산
  if p_method in ('conv','home') then
    if p_amount <> v_goods + v_fee then
      raise exception '금액이 변조되었습니다.' using errcode = 'P0001';
    end if;
  else  -- etc
    if p_amount < v_goods or (p_amount - v_goods) > 100000 then
      raise exception '금액이 변조되었습니다.' using errcode = 'P0001';
    end if;
  end if;

  -- ── 고스트 라이더 방어 (RLS 와 이중 통제): 마감/부재 버스엔 탑승 불가 ──
  if not exists (select 1 from public.buses b where b.id = p_bus_id and b.ordered = false) then
    raise exception '이미 마감되었거나 존재하지 않는 공구입니다' using errcode = 'P0001';
  end if;

  -- ① 투명 장부 INSERT (금액은 서버가 받은 값 그대로 — 이후 본인 UPDATE 는 트리거가 동결)
  insert into public.bus_riders
    (bus_id, user_id, nick, product_name, qty, yen, power, method, amount, paid, issue, has_addr, memo)
  values
    (p_bus_id, v_uid, p_nick, p_product_name, coalesce(p_qty,1), coalesce(p_yen,0), p_power,
     coalesce(p_method,'conv'), coalesce(p_amount,0), false, null, true, p_memo)
  returning id into v_rider_id;

  -- ② 개인정보 INSERT (실패 시 ① 까지 함께 롤백됨 = 원자성)
  insert into public.bus_rider_private
    (rider_id, bus_id, user_id, real_name, phone, address, payer)
  values
    (v_rider_id, p_bus_id, v_uid, p_real_name, p_phone, p_address, p_payer);

  return v_rider_id;
end;
$$;

revoke all on function public.join_coop_bus(
  uuid, text, text, integer, integer, text, text, integer, text, text, text, text, text
) from public;
grant execute on function public.join_coop_bus(
  uuid, text, text, integer, integer, text, text, integer, text, text, text, text, text
) to authenticated;


-- ── 4. 권한 부여 (Supabase 기본 default privileges 보강) ────
grant select on public.buses to anon, authenticated;
grant insert, update, delete on public.buses to authenticated;

grant select on public.bus_riders to anon, authenticated;
grant insert, update, delete on public.bus_riders to authenticated;

grant select, insert, update, delete on public.bus_rider_private to authenticated;
