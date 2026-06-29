-- ============================================================
-- 53_short_links.sql — 공구 주문서 카이와이 단축링크(리다이렉트) + 클릭추적
--
--   목적: '전체 주문내역' 팝업에서 참여자 상품 URL 을 kaiwai.kr/o/<코드> 형태의
--         짧은 카이와이 링크로 표시·복사. 클릭 시 Edge Function `o` 가 원본
--         상품페이지로 302 리다이렉트(+utm_source=kaiwai_coop) 하고 클릭수 적재.
--   ※ mig46/47 의 affiliate(커미션) 파이프라인과는 별개 — 여긴 순수 단축/리다이렉트.
--
--   확정 스펙:
--   ① short_links(code PK, url UNIQUE, clicks, created_at) — 같은 URL=같은 코드 재사용
--   ② kw_shorten(p_url): 코드 생성/재사용. http(s) URL 만 허용(오픈리다이렉트 방어),
--      authenticated 만 실행(익명 단축 남용 차단). url unique + on conflict 로 경합 안전.
--   ③ kw_shorten_many(p_urls[]): 팝업에서 여러 URL 일괄 변환(부분 성공 허용).
--   ④ kw_resolve(p_code): 코드→원본 URL 반환 + clicks+1. service_role(Edge Function) 전용.
--   ⑤ RLS: 테이블 직접접근 차단 — 모든 접근은 SECURITY DEFINER 함수 경유(Zero-Trust).
-- ============================================================

create table if not exists public.short_links (
  code       text primary key,
  url        text not null unique,
  clicks     integer not null default 0,
  created_at timestamptz not null default now()
);
comment on table public.short_links is '공구 주문서 카이와이 단축링크(코드→원본 상품URL) + 클릭수. 접근은 kw_* 함수 경유.';

alter table public.short_links enable row level security;
-- 직접 접근 정책 없음(의도) = SECURITY DEFINER 함수(kw_shorten/kw_resolve)로만 접근.

-- ── 코드 생성기: 7자리 base62 (62^7 ≈ 3.5e12, 충돌 시 재시도) ──
create or replace function public.kw_gen_code()
returns text
language plpgsql
volatile
set search_path = public, pg_temp
as $$
declare
  alphabet constant text := '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  v_out text := '';
  i int;
begin
  for i in 1..7 loop
    v_out := v_out || substr(alphabet, 1 + floor(random() * 62)::int, 1);
  end loop;
  return v_out;
end;
$$;

-- ── 단축(생성/재사용) ── http(s)만 허용, authenticated 만 실행 ──
create or replace function public.kw_shorten(p_url text)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_url  text := btrim(coalesce(p_url, ''));
  v_code text;
  v_try  int := 0;
begin
  if v_url = '' or length(v_url) > 500 then
    raise exception '잘못된 URL' using errcode = 'P0001';
  end if;
  -- 오픈 리다이렉트 방어 ①: http(s) 스킴만 허용(javascript:, data: 등 차단)
  if v_url !~* '^https?://' then
    raise exception 'http(s) URL 만 허용됩니다' using errcode = 'P0001';
  end if;
  -- 오픈 리다이렉트 방어 ②(Zero-Trust): 클라가 보낸 임의 URL 단축 금지 —
  -- 실제 공구 주문 장부(buses/bus_riders)에 등록된 product_url 만 단축 허용.
  -- (kaiwai.kr/o 가 도메인 신뢰도를 빌려주는 피싱 링크로 악용되는 것을 차단)
  if not exists (
    select 1 from public.buses      where product_url = v_url
    union all
    select 1 from public.bus_riders where product_url = v_url
  ) then
    raise exception '등록되지 않은 주문 URL 입니다' using errcode = 'P0001';
  end if;

  -- 이미 등록된 URL 이면 기존 코드 재사용(멱등)
  select code into v_code from public.short_links where url = v_url;
  if v_code is not null then
    return v_code;
  end if;

  -- 없으면 코드 충돌 회피하며 삽입. url unique 제약으로 동시 삽입도 경합 안전.
  loop
    v_try := v_try + 1;
    v_code := public.kw_gen_code();
    begin
      insert into public.short_links(code, url) values (v_code, v_url);
      return v_code;
    exception
      when unique_violation then
        -- url 충돌(다른 트랜잭션이 먼저 등록) → 그 코드 반환
        select code into v_code from public.short_links where url = v_url;
        if v_code is not null then
          return v_code;
        end if;
        -- code 충돌 → 재시도(최대 5회)
        if v_try >= 5 then
          raise;
        end if;
    end;
  end loop;
end;
$$;
revoke all on function public.kw_shorten(text) from public;
revoke all on function public.kw_shorten(text) from anon;
grant execute on function public.kw_shorten(text) to authenticated;

-- ── 배치 단축 ── (팝업에서 여러 URL 한 번에, 개별 실패는 건너뜀) ──
create or replace function public.kw_shorten_many(p_urls text[])
returns table(url text, code text)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  u text;
begin
  foreach u in array coalesce(p_urls, '{}'::text[]) loop
    begin
      url  := btrim(u);
      code := public.kw_shorten(u);
      return next;
    exception when others then
      continue;   -- 잘못된/실패 URL 은 결과에서 제외(부분 성공 허용)
    end;
  end loop;
end;
$$;
revoke all on function public.kw_shorten_many(text[]) from public;
revoke all on function public.kw_shorten_many(text[]) from anon;
grant execute on function public.kw_shorten_many(text[]) to authenticated;

-- ── 해석(리다이렉트용) + 클릭 카운트 ── Edge Function(service_role) 전용 ──
create or replace function public.kw_resolve(p_code text)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_url text;
begin
  update public.short_links
     set clicks = clicks + 1
   where code = p_code
   returning url into v_url;
  return v_url;   -- 없으면 null
end;
$$;
revoke all on function public.kw_resolve(text) from public;
revoke all on function public.kw_resolve(text) from anon;
revoke all on function public.kw_resolve(text) from authenticated;
grant execute on function public.kw_resolve(text) to service_role;
