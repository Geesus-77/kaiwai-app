// ============================================================
// o  —  공구 주문서 카이와이 단축링크 리다이렉트 (+클릭추적)
// ------------------------------------------------------------
//   접속: https://kaiwai.kr/o/<코드>  (vercel.json rewrite 가 이 함수로 프록시)
//   동작: 코드 → 원본 상품 URL 조회(kw_resolve, 클릭수+1) → 302 리다이렉트
//         (+utm_source=kaiwai_coop 카이와이 표식 부착).
//   코드 없음/오류: 카이와이 홈으로 안전 폴백(302).
//   ※ 브라우저 최상위 네비게이션(앱이 apikey 헤더를 못 붙임)이라 verify_jwt=false
//      (config.toml [functions.o]). 내부 조회는 service_role 로 kw_resolve 만 호출.
// ============================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const HOME = "https://kaiwai.kr/";

function withUtm(raw: string): string {
  try {
    const u = new URL(raw);
    u.searchParams.set("utm_source", "kaiwai_coop");
    return u.toString();
  } catch {
    return raw + (raw.includes("?") ? "&" : "?") + "utm_source=kaiwai_coop";
  }
}

Deno.serve(async (req) => {
  // 경로 마지막 세그먼트 = 코드.  /o/<code>
  const path = new URL(req.url).pathname;
  const code = decodeURIComponent(path.split("/").filter(Boolean).pop() || "");
  if (!code || code === "o") {
    return Response.redirect(HOME, 302);
  }
  try {
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data, error } = await sb.rpc("kw_resolve", { p_code: code });
    if (error || !data) {
      return Response.redirect(HOME, 302);
    }
    return Response.redirect(withUtm(String(data)), 302);
  } catch {
    return Response.redirect(HOME, 302);
  }
});
