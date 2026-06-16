# -*- coding: utf-8 -*-
# ============================================================
# upload_to_storage.py
#   logos/ , backgrounds/ 이미지를 Supabase Storage(public 버킷 'brand-assets')에
#   업로드하고, index.html 의 브랜드 bgImg 를 업로드된 배경 이미지 공개 URL로 연결.
#
#   업로드 경로(깨끗한 이름으로 통일 — URL 인코딩 이슈 방지):
#     backgrounds/{id}_*.jpg  ->  bg/{id}.jpg
#     logos/{id}_*.{ext}      ->  logo/{id}.{ext}
#
#   ⚠️ SUPABASE_SERVICE_ROLE_KEY 는 시크릿 — 코드/깃에 넣지 말 것.
#      환경변수 또는 .env.local 에서만 읽음.
#
#   실행 전 키 설정(둘 중 하나):
#     (A) 환경변수:  $env:SUPABASE_SERVICE_ROLE_KEY="..."   (PowerShell)
#     (B) .env.local 파일에  SUPABASE_SERVICE_ROLE_KEY=...  한 줄 추가
# ============================================================
import os
import re
import sys
import glob
import json
import subprocess

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def log(m):
    try: print(m, flush=True)
    except Exception: print(str(m).encode("ascii","replace").decode("ascii"), flush=True)

def ensure(pkg, imp=None):
    import importlib.util
    if importlib.util.find_spec(imp or pkg) is None:
        subprocess.run([sys.executable, "-m", "pip", "install", pkg], check=True)
ensure("requests")
import requests

# ── 설정값 로드 ─────────────────────────────────────────────
def load_env_file(path=".env.local"):
    env = {}
    if os.path.exists(path):
        for line in open(path, "r", encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env

fileenv = load_env_file()
SUPABASE_URL = (os.environ.get("NEXT_PUBLIC_SUPABASE_URL")
                or fileenv.get("NEXT_PUBLIC_SUPABASE_URL")
                or "https://iwrkpwmpfhlyfvutlnuy.supabase.co").rstrip("/")
SERVICE_KEY = (os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
               or fileenv.get("SUPABASE_SERVICE_ROLE_KEY"))

if not SERVICE_KEY:
    log("❌ SUPABASE_SERVICE_ROLE_KEY 가 없습니다.")
    log("   PowerShell:  $env:SUPABASE_SERVICE_ROLE_KEY=\"<service_role 키>\"  설정 후 다시 실행")
    log("   또는 .env.local 에  SUPABASE_SERVICE_ROLE_KEY=<키>  추가")
    sys.exit(1)

BUCKET = "brand-assets"
AUTH = {"Authorization": f"Bearer {SERVICE_KEY}", "apikey": SERVICE_KEY}
MIME = {"png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg",
        "ico":"image/x-icon","webp":"image/webp","gif":"image/gif","svg":"image/svg+xml"}

# ── 1. public 버킷 생성 (있으면 통과) ───────────────────────
def ensure_bucket():
    r = requests.post(f"{SUPABASE_URL}/storage/v1/bucket",
                      headers={**AUTH, "Content-Type": "application/json"},
                      data=json.dumps({"id": BUCKET, "name": BUCKET, "public": True}),
                      timeout=15)
    if r.status_code in (200, 201):
        log(f"버킷 '{BUCKET}' 생성됨 (public).")
    elif r.status_code == 409 or "already exists" in r.text.lower() or "duplicate" in r.text.lower():
        log(f"버킷 '{BUCKET}' 이미 존재 — 사용.")
    else:
        log(f"⚠️ 버킷 생성 응답 {r.status_code}: {r.text[:200]}")

# ── 2. 파일 업로드 (x-upsert: 덮어쓰기) ─────────────────────
def upload(local_path, dest_path):
    ext = dest_path.rsplit(".", 1)[-1].lower()
    with open(local_path, "rb") as f:
        data = f.read()
    r = requests.post(f"{SUPABASE_URL}/storage/v1/object/{BUCKET}/{dest_path}",
                      headers={**AUTH, "Content-Type": MIME.get(ext, "application/octet-stream"),
                               "x-upsert": "true"},
                      data=data, timeout=30)
    r.raise_for_status()
    return f"{SUPABASE_URL}/storage/v1/object/public/{BUCKET}/{dest_path}"

def id_of(fname):
    m = re.match(r"^(\d+)_", os.path.basename(fname))
    return int(m.group(1)) if m else None

# ── 실행 ────────────────────────────────────────────────────
ensure_bucket()

bg_urls, logo_urls = {}, {}
log("\n[배경 업로드]")
for p in sorted(glob.glob("backgrounds/*"), key=lambda x: id_of(x) or 0):
    bid = id_of(p)
    if bid is None: continue
    try:
        bg_urls[bid] = upload(p, f"bg/{bid}.jpg")
        log(f"  ✓ bg/{bid}.jpg")
    except Exception as e:
        log(f"  ✗ id {bid} 배경 - {type(e).__name__}: {e}")

log("\n[로고 업로드]")
for p in sorted(glob.glob("logos/*"), key=lambda x: id_of(x) or 0):
    bid = id_of(p)
    if bid is None: continue
    ext = p.rsplit(".", 1)[-1].lower()
    try:
        logo_urls[bid] = upload(p, f"logo/{bid}.{ext}")
        log(f"  ✓ logo/{bid}.{ext}")
    except Exception as e:
        log(f"  ✗ id {bid} 로고 - {type(e).__name__}: {e}")

# ── 3. index.html 의 브랜드 bgImg 연결 (브랜드 객체 한정) ────
content = open("index.html", "r", encoding="utf-8").read()
starts = [m.start() for m in re.finditer(r'\{id:\s*\d+', content)]
starts.append(len(content))
out, patched = [], 0
prev = 0
for i in range(len(starts) - 1):
    seg = content[starts[i]:starts[i+1]]
    bid = int(re.search(r'id:\s*(\d+)', seg).group(1))
    if bid in bg_urls:
        new_seg, n = re.subn(r'bgImg:"[^"]*"', f'bgImg:"{bg_urls[bid]}"', seg, count=1)
        if n:
            patched += 1
            seg = new_seg
    out.append(seg)

# 재조립: 첫 브랜드 이전(헤더/CM 카테고리 등)은 원본 그대로 유지
new_content = content[:starts[0]] + "".join(out)
open("index.html", "w", encoding="utf-8").write(new_content)

log("\n" + "="*46)
log(f"📊 업로드: 배경 {len(bg_urls)} / 로고 {len(logo_urls)}")
log(f"   index.html bgImg 연결: {patched}개")
log("="*46)
log(f"공개 URL 예시: {next(iter(bg_urls.values())) if bg_urls else '(없음)'}")
