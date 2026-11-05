# 阶段 N 报告：锚点闭环接入、walk_type 取证与真实道路回归

日期：2026-11-05
范围：只做本阶段要求的锚点闭环接入、质量口径拆分、真实 API 回归与双 APK 重建；
未引入 OSM、未配置代理、未扩展 App 新页面。

## 1. 结论先行

- `anchor_loop.py` 已接入 `POST /api/route/generate`：请求可带 4~15 个有序
  参考锚点，服务端逐段真实步行规划、按目标裁剪、强制闭合后返回。
- 长江大学武汉校区 10 锚点、目标 2500m 的真实结果：
  **2593m（+93m，+3.7%）、闭合缺口 0.59m、7 次转弯、转弯密度 2.68 次/km**；
  为达到 2.5km 去掉了 3 个内部锚点（第 4/6/7 个），保留首锚点作为起终点，
  **没有切割折线**。
- 回归 1/2.5/5/15/50km 全部 `within_tolerance=true`；闭合误差 0~0.59m。
  50km 为 49718.7m（−281.3m），585 次高德调用、156.6s。
- 道路安全、车流暴露在本轮**没有真实照明/实时车流/道路宽度数据**，
  API 明确返回 `available=false, score=null`；没有合成任何“安全分”。
- 机动车可通行率只作为道路等级/连通性代理，API 标为
  `motor_vehicle_access`，`not_for=["safety","traffic_exposure"]`。
- 双 APK 已重建；debug 与 release 都注入
  `TAILNET_BASE_URL=https://your-device.your-tailnet.ts.net`，与当前后端
  （PID 36208，v0.6，Tailscale Serve → 127.0.0.1:8000）一致。

## 2. OSM 决策（按用户拍板）

- **不配置代理、不引入 OSM**；本轮所有道路/步骤数据来自已在高德 Key 下验证过的
  AMap Web 服务。
- 不新增 Overpass/OSM 依赖、不新增外部数据基础设施。
- 现有代码中没有任何 `lit`、`surface`、`highway` 字段的读取或推断；
  也没有声称“已验证照明/车流/路宽”。

## 3. walk_type 实际语义与取值（先取证，再评分）

### 3.1 官方文档

高德步行路径规划 `steps.walk_type` 的官方字段表：
<https://lbs.amap.com/api/webservice/guide/api/direction>

官方确认取值（截至取证时文档列到 11）：

| 值 | 含义 |
|---|---|
| 0 | 普通道路 |
| 1 | 人行横道 |
| 3 | 地下通道 |
| 4 | 过街天桥 |
| 5 | 地铁通道 |
| 6 | 公园 |
| 7 | 广场 |
| 8 | 扶梯 |
| 9 | 直梯 |
| 10 | 索道 |
| 11 | 空中通道 |

注意：**2 不是官方“地下通道”取值**。此前 `tools/diag_phase_n_drivable.py`
把 2 误映射成地下通道，本轮已修正；未知值不再猜测。

### 3.2 真实 API 取证（`tools/diag_walk_type.py`）

结果落 `docs/phase_n/walk_type_probe.json`，共 19 次真实调用：

| 探测组 | 实际取值 | 说明 |
|---|---|---|
| 长江大学 10 锚点闭环 | `0` × 20 步，2987m | 校园环线全部为普通道路 |
| 光谷广场（地下通道） | `0` + `3` | 实测到地下通道 |
| 循礼门（过街天桥） | `0` + `4` | 实测到过街天桥 |
| 光谷广场（地铁通道） | `0` + `5` | 实测到地铁通道 |
| 光谷广场（另一路口） | `0` + **`20`** | **文档未收录值**，只上报 unclassified |

结论：
- 评分只解释已确认的 0/1/3/4/5/6/7/8/9/10/11；
- `3/4/5/8/9/10/11` 仅作为“非地面/需上下设施”的结构事实统计，
  不据此推断安全；
- 20 等未收录取值原样进入 `unclassified_counts`，不参与比例、不猜测含义。

## 4. 质量口径：安全、连续性、车流暴露分开

新增 `backend/route_generator/quality.py`。每个候选新增 `quality` 块：

| 字段 | 是否有分 | 依据 | 说明 |
|---|---|---|---|
| `road_continuity` | 有 0~100 | 真实步行 steps 的闭合/转弯/长直行/重复 | 只叫“连续性”，不是安全 |
| `road_safety` | **无** | 缺少照明/实时车流/路宽 | `available=false, score=null`，写明原因 |
| `traffic_exposure` | **无** | 缺少实时车流/车速/路宽 | `available=false, score=null`；不从驾车率推断 |
| `motor_vehicle_access` | 无（比率） | 真实高德驾车 v5，逐段 | 仅辅助道路等级/连通性；`not_for=safety/traffic_exposure` |
| `walk_type` | 无（事实） | 真实 steps.walk_type | 计数/距离/未收录值 |
| `data_gaps` | — | — | `lighting`、`realtime_traffic`、`road_width` |

`verify_drivable=true` 时才调用驾车核验（默认关闭，避免每次生成多耗调用）；
本轮 2.5km 锚点路线实测：7/7 段可驾车通行，驾车/步行里程比 **1.487**。
该比率 **没有** 被写进安全分或车流分。

## 5. anchor_loop 接入与裁剪规则

### 5.1 API

`POST /api/route/generate` 新增可选字段：

```json
{
  "origin": {"lng": 114.027494, "lat": 30.535040},
  "target_m": 2500,
  "tol_m": 500,
  "anchors": [[lng, lat], "..."],
  "verify_drivable": true
}
```

- `anchors`：4~15 个有序点，首点 = 起点；不传则完全走原骨架路径；
- 响应新增 `route_mode`（`anchor`/`skeleton`）、`candidate.quality`、
  `candidate.anchor`；
- 健康检查新增 `features={"anchor_loop":true,"verify_drivable":true}`、
  `pid`、`started_at`，用于确认进程确实是新代码，而不只看 `version=0.6`。

### 5.2 闭合铁律

- 裁剪 = 去掉 1~3 个**内部**锚点后，对剩余锚点重新逐段真实规划并闭合回首锚点；
- 首锚点永不丢；**不截断 polyline**；
- 每个候选计算首尾折线距离，超过 50m 直接判 `error` 并丢弃；
- 全部候选都不闭合时返回错误，不用“切断闭环”凑距离。

单测 `tests/test_anchor_loop.py` 覆盖：
- 裁剪后仍闭合、距离等于各段之和；
- 首锚点不会被 drop；
- 闭合段被故意甩开 120m 时，候选被拒绝而不是修补/截断；
- 单测全部离线，不触真实 API。

### 5.3 2.5km 实测裁剪过程

| 候选 | 距离 | 误差 | 闭合 | 转弯 | 密度 | 重复 | 连续性分 | 综合分 |
|---|---|---|---|---|---|---|---|---|
| 不裁剪（10 锚点） | 2987.0 | +487.0 | 0.59 | 9 | 2.99 | 34.5% | — | 20.5 |
| 去 1 个（第 10） | 2777.0 | +277.0 | 0.59 | 9 | 3.22 | 32.9% | — | 21.1 |
| **去 3 个（4/6/7）** | **2593.0** | **+93.0** | **0.59** | **7** | **2.68** | **26.1%** | **63.8** | **48.0** |

最终返回 7 个锚点参与（`anchors_used=7`），`drops=[3,5,6]`（0-based）。
共尝试 130 个闭合候选；因共享分段缓存，步行+驾车 HTTP 总调用仅 56 次
（其中驾车核验 7 次）、14.0s。

## 6. 真实 API 回归（1/2.5/5/15/50km）

工具：`tools/regress_phase_n_anchor.py`，走真实 `POST /api/route/generate`，
不是直接调库；结果 `docs/phase_n/regression_anchor_v06.json`。
seeds 使用 App 默认 `[1,2,3]`，`max_candidates=1`，`max_api_calls=800`。

口径说明：这 10 个锚点本身围成约 3km 的固定校园环线，只适合 2.5km 目标；
1/5/15/50km 没有可用的同尺度锚点，走的是 App 默认的通用骨架路径。
因此本表同时覆盖「锚点模式（2.5km）」与「骨架模式（其余距离）」，不是
用 10 个锚点硬凑所有距离。

| 案例 | 目标 | 实际 | 误差 | 达标 | 闭合 | 转弯 | 密度 | 重复 | 连续性 | 调用 | 耗时 |
|---|---:|---:|---:|:---:|---:|---:|---:|---:|---:|---:|---:|
| 1km 骨架 | 1000 | 1076.0 | +76.0 | ✅ | 0.0 | 10 | 9.25 | 51.5% | 41.3 | 113 | 29.3s |
| 1km 骨架 seed6（曾 586m） | 1000 | 1076.0 | +76.0 | ✅ | 0.0 | 10 | 9.25 | 51.5% | 41.3 | 117 | 30.4s |
| 2.5km 骨架（对照） | 2500 | 2565.9 | +65.9 | ✅ | 0.59 | 19 | 7.36 | 45.5% | 45.9 | 143 | 36.8s |
| **2.5km 锚点** | 2500 | **2593.0** | +93.0 | ✅ | 0.59 | **7** | **2.68** | **26.1%** | **63.8** | 56 | 14.0s |
| 5km 骨架 | 5000 | 4901.3 | −98.7 | ✅ | 0.59 | 26 | 5.26 | 26.7% | 60.8 | 77 | 20.6s |
| 15km 骨架 | 15000 | 15074.7 | +74.7 | ✅ | 0.59 | 29 | 1.92 | 39.8% | 63.1 | 135 | 34.9s |
| 50km 骨架 | 50000 | 49718.7 | −281.3 | ✅ | 0.59 | 68 | 1.36 | 34.3% | 74.3 | 585 | 156.6s |

- 短距离：1km 最差案例从 586m 提升到 1076m（仍在 ±500m 内）；
  2.5km 锚点路线比骨架少 12 次转弯、重复率低 19.4 个百分点，距离仍 +3.7%。
- 长距离：5/15/50km 全部达标；50km 依赖“超差候选不提前停止、继续试 seed3”
  （见 §7），最终 −281m。
- 全部案例 `road_safety.available=false`、`traffic_exposure.available=false`，
  自动化诚实性检查 0 违规。

### 6.1 50km 为什么从 +1387m 变成 −281m

旧行为：`max_candidates=1` 时，seed1 只要**能生成**就停，哪怕
`|err|=1387m > 500m`。50km seed1 实测 51387m（超差），因此旧请求直接返回超差路线。

本轮最小修正：**只有距离达标的候选才计入 `max_candidates`**；未达标时继续试
seed2/3，最后按“达标优先、同档比评分”排序，再按 `max_candidates` 截断。
50km 实测：

| seed | 距离 | 误差 | 是否达标 |
|---|---:|---:|---:|
| 1 | 51387.0 | +1387.0 | ❌ |
| 2 | 50519.0 | +519.0 | ❌ |
| 3 | 49718.7 | −281.3 | ✅ |

代价：50km 一次请求 585 次调用、156.6s，仍在 800 调用预算与客户端 240s 超时内。

## 7. 新旧代码 A/B（证明骨架路径未被本轮改动影响）

用 `git worktree` 检出改动前 HEAD `d645c2b`，在 8001 端口用同一 Key、同一起点、
同一 seed1 请求对照；结果 `docs/phase_n/ab_old_head_5_15_50.json`。

| 目标 | 旧 HEAD 距离/误差/转弯 | 新工作树距离/误差/转弯 | 结论 |
|---|---|---|---|
| 5km | 4901.3 / −98.7 / 26 | 4901.3 / −98.7 / 26 | 完全一致 |
| 15km | 15074.7 / +74.7 / 29 | 15074.7 / +74.7 / 29 | 完全一致 |
| 50km seed1 | 51387.0 / +1387.0 / 80 | 51387.0 / +1387.0 / 80 | 完全一致（既有超差，不是本轮引入） |

因此：anchor/quality 接入没有改变骨架算法；50km 的改善来自 §6.1 的
“不提前接受超差候选”，不是通过改骨架参数硬凑。

## 8. 服务地址与 APK

### 8.1 当前服务链

- 后端：`waitress` 监听 `127.0.0.1:8000`，PID 36208，`version=0.6`，
  `features.anchor_loop=true`，`started_at=2026-11-05T17:45:20+0800`；
- Tailscale Serve：`https://your-device.your-tailnet.ts.net → http://127.0.0.1:8000`；
- 实测两个入口均 200 且返回同一 PID：
  - `http://127.0.0.1:8000/api/health`
  - `https://your-device.your-tailnet.ts.net/api/health`
- **注意**：`http://192.168.1.100:8000` 在“后端只监听回环”的生产形态下不可达；
  这是设计使然（安全边界），不是 404。本机 debug APK 因此也改用 Tailnet 地址，
  不再依赖校园网 LAN 直连。

### 8.2 双 APK

两次构建均注入 `TAILNET_BASE_URL=https://your-device.your-tailnet.ts.net` 与高德
Android Key；release 与 debug 的运行时地址一致：

| 产物 | 大小 | SHA-256 | 签名 |
|---|---:|---|---|
| `app-debug.apk` | 198,527,838 B | `3FD641F85B4EE15B8A8AB1E86FC57D18378E0D311D4E410DA25F4FAD382B9F46` | Android Debug |
| `app-release.apk` | 78,712,968 B | `BBD663A759970EAF7BBABEBE455E98A66DD65EACD76A2B3344002E4EE3CBF47B` | `CN=RunLoop` 既有 keystore |

- `apksigner verify`：debug/release 均 exit 0；
- 解包核对：
  - release `libapp.so` 含 `your-device.your-tailnet.ts.net`，不含 `192.168.1.100`；
  - debug `kernel_blob.bin` 含 Tailnet 地址；LAN 常量仍在源码中作为
    “显式 0.0.0.0 调试”的兜底，但 debug 构建已注入 Tailnet，
    `AppConfig.routeApiBaseUrl` 在 debug 下优先返回有效 Tailnet 地址，不使用 LAN。
  - 另用临时 Flutter 测试（`--dart-define=TAILNET_BASE_URL=...`，断言
    `AppConfig.routeApiBaseUrl == https://your-device.your-tailnet.ts.net`）在 debug
    模式实测通过；临时测试文件已删除，未入库。
- 高德 Web 服务 Key 不在 APK 内；APK 内只有 Android 地图 Key（绑包名/SHA1）。

## 9. 自动化测试

| 项 | 结果 |
|---|---|
| Python 全量 `pytest` | **172 passed**（含 anchor_loop 7 项、quality 5 项、server anchor 契约 3 项等） |
| Flutter `flutter test` | **185 passed** |
| `flutter analyze lib test` | 0 error / 0 warning；1 条既有 info（`route_api_service.dart:131` 的 null-aware 风格提示，本轮未改该文件） |
| `flutter analyze`（全仓） | 609 条，全部来自 `packages/amap_flutter_*` 自带 example，属既有第三方包问题；不是本次改动 |
| 双 APK 构建 | debug/release 均成功；签名校验通过 |

自动化测试全部离线，不触真实高德；真实 API 证据见 §3/§6/§7。

## 10. 真实 API 测试与待真机测试的边界

**已在真实 API 验证：**
- 19 次 walk_type 取证（含未知值 20）；
- 7 个距离档的真实 `/api/route/generate`（含 anchors 与驾车核验）；
- 新旧代码 5/15/50km 单种子 A/B；
- 两个服务入口（回环与 Tailnet HTTPS）健康检查。

**仍待真机验证（不能在开发机代替）：**
1. 安装 `app-release.apk` / `app-debug.apk`，手机连 Tailnet 后实际生成路线；
2. 2.5km 长江大学锚点路线目前只通过 API 参数提供，**App 尚无“自定义锚点”
   UI**，无法在手机上直接选这条路线；需要后续单独做自定义路线页面；
3. GPS 真实轨迹、偏航重规划、锁屏语音、TTS、地图视觉、电池/前台服务；
4. 50km 请求在手机上约 157s，需实测 Tailnet 弱网下是否触发客户端 240s 超时；
5. 高德驾车核验默认关闭，手机端不会自动发起；如未来开放，需要确认配额与等待体验。

## 11. 修改文件

后端：
- `backend/route_generator/quality.py`（新增）
- `backend/route_generator/anchor_loop.py`
- `backend/route_generator/generator.py`
- `backend/route_generator/nav_metrics.py`
- `backend/route_generator/planner.py`（新增 `plan_driving`）
- `backend/route_generator/types.py`
- `backend/route_generator/__init__.py`
- `backend/server.py`

测试：
- `tests/test_anchor_loop.py`
- `tests/test_quality.py`（新增）
- `tests/test_nav_metrics.py`
- `tests/test_generator.py`
- `tests/test_server_api.py`

工具/证据：
- `tools/diag_walk_type.py`（新增）
- `tools/regress_phase_n_anchor.py`（新增）
- `tools/diag_phase_n_drivable.py`（修正 walk_type 映射）
- `docs/phase_n/walk_type_probe.json`
- `docs/phase_n/regression_anchor_v06.json`
- `docs/phase_n/ab_old_head_5_15_50.json`
- `docs/phase_n_report.md`（本文件）

未改 `lib/` 业务代码；未引入 OSM/Overpass；未新增第三方依赖。

## 12. 未解决 / 下一步

1. App 自定义锚点 UI（本轮未做，避免扩大范围）；在此之前 2.5km 锚点路线
   只能由 API 调用方使用。
2. 道路安全/车流暴露仍无真实数据源；在拿到照明、实时车流、路宽数据前，
   保持 `available=false`，不合成分数。
3. 50km 的 156.6s 与 585 次调用需要真机弱网验证；若超时，需把“试到第 3 个
   seed”做成可配置/可提示的渐进策略，而不是默认硬等。
4. `flutter analyze` 全仓仍受第三方 example 包影响；`lib test` 仅 1 条既有 info。
