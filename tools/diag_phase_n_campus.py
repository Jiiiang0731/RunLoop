#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 N：长江大学武汉校区 ~2.5km 环线真实道路验证（用户提供的 10 个锚点）。

验证内容（全部真实 API，记录调用次数）：
1. 相邻锚点之间的高德真实步行距离/转弯/道路名；
2. 闭环闭合误差与总里程（判断是否 ≈2.5km）；
3. 第 9 锚点（114.029966,30.533269）附近「进运动场豁口」的连通性：
   从该点向四个方向各探测 60m 是否可步行到达；
4. OSM/Overpass 在该区域的道路覆盖度（道路等级统计，用于评估
   「道路网络优先」架构的数据可用性）。

运行：python tools/diag_phase_n_campus.py
"""
import json
import math
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from backend.route_generator.geo import haversine  # noqa: E402
from backend.route_generator.planner import AmapWalkingPlanner  # noqa: E402

ANCHORS = [
    (114.027494, 30.535040),
    (114.027651, 30.532929),
    (114.026649, 30.530919),
    (114.027056, 30.529165),
    (114.030188, 30.527506),
    (114.032443, 30.526696),
    (114.034197, 30.528436),
    (114.031535, 30.530838),
    (114.029966, 30.533269),
    (114.030107, 30.535383),
]

KEY_FILE = os.path.join(ROOT, "config", "amap_key.local")


def load_key() -> str:
    env = os.environ.get("RUNLOOP_AMAP_KEY", "").strip()
    if env:
        return env
    with open(KEY_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    raise RuntimeError("缺少高德 Key")


def offset_point(p, brg_deg, m):
    b = math.radians(brg_deg)
    dlat = math.cos(b) * m / 110574.0
    dlng = math.sin(b) * m / (111320.0 * math.cos(math.radians(p[1])))
    return (p[0] + dlng, p[1] + dlat)


def overpass_roads(bbox):
    """OSM 道路覆盖度统计（只统计，不写库）。"""
    south, west, north, east = bbox
    q = ("[out:json][timeout:60];"
         f'way["highway"]({south},{west},{north},{east});'
         "out tags center;")
    req = urllib.request.Request("https://overpass-api.de/api/interpreter",
                                 data=q.encode("utf-8"),
                                 headers={"User-Agent": "RunLoop-diag/1.0"})
    with urllib.request.urlopen(req, timeout=90) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data.get("elements", [])


def main():
    key = load_key()
    planner = AmapWalkingPlanner(key, sleep=0.15, timeout=20)

    print("=" * 70)
    print("1) 相邻锚点真实步行段（9 段 + 闭合段）")
    print("=" * 70)
    total = 0.0
    legs = []
    seq = ANCHORS + [ANCHORS[0]]
    for i in range(len(seq) - 1):
        a, b = seq[i], seq[i + 1]
        r = planner.plan_walking(a, b)
        if r.error:
            print(f"  leg{i+1}: {a} -> {b} FAILED {r.error}")
            continue
        turns = [s.action for s in r.steps if s.action]
        roads = [s.road for s in r.steps if s.road]
        straight = haversine(a, b)
        total += r.distance_m
        legs.append({"i": i + 1, "from": a, "to": b, "dist": r.distance_m,
                     "straight": straight, "turns": len(turns),
                     "actions": turns, "roads": roads[:5]})
        print(f"  leg{i+1}: {r.distance_m:7.0f}m 直线 {straight:6.0f}m "
              f"比率 {r.distance_m/max(straight,1):.2f} 转弯 {len(turns)} "
              f"actions={turns[:4]} roads={roads[:3]}")
    print(f"\n  环线总里程 = {total:.0f}m（目标 ~2500m，误差 {total-2500:+.0f}m）")
    print(f"  闭合误差（末锚点→首锚点直线）= "
          f"{haversine(ANCHORS[-1], ANCHORS[0]):.0f}m")

    print()
    print("=" * 70)
    print("2) 第 9 锚点附近进运动场豁口：四个方向 60m 可步行探测")
    print("=" * 70)
    p9 = ANCHORS[8]
    print(f"  锚点9 = {p9}")
    probe = {}
    for brg in (0, 90, 180, 270):
        q = offset_point(p9, brg, 60.0)
        r = planner.plan_walking(p9, q)
        ok = r.error is None
        probe[f"brg{brg}"] = {"point": q, "ok": ok,
                              "dist": r.distance_m if ok else None,
                              "err": r.error}
        print(f"  方位{brg:3d}° → {q[0]:.6f},{q[1]:.6f}: "
              f"{'可步行 %.0fm' % r.distance_m if ok else '不可达 ' + str(r.error)}")

    # 若某方向可步行且距离明显大于直线（说明有绕行/入口），输出步骤
    print()
    print("=" * 70)
    print("3) OSM/Overpass 道路覆盖度（校园周边 ~1.3km × 1.1km）")
    print("=" * 70)
    bbox = (30.5255, 114.0245, 30.5365, 114.0355)  # south,west,north,east
    try:
        ways = overpass_roads(bbox)
        from collections import Counter
        cls = Counter((w.get("tags") or {}).get("highway") for w in ways)
        named = sum(1 for w in ways if (w.get("tags") or {}).get("name"))
        lit = sum(1 for w in ways if (w.get("tags") or {}).get("lit") == "yes")
        print(f"  道路 way 数 = {len(ways)}；有名称 = {named}；lit=yes = {lit}")
        for k, v in cls.most_common():
            print(f"    highway={k}: {v}")
        # 采样 6 条主干道路名
        majors = [w for w in ways
                  if (w.get("tags") or {}).get("highway") in
                  ("primary", "secondary", "tertiary", "residential")]
        for w in majors[:6]:
            t = w.get("tags") or {}
            c = w.get("center") or {}
            print(f"    - {t.get('highway')} {t.get('name','(无名)')} "
                  f"@ {c.get('lon')},{c.get('lat')}")
    except Exception as e:  # noqa: BLE001
        print(f"  Overpass 查询失败：{e}")
        ways = []

    out = {"anchors": ANCHORS, "legs": legs, "total_m": total,
           "closure_m": haversine(ANCHORS[-1], ANCHORS[0]),
           "gap_probe": probe, "osm_ways": len(ways),
           "amap_calls": planner.http_calls}
    os.makedirs(os.path.join(ROOT, "docs", "phase_n"), exist_ok=True)
    path = os.path.join(ROOT, "docs", "phase_n", "campus_loop_diag.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print(f"\n高德调用次数 = {planner.http_calls}；结果写入 {path}")


if __name__ == "__main__":
    main()
