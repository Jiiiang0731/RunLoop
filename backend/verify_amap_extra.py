#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""补充验证：驾车/骑行服务可用性、无路可走时的错误码。"""
import json
import urllib.parse
import urllib.request

BASE = "https://restapi.amap.com"
KEY_FILE = "config/amap_key.local"


def load_key():
    with open(KEY_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "RunLoop-phase1/0.1"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    key = load_key()
    o, d = "121.552563,31.215725", "121.602563,31.215725"  # ~4.8km 东
    # 骑行
    q = urllib.parse.urlencode({"origin": o, "destination": d, "key": key})
    data = get(f"{BASE}/v3/direction/bicycle?{q}")
    print("bicycle:", data.get("status"), data.get("infocode"), data.get("info"))
    # 驾车
    q = urllib.parse.urlencode({"origin": o, "destination": d, "key": key})
    data = get(f"{BASE}/v3/direction/driving?{q}")
    print("driving:", data.get("status"), data.get("infocode"), data.get("info"),
          "dist=", (data.get("route") or {}).get("paths", [{}])[0].get("distance") if data.get("route") else None)
    # 无路可走场景：海中间两点
    q = urllib.parse.urlencode({"origin": "121.90,31.25", "destination": "121.95,31.25", "key": key})
    data = get(f"{BASE}/v3/direction/walking?{q}")
    print("walking(no-road):", data.get("status"), data.get("infocode"), data.get("info"))


if __name__ == "__main__":
    main()
