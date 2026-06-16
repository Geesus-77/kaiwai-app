# -*- coding: utf-8 -*-
"""
extract_logo_colors.py

logos/ 폴더의 각 로고 이미지에서 배경색(모서리 색상)을 추출하여
index.html 의 각 브랜드 객체에 logoBgColor:"#RRGGBB" 속성을 추가한다.

- 파일명 형식: {id}_{브랜드명}_logo.{ext}  (ext: png/jpg/jpeg/ico)
- 매핑 키: 파일명 앞 숫자 = 브랜드 id, index.html 의 logo URL `.../logo/{id}.ext` 와 매칭
- 색상 추출: 네 모서리 픽셀을 샘플링해 최빈값 채택(동률이면 좌상단 우선)
- 투명 배경(alpha=0): 앱 흰 배경과 동일하게 #FFFFFF 처리
"""
import os
import re
import sys
import subprocess
from collections import Counter

# ---- Pillow 자동 설치 ----
try:
    from PIL import Image
except ImportError:
    print("[setup] Pillow 미설치 → 설치 시도...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "Pillow"])
    from PIL import Image

# Windows 콘솔(cp949) 한글/한자 출력 깨짐 방지
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = os.path.dirname(os.path.abspath(__file__))
LOGO_DIR = os.path.join(ROOT, "logos")
HTML_PATH = os.path.join(ROOT, "index.html")

WHITE = "#FFFFFF"


def rgb_to_hex(rgb):
    return "#{:02X}{:02X}{:02X}".format(rgb[0], rgb[1], rgb[2])


def extract_bg_color(path):
    """이미지 네 모서리에서 배경색을 추출. 투명이면 #FFFFFF."""
    with Image.open(path) as im:
        im = im.convert("RGBA")
        w, h = im.size
        if w == 0 or h == 0:
            return WHITE
        corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
        samples = []
        for (x, y) in corners:
            r, g, b, a = im.getpixel((x, y))
            if a == 0:
                samples.append(WHITE)          # 투명 → 흰색
            else:
                samples.append(rgb_to_hex((r, g, b)))
        # 최빈값(동률이면 좌상단=첫 샘플 우선)
        counter = Counter(samples)
        top_count = counter.most_common(1)[0][1]
        for s in samples:                       # 입력 순서대로 첫 최빈값
            if counter[s] == top_count:
                return s
        return samples[0]


def main():
    if not os.path.isdir(LOGO_DIR):
        print(f"[error] logos 폴더 없음: {LOGO_DIR}")
        sys.exit(1)

    # 1) id -> hex 추출
    id_to_hex = {}
    failures = []
    files = sorted(os.listdir(LOGO_DIR))
    for fname in files:
        m = re.match(r"^(\d+)_", fname)
        if not m:
            continue
        bid = int(m.group(1))
        path = os.path.join(LOGO_DIR, fname)
        try:
            hexcolor = extract_bg_color(path)
            id_to_hex[bid] = hexcolor
            print(f"  id={bid:<3} {hexcolor}  ({fname})")
        except Exception as e:
            failures.append((bid, fname, str(e)))
            print(f"  id={bid:<3} [FAIL] {fname} -> {e}")

    print(f"\n[추출] 성공 {len(id_to_hex)} / 실패 {len(failures)}")

    # 2) index.html 업데이트 (logo URL 뒤에 logoBgColor 삽입, 멱등)
    with open(HTML_PATH, "r", encoding="utf-8") as f:
        html = f.read()

    updated = {"n": 0}
    # logo:"...../logo/{id}.{ext}"  바로 뒤에 이미 logoBgColor 가 없으면 삽입
    pattern = re.compile(
        r'(logo:"[^"]*?/logo/(\d+)\.[A-Za-z0-9]+")(?!\s*,\s*logoBgColor)'
    )

    def repl(mobj):
        full = mobj.group(1)
        bid = int(mobj.group(2))
        if bid not in id_to_hex:
            return full
        updated["n"] += 1
        return f'{full}, logoBgColor:"{id_to_hex[bid]}"'

    new_html = pattern.sub(repl, html)

    if new_html != html:
        with open(HTML_PATH, "w", encoding="utf-8") as f:
            f.write(new_html)

    # 3) 리포트
    print(f"[업데이트] index.html 브랜드 객체에 logoBgColor 삽입: {updated['n']}건")
    if updated["n"] < len(id_to_hex):
        print("[참고] 일부는 이미 logoBgColor 가 있어 건너뛰었거나 매칭 실패했을 수 있음.")
    if failures:
        print("[실패 목록]")
        for bid, fname, err in failures:
            print(f"   id={bid} {fname}: {err}")


if __name__ == "__main__":
    main()
