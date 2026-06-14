import json
import os
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from apify_client import ApifyClient

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

APIFY_TOKEN = os.environ.get("APIFY_TOKEN", "")
IG_COOKIE = os.environ.get("IG_COOKIE", "")
TW_COOKIE = os.environ.get("TW_COOKIE", "")
OUT_PATH = Path(__file__).parent / "calendar_data.json"

ACTOR_IG = "apify/instagram-scraper"
ACTOR_TW = "katerinahronik/twitter-scraper"

BRANDS = [
    {"name": "ROJITA", "ig": "rojita__official", "tw": "ROJITA__jp", "color": "#C41055", "emoji": "🖤"},
    {"name": "Ank Rouge", "ig": "ankrouge_official", "tw": "AnkRouge", "color": "#C41055", "emoji": "🎀"},
    {"name": "LIZ LISA", "ig": "lizlisa_official_japan", "tw": "lizlisaofficial", "color": "#C41055", "emoji": "🌸"},
    {"name": "Secret Honey", "ig": "secrethoney_official", "tw": "SecretHoney_HB", "color": "#C41055", "emoji": "🐰"},
    {"name": "pium", "ig": "", "tw": "pium__official", "color": "#AA7020", "emoji": "🌸"},
    {"name": "Honey Cinnamon", "ig": "", "tw": "honeyc0214", "color": "#C41055", "emoji": "🍯"},
    {"name": "NOEMIE", "ig": "noemie_official_", "tw": "Noemie_shop", "color": "#C41055", "emoji": "🩷"},
    {"name": "MA*RS", "ig": "marsofficialjapan", "tw": "mars_amoebamars", "color": "#C41055", "emoji": "♦️"},
    {"name": "DearMyLove", "ig": "dearmylove_official", "tw": "dearmylove_yume", "color": "#C41055", "emoji": "💕"},
    {"name": "DimMoire", "ig": "", "tw": "_DimMoire_", "color": "#7733BB", "emoji": "🌑"},
]

def apify_instagram(client, ig_handle):
    try:
        run = client.actor(ACTOR_IG).call(run_input={
            "directUrls": [f"https://www.instagram.com/{ig_handle}/"], 
            "resultsLimit": 5,
            "proxy": {"useApifyProxy": True},
            "cookies": [{"name": "sessionid", "value": IG_COOKIE}] if IG_COOKIE else []
        })
        return [item.get("caption") or item.get("text") for item in client.dataset(run["defaultDatasetId"]).iterate_items()]
    except Exception as e:
        print(f"  ⚠️ IG 실패 ({ig_handle}): {e}")
        return []

def apify_twitter(client, x_handle):
    try:
        # 트위터는 cookies 필드에 auth_token을 넘깁니다.
        run = client.actor(ACTOR_TW).call(run_input={
            "handles": [x_handle.lstrip("@")], 
            "tweetsDesired": 5,
            "cookies": [{"name": "auth_token", "value": TW_COOKIE}] if TW_COOKIE else []
        })
        return [item.get("text") for item in client.dataset(run["defaultDatasetId"]).iterate_items() if not item.get("text", "").startswith("RT ")]
    except Exception as e:
        print(f"  ⚠️ TW 실패 (@{x_handle}): {e}")
        return []

def main():
    client = ApifyClient(APIFY_TOKEN) if APIFY_TOKEN else None
    all_events = []
    for brand in BRANDS:
        print(f"▶ 수집 중: {brand['name']}")
        texts = []
        if client:
            if brand["ig"]: texts.extend(apify_instagram(client, brand["ig"]))
            if brand["tw"]: texts.extend(apify_twitter(client, brand["tw"]))
        
        for text in texts:
            if any(trig in text for trig in ["発売", "新作", "drop", "예약", "팝업"]):
                all_events.append({"dt": datetime.now().strftime("%Y-%m-%d"), "br": brand["name"], "d": text[:50]})
        time.sleep(10)
    OUT_PATH.write_text(json.dumps(all_events, ensure_ascii=False, indent=2), encoding="utf-8")
    print("✅ 완료.")

if __name__ == "__main__":
    main()
