# -*- coding: utf-8 -*-
# 신규 브랜드(61~73) 로고를 저용량 webp 로 변환 → Supabase brand-assets/logo/{id}.webp 업로드.
# 투명도(알파) 보존. 배경(bg)은 건드리지 않음. index.html 로고 URL은 이미 .webp 로 설정됨(수정 X).
import os, re, sys, glob, subprocess
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
def log(m):
    try: print(m, flush=True)
    except Exception: print(str(m).encode("ascii","replace").decode(), flush=True)

from PIL import Image, ImageOps
import requests
try: RESAMPLE = Image.Resampling.LANCZOS
except AttributeError: RESAMPLE = Image.LANCZOS

MAX_W = 512
Q = 82
IDS = set(range(61, 74))

def load_env(path=".env.local"):
    e={}
    if os.path.exists(path):
        for ln in open(path, encoding="utf-8"):
            ln=ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k,v=ln.split("=",1); e[k.strip()]=v.strip().strip('"').strip("'")
    return e
env=load_env()
URL=(os.environ.get("NEXT_PUBLIC_SUPABASE_URL") or env.get("NEXT_PUBLIC_SUPABASE_URL")
     or "https://iwrkpwmpfhlyfvutlnuy.supabase.co").rstrip("/")
KEY=os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or env.get("SUPABASE_SERVICE_ROLE_KEY")
if not KEY: log("❌ SERVICE KEY 없음"); sys.exit(1)
BUCKET="brand-assets"; AUTH={"Authorization":f"Bearer {KEY}","apikey":KEY}

def id_of(f):
    m=re.match(r"^(\d+)_", os.path.basename(f)); return int(m.group(1)) if m else None

def to_webp(src, dst):
    with Image.open(src) as im:
        im=ImageOps.exif_transpose(im)
        has_alpha = im.mode in ("RGBA","LA") or (im.mode=="P" and "transparency" in im.info)
        im = im.convert("RGBA") if has_alpha else im.convert("RGB")
        w,h=im.size
        if w>MAX_W:
            im=im.resize((MAX_W, round(h*MAX_W/w)), RESAMPLE)
        im.save(dst, "WEBP", quality=Q, method=6)
    return os.path.getsize(dst)

def upload(local, dst):
    with open(local,"rb") as f: data=f.read()
    r=requests.post(f"{URL}/storage/v1/object/{BUCKET}/{dst}",
        headers={**AUTH,"Content-Type":"image/webp","x-upsert":"true"}, data=data, timeout=60)
    r.raise_for_status()
    return f"{URL}/storage/v1/object/public/{BUCKET}/{dst}"

srcs=[p for p in glob.glob("logos/*") if id_of(p) in IDS and os.path.isfile(p)]
srcs.sort(key=lambda x:id_of(x))
log(f"대상 로고 {len(srcs)}개")
os.makedirs("_logo_tmp", exist_ok=True)
ok=0; tot_s=tot_o=0
for p in srcs:
    bid=id_of(p); dst=f"_logo_tmp/{bid}.webp"
    try:
        ss=os.path.getsize(p); os_=to_webp(p,dst)
        url=upload(dst, f"logo/{bid}.webp")
        tot_s+=ss; tot_o+=os_; ok+=1
        log(f"  ✓ id {bid:<3} {ss//1024:>4}KB → {os_//1024:>3}KB  logo/{bid}.webp")
    except Exception as e:
        log(f"  ✗ id {bid} 실패 - {type(e).__name__}: {e}")
import shutil; shutil.rmtree("_logo_tmp", ignore_errors=True)
log(f"\n완료: {ok}/{len(srcs)} 업로드  ({tot_s//1024}KB → {tot_o//1024}KB)")
