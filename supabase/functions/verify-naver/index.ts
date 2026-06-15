// ============================================================
// verify-naver  —  Naver OAuth 콜백 처리 Edge Function
// ------------------------------------------------------------
// 흐름:
//   ① code + CLIENT_SECRET → Naver access_token 교환
//   ② access_token → Naver 프로필 조회
//   ③ 이메일로 기존 유저 탐색
//        - 없음 → createUser(user_metadata)  → handle_new_user() 트리거가 profiles 자동 생성
//        - 있음 → updateUserById(user_metadata) 로 프로필 최신화
//   ④ generateLink(magiclink) 로 token_hash 발급 → 클라이언트가 verifyOtp 로 세션 설정
//
// 필요한 Secrets (supabase secrets set ...):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  (Edge Function 런타임 기본 제공되지만 명시 권장)
//   NAVER_CLIENT_ID, NAVER_CLIENT_SECRET
// ============================================================
import { createClient, type User } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// service_role 키는 Edge Function 내부에서만 사용 (클라이언트 노출 금지)
const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

interface NaverProfile {
  id: string;
  email?: string;
  nickname?: string;
  name?: string;
  profile_image?: string;
}

// ── 이메일로 기존 유저 탐색 (페이지네이션 순회) ──────────────
async function findUserByEmail(email: string): Promise<User | null> {
  let page = 1;
  // perPage 최대치로 순회 (대규모면 별도 인덱스/RPC 권장)
  while (true) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    const hit = data.users.find((u) => u.email?.toLowerCase() === email.toLowerCase());
    if (hit) return hit;
    if (data.users.length < 1000) return null;
    page += 1;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const { code, state } = await req.json();
    if (!code || !state) {
      return json({ error: "code, state 는 필수입니다." }, 400);
    }

    // ① code → Naver access_token 교환
    const tokenUrl =
      "https://nid.naver.com/oauth2.0/token?" +
      new URLSearchParams({
        grant_type: "authorization_code",
        client_id: Deno.env.get("NAVER_CLIENT_ID")!,
        client_secret: Deno.env.get("NAVER_CLIENT_SECRET")!,
        code,
        state,
      });
    const tokenRes = await fetch(tokenUrl, { method: "GET" });
    const tokenData = await tokenRes.json();
    if (!tokenData.access_token) {
      return json({ error: "Naver 토큰 교환 실패", detail: tokenData }, 401);
    }

    // ② access_token → Naver 프로필 조회
    const meRes = await fetch("https://openapi.naver.com/v1/nid/me", {
      headers: { Authorization: `Bearer ${tokenData.access_token}` },
    });
    const meData = await meRes.json();
    if (meData.resultcode !== "00" || !meData.response) {
      return json({ error: "Naver 프로필 조회 실패", detail: meData }, 401);
    }
    const naver: NaverProfile = meData.response;

    // 이메일 미동의 대비: 동의 안 한 경우 noreply 형식 대체 이메일 사용
    const email = naver.email ?? `naver_${naver.id}@users.noreply.kaiwai`;

    // 트리거 폴백 체인에 맞춘 메타데이터 (user_name, full_name, avatar_url)
    const userMetadata = {
      provider: "naver",
      naver_id: naver.id,
      user_name: naver.nickname ?? naver.name,
      nickname: naver.nickname,
      full_name: naver.name ?? naver.nickname,
      name: naver.name,
      avatar_url: naver.profile_image,
      profile_image: naver.profile_image,
      email,
    };

    // ③ 기존 유저 탐색 → 생성 또는 갱신
    const existing = await findUserByEmail(email);
    if (!existing) {
      // 신규: createUser 시점에 user_metadata 전달 → handle_new_user() 트리거가 profiles 생성
      const { error: createErr } = await admin.auth.admin.createUser({
        email,
        email_confirm: true,
        user_metadata: userMetadata,
      });
      if (createErr) {
        return json({ error: "유저 생성 실패", detail: createErr.message }, 500);
      }
    } else {
      // 기존: 프로필 정보 최신화 (트리거는 INSERT 전용이라 무관)
      const { error: updateErr } = await admin.auth.admin.updateUserById(
        existing.id,
        { user_metadata: { ...existing.user_metadata, ...userMetadata } },
      );
      if (updateErr) {
        return json({ error: "유저 갱신 실패", detail: updateErr.message }, 500);
      }
    }

    // ④ 세션용 magiclink 발급 → token_hash 반환
    const { data: linkData, error: linkErr } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    if (linkErr || !linkData) {
      return json({ error: "세션 링크 발급 실패", detail: linkErr?.message }, 500);
    }

    return json({
      email,
      // 클라이언트에서 supabase.auth.verifyOtp({ email, token_hash, type: 'email' }) 호출
      token_hash: linkData.properties?.hashed_token,
    });
  } catch (e) {
    return json({ error: "서버 오류", detail: String(e) }, 500);
  }
});
