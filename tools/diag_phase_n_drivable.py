#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 N：校园环线「机动车可通行性」验证（真实高德驾车 v5）。

用途：高德步行 API 不返回道路等级；但**驾车规划能否走通**是一个真实可
获取的代理信号——机动车可通行的路段通常更宽、更连续、更接近主干道。
这里只做代理统计，不声称「安全」。

同时统计每段步行 steps 的 walk_type 分布（0 普通道路/1 人行横道/3 地下
通道/4 过街天桥/8 扶梯/9 直梯/10 索道/11 空中通道）——这是判定「台阶、
地下通道、天桥」等不适合跑步路段的真实数据来源。

运行：python tools/diag_phase_n_drivable.py
"""
import json
import os
import sys
import time
import urllib.request
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from backend.route_generator.planner import AmapWalkingPlanner  # noqa: E402

ANCHORS = [
    (114.027494, 30.535040), (114.027651, 30.532929), (114.026649, 30.530919),
    (114.027056, 30.529165), (114.030188, 30.527506), (114.032443, 30.526696),
    (114.034197, 30.528436), (114.031535, 30.530838), (114.029966, 30.533269),
    (114.030107, 30.535383), (114.027494, 30.535040),
]

# 只写官方已确认取值；2 不是官方地下通道取值（曾误映射，已修正）。
# 真实 API 还可能返回文档未收录取值（如实测 20），一律 unclassified。
WALK_TYPE_NAMES = {
    "0": "普通道路", "1": "人行横道", "3": "地下通道",
    "4": "过街天桥", "5": "地铁通道", "6": "公园", "7": "广场",
    "8": "扶梯", "9": "直梯", "10": "索道", "11": "空中通道",
}


def load_key() -> str:
    env = os.environ.get("RUNLOOP_AMAP_KEY", "").strip()
    if env:
        return env
    with open(os.path.join(ROOT, "config", "amap_key.local"), "r",
              encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    raise RuntimeError("缺少高德 Key")


def drive(key, o, d):
    url = ("https://restapi.amap.com/v5/direction/driving?"
           "origin=%.6f,%.6f&destination=%.6f,%.6f&key=%s"
           % (o[0], o[1], d[0], d[1], key))
    try:
        dd = json.loads(urllib.request.urlopen(
            urllib.request.Request(url), timeout=20).read())
    except Exception as e:  # noqa: BLE001
        return None, "exception:%s" % type(e).__name__
    if str(dd.get("status")) != "1":
        return None, dd.get("info")
    paths = (dd.get("route") or {}).get("paths") or []
    return (float(paths[0]["distance"]) if paths else None), None


def main():
    key = load_key()
    planner = AmapWalkingPlanner(key, sleep=0.12, timeout=20)
    rows = []
    wt = Counter()
    print(" leg | walking | driving | ratio | walk_type 分布")
    print("-" * 68)
    for i in range(len(ANCHORS) - 1):
        a, b = ANCHORS[i], ANCHORS[i + 1]
        w = planner.plan_walking(a, b)
        d, err = drive(key, a, b)
        time.sleep(0.1)
        # 阶段 N：PlanStep 已保留真实 walk_type；未知值单独显示
        types = Counter((st.walk_type or "").strip() for st in w.steps if st.walk_type)
        types_label = {k: WALK_TYPE_NAMES.get(k, "unclassified") for k in types}
        ratio = (d / w.distance_m) if (d and w.distance_m) else None
        rows.append({"leg": i + 1, "walking_m": w.distance_m if not w.error else None,
                     "driving_m": d, "driving_err": err, "ratio": ratio,
                     "walk_steps": len(w.steps),
                     "walk_types": dict(types),
                     "walk_type_labels": types_label,
                     "walk_actions": [s.action for s in w.steps if s.action],
                     "roads": [s.road for s in w.steps if s.road]})
        print("%4d | %7s | %7s | %5s | walk_type=%s actions=%s roads=%s"
              % (i + 1,
                 ("%.0f" % w.distance_m) if not w.error else "FAIL",
                 ("%.0f" % d) if d else "FAIL",
                 ("%.2f" % ratio) if ratio else "-",
                 dict(types),
                 [s.action for s in w.steps if s.action],
                 [s.road for s in w.steps if s.road]))

    ok = sum(1 for r in rows if r["driving_m"])
    print("-" * 68)
    print("驾车可通行段数 = %d/%d（代理指标：可机动车通行 ≈ 更宽更连续；"
          "不代表安全承诺）" % (ok, len(rows)))
    print("步行总里程 = %.0fm" % sum(r["walking_m"] or 0 for r in rows))
    print("高德调用 = %d（walk）+ %d（drive）"
          % (planner.http_calls, len(rows)))

    out = {"anchors": ANCHORS, "legs": rows, "drivable": ok,
           "walk_total_m": sum(r["walking_m"] or 0 for r in rows)}
    path = os.path.join(ROOT, "docs", "phase_n", "campus_drivable.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print("写入", path)


if __name__ == "__main__":
    main()
