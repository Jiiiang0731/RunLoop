#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 N：高德步行 steps.walk_type 真实语义/取值取证（不猜测）。

为什么需要这个脚本：
- walk_type 是评分「非路面路段」的唯一真实来源，但官方文档表只列到 11，
  实际 API 会返回文档未收录的取值（本项目实测到 20）；
- 因此代码只对「已确认」的取值做解释，未知取值必须原样上报为
  unclassified，绝不能默认当成普通道路，也不能拿来推算安全性。

本脚本只调用真实高德步行 API，不写业务数据；结果落
docs/phase_n/walk_type_probe.json，供报告引用。
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from backend.server import load_key  # noqa: E402
from backend.route_generator.planner import AmapWalkingPlanner  # noqa: E402

# 长江大学武汉校区（用户提供的 10 个锚点）
ANCHORS = [
    (114.027494, 30.535040), (114.027651, 30.532929), (114.026649, 30.530919),
    (114.027056, 30.529165), (114.030188, 30.527506), (114.032443, 30.526696),
    (114.034197, 30.528436), (114.031535, 30.530838), (114.029966, 30.533269),
    (114.030107, 30.535383),
]

# 已确认的官方取值（高德 Web 服务步行路径规划 steps.walk_type）。
# 文档只保证到 11；12+ 在真实响应中出现时必须按未知处理。
DOCUMENTED = {
    "0": "普通道路",
    "1": "人行横道",
    "3": "地下通道",
    "4": "过街天桥",
    "5": "地铁通道",
    "6": "公园",
    "7": "广场",
    "8": "扶梯",
    "9": "直梯",
    "10": "索道",
    "11": "空中通道",
}

# 真实城市路口探测点：用于观察 3（地下通道）/4（过街天桥）/5（地铁通道）
# 以及文档未收录的取值。坐标来自高德真实步行结果，不含推测。
PROBES = [
    ("光谷广场-地下通道", (114.39650, 30.50460), (114.39650, 30.50860)),
    ("循礼门-过街天桥", (114.28262, 30.58460), (114.28262, 30.58560)),
    ("光谷广场-地铁通道", (114.39420, 30.50580), (114.40020, 30.50580)),
    ("光谷广场-未知类型", (114.39700, 30.50550), (114.39820, 30.50650)),
]


def _profile(steps, total_m):
    counts, dist = {}, {}
    for st in steps:
        wt = (st.walk_type or "").strip()
        if not wt:
            continue
        counts[wt] = counts.get(wt, 0) + 1
        dist[wt] = round(dist.get(wt, 0.0) + (st.distance_m or 0.0), 1)
    unknown = {k: v for k, v in counts.items() if k not in DOCUMENTED}
    return {
        "counts": counts,
        "distance_m": dist,
        "labels": {k: DOCUMENTED.get(k, "unclassified") for k in counts},
        "unclassified_counts": unknown,
        "total_m": round(total_m, 1),
    }


def _steps_detail(steps):
    out = []
    for st in steps:
        out.append({
            "walk_type": st.walk_type,
            "instruction": st.instruction,
            "road": st.road,
            "action": st.action,
            "distance_m": st.distance_m,
            "label": DOCUMENTED.get((st.walk_type or "").strip(), "unclassified"),
        })
    return out


def main():
    planner = AmapWalkingPlanner(load_key(), sleep=0.15, timeout=25)
    result = {"documented": DOCUMENTED, "groups": []}

    # 1) 校区环线：逐段统计
    seq = ANCHORS + [ANCHORS[0]]
    campus_steps = []
    campus_m = 0.0
    for i in range(len(seq) - 1):
        r = planner.plan_walking(seq[i], seq[i + 1])
        if r.error:
            raise RuntimeError(f"campus leg {i + 1} failed: {r.error}")
        campus_steps.extend(r.steps)
        campus_m += r.distance_m
    result["groups"].append({
        "name": "长江大学武汉校区 10 锚点闭环",
        "profile": _profile(campus_steps, campus_m),
        "steps": _steps_detail(campus_steps),
    })

    # 2) 城市路口：只保留出现非 0 的步骤作为证据
    for name, origin, dest in PROBES:
        r = planner.plan_walking(origin, dest)
        if r.error:
            result["groups"].append({"name": name, "error": r.error})
            continue
        detail = [s for s in _steps_detail(r.steps)
                  if (s["walk_type"] or "").strip() not in ("", "0")]
        result["groups"].append({
            "name": name,
            "origin": origin,
            "destination": dest,
            "distance_m": round(r.distance_m, 1),
            "profile": _profile(r.steps, r.distance_m),
            "non_zero_steps": detail,
        })

    result["api_calls"] = planner.http_calls
    out_dir = os.path.join(ROOT, "docs", "phase_n")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "walk_type_probe.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)

    print(f"api_calls={planner.http_calls} -> {path}")
    for g in result["groups"]:
        p = g.get("profile") or {}
        print(f"{g['name']}: counts={p.get('counts')} "
              f"unknown={p.get('unclassified_counts')}")
    print("documented values:", ",".join(sorted(DOCUMENTED)))


if __name__ == "__main__":
    main()
