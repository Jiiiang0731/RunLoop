#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
高德地图 Web 服务 API 最小验证脚本（阶段 1）。

目的：不依赖任何假设，真实调用高德接口，确认以下能力与返回字段：
  1) 地理编码（地址 -> GCJ-02 经纬度）
  2) 步行路径规划（两点 -> 距离/时长/分段/折线 polyline 格式）
  3) 骑行路径规划（对比，供"减少重复、贴近道路"的备选）
  4) 坐标转换（GPS/WGS-84 -> GCJ-02）
  5) 配额/限流错误码（infocode）与请求耗时

密钥从 config/amap_key.local 读取，不入库、不硬编码。
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

BASE = "https://restapi.amap.com"
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY_FILE = os.path.join(HERE, "config", "amap_key.local")


def load_key() -> str:
    with open(KEY_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    raise RuntimeError("no key found in " + KEY_FILE)


def http_get_json(url: str, timeout: int = 25):
    req = urllib.request.Request(url, headers={"User-Agent": "RunLoop-phase1/0.1"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
    dt = time.time() - t0
    return json.loads(raw), dt


def show(name: str, data: dict, dt: float):
    status = data.get("status")
    info = data.get("info")
    code = data.get("infocode")
    print(f"[{name}] status={status} infocode={code} info={info} 耗时={dt:.2f}s")


def main():
    key = load_key()
    print("Key 加载成功，尾号 ...%s" % key[-4:])
    print("=" * 70)

    # 1) 地理编码：地址 -> 坐标（确认返回 GCJ-02）
    q = urllib.parse.urlencode({"address": "上海世纪公园", "city": "上海", "key": key})
    data, dt = http_get_json(f"{BASE}/v3/geocode/geo?{q}")
    show("地理编码", data, dt)
    if data.get("geocodes"):
        g = data["geocodes"][0]
        print("    location=%s  formatted=%s  level=%s" %
              (g.get("location"), g.get("formatted_address"), g.get("level")))

    # 2) 步行路径规划：天安门 -> 东侧约 1.7km（GCJ-02）
    origin = "116.397428,39.909230"
    dest = "116.417428,39.909230"
    q = urllib.parse.urlencode({"origin": origin, "destination": dest, "key": key})
    data, dt = http_get_json(f"{BASE}/v3/direction/walking?{q}")
    show("步行路径规划", data, dt)
    if data.get("route") and data["route"].get("paths"):
        p = data["route"]["paths"][0]
        print("    distance(m)=%s  duration(s)=%s  steps=%d" %
              (p.get("distance"), p.get("duration"), len(p.get("steps", []))))
        print("    path 顶层字段: %s" % sorted(p.keys()))
        if p.get("steps"):
            s0 = p["steps"][0]
            print("    step 字段: %s" % sorted(s0.keys()))
            pl = s0.get("polyline", "")
            print("    step[0].polyline 前 160 字符: %s" % pl[:160])
            print("    step[0] road=%s instruction=%s distance=%s duration=%s" %
                  (s0.get("road"), s0.get("instruction"), s0.get("distance"), s0.get("duration")))
    else:
        print("    无路线，完整返回(前800字符):", json.dumps(data, ensure_ascii=False)[:800])

    # 3) 骑行路径规划（同一对点，对比距离/道路类型）
    q = urllib.parse.urlencode({"origin": origin, "destination": dest, "key": key})
    data, dt = http_get_json(f"{BASE}/v3/direction/bicycle?{q}")
    show("骑行路径规划", data, dt)
    if data.get("data") and data["data"].get("paths"):
        p = data["data"]["paths"][0]
        print("    distance(m)=%s  duration(s)=%s  steps=%d" %
              (p.get("distance"), p.get("duration"), len(p.get("steps", []))))

    # 4) 坐标转换：WGS-84(GPS) -> GCJ-02
    gps = "116.391275,39.907500"
    q = urllib.parse.urlencode({"locations": gps, "coordsys": "gps", "key": key})
    data, dt = http_get_json(f"{BASE}/v3/assistant/coordinate/convert?{q}")
    show("坐标转换 GPS->GCJ02", data, dt)
    print("    输入 %s -> 输出 %s" % (gps, data.get("locations")))

    print("=" * 70)
    print("验证完成。")


if __name__ == "__main__":
    main()
