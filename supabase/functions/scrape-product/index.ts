// ============================================================
// scrape-product  —  상품 URL 메타 스크래핑 (서버사이드)
// ------------------------------------------------------------
// 기존: 클라가 무료 프록시(allorigins)로 긁음 → 프록시 522 다운 + 클라 CORS 로 UA 변경 불가.
// 개선: 서버에서 브라우저 User-Agent 로 직접 fetch(차단 회피) → og 메타 + JSON-LD 파싱.
//   · 깨진 og:image(렌즈랄라의 스프레드시트 수식 누출 등)는 거부하고 JSON-LD image 로 폴백.
//   · 가격은 product:price meta → JSON-LD "price" → og:description 의 ¥/円 순으로 견고 추출.
//   · 어떤 실패든 throw 하지 않고 { ok:false } 반환 → 프론트가 우아한 폴백 처리.
// 호출: sb.functions.invoke("scrape-product", { body: { url } })
// ============================================================
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

function decode(s: string): string {
  return String(s || "")
    .replace(/&quot;/g, '"').replace(/&#34;/g, '"')
    .replace(/&#39;/g, "'").replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").trim();
}
function metaContent(html: string, prop: string): string {
  // property 또는 name=prop 인 meta 의 content
  const re = new RegExp(`<meta[^>]+(?:property|name)=["']${prop}["'][^>]*>`, "i");
  const tag = html.match(re);
  if (!tag) return "";
  const c = tag[0].match(/content=["']([\s\S]*?)["']/i);
  return c ? decode(c[1]) : "";
}
const isHttpImg = (u: string) => /^https?:\/\//i.test(u) && !/^=/.test(u);
function toInt(s: string): number {
  const n = parseInt(String(s || "").replace(/[,\.\s]/g, ""), 10);
  return isNaN(n) || n <= 0 ? 0 : n;
}

// JSON-LD( application/ld+json ) 블록들에서 키 추출 (Product 우선)
function fromJsonLd(html: string, key: "image" | "price"): string {
  const blocks = html.match(/<script[^>]+application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi) || [];
  for (const b of blocks) {
    const body = b.replace(/<\/?script[^>]*>/gi, "");
    if (key === "image") {
      const m = body.match(/"image"\s*:\s*"(https?:\/\/[^"]+)"/i)
        || body.match(/"image"\s*:\s*\[\s*"(https?:\/\/[^"]+)"/i);
      if (m) return m[1];
    } else {
      const m = body.match(/"price"\s*:\s*"?([0-9][0-9,\.]*)"?/i);
      if (m) return m[1];
    }
  }
  return "";
}

function parse(html: string) {
  // 제목
  const title = metaContent(html, "og:title") || metaContent(html, "twitter:title")
    || (html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ? decode(html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)![1]) : "");
  // 이미지: og:image(유효 http 만) → JSON-LD image → twitter:image
  let imageUrl = "";
  const ogImg = metaContent(html, "og:image");
  if (isHttpImg(ogImg)) imageUrl = ogImg;
  if (!imageUrl) { const j = fromJsonLd(html, "image"); if (isHttpImg(j)) imageUrl = j; }
  if (!imageUrl) { const t = metaContent(html, "twitter:image"); if (isHttpImg(t)) imageUrl = t; }
  // 가격: meta → JSON-LD → og:description/본문의 ¥/円
  let price = toInt(metaContent(html, "product:price:amount") || metaContent(html, "og:price:amount"));
  if (!price) price = toInt(fromJsonLd(html, "price"));
  if (!price) {
    const src = (metaContent(html, "og:description") || "") + " " + html.slice(0, 20000);
    const m = src.match(/(?:[¥￥]|円|JPY)\s*([0-9][0-9,\.]{1,})|([0-9][0-9,\.]{1,})\s*(?:円|JPY)/i);
    if (m) price = toInt(m[1] || m[2]);
  }
  return { title, imageUrl, price };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, reason: "method" }, 405);
  try {
    const { url } = await req.json().catch(() => ({}));
    const target = String(url || "").trim();
    if (!/^https?:\/\/[^\s.]+\.[^\s]+$/i.test(target)) return json({ ok: false, reason: "invalid-url" }, 200);

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 12000);
    let html = "";
    try {
      const res = await fetch(target, {
        redirect: "follow",
        signal: ctrl.signal,
        headers: {
          "User-Agent": UA,
          "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          "Accept-Language": "ko,ja;q=0.9,en;q=0.8",
        },
      });
      if (!res.ok) return json({ ok: false, reason: "http-" + res.status }, 200);
      html = await res.text();
    } finally { clearTimeout(timer); }

    const { title, imageUrl, price } = parse(html);
    const ok = !!(title || imageUrl || price);
    return json({ ok, title, imageUrl, price, reason: ok ? "" : "no-meta" }, 200);
  } catch (e) {
    return json({ ok: false, reason: "fetch-failed", detail: String(e) }, 200);
  }
});
