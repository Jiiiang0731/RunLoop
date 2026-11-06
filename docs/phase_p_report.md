# 阶段 P0/P1 整改报告：导航指令、播报时机、锁屏诊断、1 km 性能与交付

日期：2026-11-05
接手基线：`84a4777`（阶段 N-2，Python 172 / Flutter 185 测试全绿）
本次提交：`5a90ad0`（后端 P0/P1）、`b35da0d`（客户端 P0）

> 真实性约定：本报告把「自动化测试」「真实高德 API」「真机测试」分开写。
> 没有在用户 Vivo 真机上听到声音的项，一律标记为**待真机验收**，不写成已通过。

---

## 1. 结论先行

### 1.1 已修复并有自动化/真实 API 证据

1. **左右转方向不再由两套逻辑各算**：服务端输出统一 `TurnEvent`，地图图标、顶部“下一转弯”、TTS 全部消费同一对象；左右以实际行进方向为准，与地图旋转无关。
2. **明显转弯不再漏报**：旧碎步合并会把 4 个真实转弯（含 90°）吞成 1 条 121 m 指令；新规则禁止跨真实转弯/分段接缝合并。真实 1 km 路线由旧 8 条转弯恢复为 **5 左 + 5 右 + 2 掉头**。
3. **地图几何不再被抽稀裁角**：旧 `_downsample(points, 2)` 把 1081 m 折线压成 991 m（-8%）；改为 RDP 保形简化后长度误差 **0.17%**。
4. **播报时机改为路线进度 + 动态提前量**：`atM` 使用真实折线累计里程；提前量 = `max(用户设定, 配速 × 10 s)`，25–150 m；越过转弯 > 30 m 永久作废，不再补播过期指令。
5. **1 km 生成显著提速且更准**：真实 API 从 **112 次 / 29.4 s / 1076 m** 降至 **18 次 / 4.4 s / 1030 m**；接缝短折返（20 m 级）从 **2 → 0**。
6. **结束跑步二次确认**：标题/正文/两个按钮按任务书实现；返回键、点击弹窗外部、“继续跑步”都不结束；确认前 GPS/计时/语音不停止；组件测试 4 项通过。
7. **锁屏语音从“猜权限”改为“可诊断”**：前台服务先启动、30 s 心跳、TTS 6 s/20 s 看门狗、8 次/2 分钟锁屏自检、日志每 30 s 落盘。**真机验收仍待完成。**

### 1.2 部分解决 / 仍需后续

- 1 km 已无 20 m 级接缝短折返；**2.5 km 骨架路线仍有 5 处较长接缝折返**（`join_short_uturns=0`，但 `join_uturns=5`）。这些是骨架/控制点与真实路网不匹配造成的，需要后续自动锚点或道路图搜索，不能靠删点解决。
- 锁屏语音：代码路径、看门狗与诊断页已完成，但本环境没有 Vivo 真机，**不得宣称已通过**。
- 50 km 单 seed 1 会超差（+1387 m）；App 实际发送 `seeds=[1,2,3]` 时回归 49718.7 m（-281.3 m，within=true）。报告中必须写清参数。

---

## 2. 接手前基线

| 项目 | 基线 |
|---|---|
| Git | `master`，工作区干净，HEAD `84a4777` |
| Python 测试 | 172 passed |
| Flutter 测试 | 185 passed |
| `flutter analyze lib test` | 0 error / 0 warning，1 条历史 info |
| 后端 | v0.6，PID 36208，Waitress 127.0.0.1:8000，Tailscale Serve |
| 1 km 真实 API（某校园起点 114.164494,30.442040） | 112 次调用 / 29.4 s / 1076 m（+76 m）/ 闭合 0 m |
| 1 km 折线 | 原始 1081.3 m → 下发 991.4 m（-8.3%） |
| 1 km 转弯 | 旧合并后 8 条指令；4 个真实转弯被吞进 1 条 121 m 步骤 |

---

## 3. 根因证据（不是猜测）

### 3.1 折线被隔点抽稀

服务端旧代码：

```python
def _downsample(points, step=2):
    out = points[::step]
    ...
```

真实 1 km 路线 `loop.polyline` 44 点、1081.3 m；隔点抽稀后 23 点、991.4 m。
地图按 991 m 绘制，语音仍用高德步骤累计里程（1076 m），两者基准不一致：

- 地图几何被裁角，视觉转弯形态与步骤 action 可能不一致；
- App 的 `RoutePath.total` 小于步骤最后累计里程，转弯提示按步骤里程触发时已经偏晚；
- 去/返程或拐角处抽稀会改变实际左右转的视觉判断。

### 3.2 碎步合并吞掉真实转弯

旧 `build_nav_instructions` 的合并条件只有：

```python
self_straight = _ang_diff(it["enter_b"], it["exit_b"]) < 30
if it["distance_m"] < 40 and self_straight:
    # 并入上一步
```

它只看“当前碎步自身是否直行”，不看“上一步到当前步的边界是不是转弯”。
真实 1 km 路线中，以下 4 个边界被合进同一条 121 m 指令：

- 42 m 后右转；
- 22 m 处接缝掉头；
- 22 m 后右转；
- 35 m 后右转。

结果：一个明显的直角转弯完全不播报，残留的合并终点又可能是一个小角度，造成“该报不报、不该报乱报”。

### 3.3 地图与语音不是同一个事实来源

旧客户端地图转弯标记、顶部提示和 TTS 都各自扫描 `steps`；服务端又把几何推导出的 `turn` 写入 `action`。在折线抽稀、步骤合并、分段接缝三种情况下，三者可能得到不同结论。

### 3.4 分段接缝折返是真实存在的

1 km 路线由 9 段独立高德步行规划拼接，接缝处出现：

- 段 0 向东 253 m，段 1 先向西 42 m 再向北 22 m；
- 段 1 向北，段 2 向南——方向反转。

这些接缝折返不在高德 `steps.action` 中，旧质量指标完全看不到，却真实浪费距离、增加掉头语音。

---

## 4. 本次改动

### 4.1 服务端：统一 TurnEvent

新增 `backend/route_generator/turn_events.py`：

- `build_turn_events(segments, polyline)` 返回唯一转弯事件；
- `at_m` 一律是**真实下发折线**的累计里程；
- 几何角差与高德 action 交叉验证：
  - 两者一致 → `high`；
  - 只有 action / 只有几何 → `medium`；
  - 左/右冲突 → 以高德结构化 action 为准，标 `low`；
- 事件字段：`id / at_m / angle_deg / signed_deg / kind / announce / road_from / road_to / junction / step_index / join / source / confidence`；
- 接缝折返显式标 `join=true`，不再被静默吞掉。

角度分级：

| 角度 | 无 action 时 | 有 action 时 |
|---|---|---|
| < 20° | straight | 以 action 为准 |
| 20°–45° | straight（不误报轻微弯曲） | 以 action 为准 |
| 45°–150° | left / right | 以 action 为准 |
| ≥ 150° | uturn | 以 action 为准 |

服务端 `/api/route/generate` 新增 `turns` 数组；`steps` 仍保留，字段只增不改。
服务版本升至 **0.7**，健康检查新增 `turn_events=true`、`geometry_preserving=true`。

### 4.2 保形折线

`backend/route_generator/geo.py` 新增 `simplify_rdp(points, 1.5)`；
候选路线与重规划连接段不再隔点抽稀。

真实 1 km 验证：1081.3 m → 1079.5 m，误差 **0.17%**；所有真实拐角保留。

### 4.3 碎步安全合并

`nav_text.build_nav_instructions(steps, segments=None)`：

- 合并前必须满足：同一分段内 + 上一步到当前步边界为直行 + 当前步自身直行且 <40 m；
- 跨真实转弯、掉头、分段接缝一律不合并；
- 转向优先使用高德 action，几何兜底。

### 4.4 客户端：TurnEvent 贯通

- `lib/models/planned_route.dart` 新增 `RouteTurn`，解析服务端 `turns`；
- 旧缓存没有 `turns` 时，从结构化 `steps.action` 派生，不按地图箭头/屏幕方向猜；
- 地图转弯图标、顶部“下一转弯”、TTS 全部只消费 `_activeTurns`；
- 重规划后由新 steps 的 action 重建 `_activeTurns`，旧事件作废。

### 4.5 播报时机与去重

`lib/services/nav/nav_announcer.dart` 重写：

- 剩余距离 = `turn.atM − alongM`（真实折线进度）；
- 动态提前量：`max(用户设定, speedMps × 10)`，clamp 25–150 m；
- 两阶段：提前提醒 + 距转弯 ≤8 m 的“现在左转/右转/掉头”；
- 越过转弯 >30 m：永久标记已处理，绝不补播过期指令；
- GPS 回跳/重复 tick：事件 id 去重；
- 低置信度：降级为“前方有路口，请按地图路线方向行进”，不编造左右；
- 连续转弯 ≤80 m 合并播报；偏航/暂停/继续/公里配速队列语义保留。

### 4.6 结束跑步二次确认

新增 `lib/widgets/end_run_dialog.dart`：

- 标题：“确认结束本次跑步？”
- 正文：“结束后将停止本次运动记录，并保存本次运动数据。确定结束吗？”
- 按钮：“继续跑步” / “确认结束”；
- 返回键、点击外部、“继续跑步” → 不结束；
- `_endDialogOpen` + `_ending` 防重复；
- 只有明确确认后才停止前台服务、GPS、计时和语音。

### 4.7 锁屏语音诊断与看门狗

- 前台服务在 GO 瞬间先启动，再请求通知权限，避免权限弹窗延误 FGS；
- 跑步心跳每 30 s 记录：点数/公里/FGS/GPS 新鲜度/屏幕/Doze/TTS 是否在播/导航状态；并每 30 s 落盘日志；
- TTS 看门狗：
  - speak 提交后 6 s 无 `onStart` → 记录“请求已提交但引擎未出声”，并尝试重新初始化；
  - `onStart` 后 20 s 无 `onDone` → 记录“已开始但未完成/音频输出可能被中断”；
  - 迟到回调只记录，不重复调度队列；
- 语音诊断页新增“锁屏语音自检”：每 15 s 真实朗读一次，共 8 次（约 2 分钟），锁屏后解锁查看 speak → start → done / 看门狗错误。

### 4.8 折返指标与 1 km 性能

- `nav_metrics.join_turn_metrics` 新增：
  - `join_joins` / `join_uturns` / `join_sharp` / `join_short_uturns` / `join_short_uturn_m`；
  - 接缝折返计入有效转弯、急弯、掉头，并进入评分惩罚（短折返额外重罚）。
- 1 km（≤1.5 km）改用 **6 控制点**；1.5–3 km 仍用 8 点。
- 短距离变体：删除两个“圆心=起点”的棒棒糖变体，保留四个偏移方位 + 两个放大兜底；历史最优 `grid_off_se_big` 前置。
- 两个变体后若最优误差进入内部目标带（5%·目标）即早停。
- 1.5 km 内不做激进 `spur_fix`：实测它会把 1 km 从 1076 m 修到 742 m（-258 m）却仍在 ±500 m 内被接受，破坏用户要求的 0.99 km 精度。
- 1.5 km 以上的 `spur_fix` 部分采用增加 `tight` 距离守卫，不再仅凭评分接受。

---

## 5. 验证结果

### 5.1 自动化测试

| 项目 | 结果 |
|---|---|
| Python | **191 passed**（新增 19 项：TurnEvent 方向/契约、保形折线、接缝折返、6 点骨架） |
| Flutter | **201 passed**（新增 16 项：TurnEvent 契约、左右转/掉头、高速/低速提前量、跳点作废、低置信度降级、结束弹窗） |
| `flutter analyze lib test` | 0 error / 0 warning；仅 1 条历史 info（`route_api_service.dart:131`） |

方向测试覆盖：

- 90° 左转 / 90° 右转；
- 45° 左转 / 45° 右转；
- 近似直行（不产生转弯事件）；
- 连续转弯不被吞；
- 180° 掉头；
- 同一条路线反向行走（左变右）；
- 地图旋转：TurnEvent 只含地理方位与真实折线里程，不含屏幕坐标，客户端不参与重算；
- 高德 action 与几何冲突时以 action 为准并标 `low`。

时机测试覆盖：

- 8 m/s 在 70 m 外提前提示；2 m/s 在 70 m 外保持静默；
- GPS 跳点越过转弯 40 m 不补播；
- 正常到位播一次“现在”；
- 低置信度不编造左右；
- `atM` 与折线投影同一基准。

### 5.2 真实高德 API 回归（App 参数）

起点：某校园 `114.164494, 30.442040`；`tol_m=500`；1/2.5/5/15 km 使用 App 默认 `seeds=[1,2,3]`、`max_candidates=1`；50 km 同 App 参数。
数据文件：`/tmp/regress_*.json`（本次会话临时目录，最终数据摘录见下表）。

| 目标 | 调用 | 耗时 | 实测距离 | 误差 | 闭合 | 转弯 | 接缝短折返 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 km | 18 | 4.6 s | 1030.0 m | +30.0 m | 0.00 m | 9 | 0 |
| 2.5 km | 116 | 29.4 s | 2565.9 m | +65.9 m | 0.59 m | 24 | 0 |
| 5 km | 75 | 19.5 s | 4901.3 m | -98.7 m | 0.59 m | 27 | 0 |
| 15 km | 127 | 33.3 s | 15074.7 m | +74.7 m | 0.59 m | 33 | 0 |
| 50 km* | 562 | 151.1 s | 49718.7 m | -281.3 m | 0.59 m | 72 | 0 |

\* 50 km 必须使用 App 实际参数 `seeds=[1,2,3]`；单 seed 1 的复测为 51387.0 m（+1387 m，within=false），未隐瞒。

### 5.3 1 km 前后对比

| 指标 | 整改前 | 整改后 | 变化 |
|---|---:|---:|---:|
| 真实 API 调用 | 112 次 | 18 次 | **-84%** |
| 耗时 | 29.4 s | 4.4 s | **-85%** |
| 实测距离 | 1076.0 m | 1030.0 m | 误差 +76 → +30 m |
| 闭合 | 0.00 m | 0.00 m | 保持 |
| 有效转弯 | 12 | 9 | 更少无效折返 |
| 接缝短折返 | 2 | 0 | **20 m 级折返消除** |

### 5.4 APK

| 产物 | 大小 | 签名/校验 |
|---|---:|---|
| `dist/phase_p/RunLoop-环跑-Android-debug-P0P1.apk` | 190 MB | debug |
| `dist/phase_p/RunLoop-环跑-Android-release-P0P1.apk` | 76 MB | APK Signature Scheme v2 通过；证书 `CN=RunLoop`；SHA-256 `21a8b9db…ff8bdf` |

- 两个 APK 均注入 `TAILNET_BASE_URL=https://your-device.your-tailnet.ts.net`（release 在 dex、debug 在 kernel_blob 中核验到该地址）；
- Release APK 使用原有 `android/key.properties` 签名，未重新生成证书；
- 高德 Android Key 仅通过构建参数注入，未写入 Git/PPT/报告。

---

## 6. 锁屏语音：已完成与待验收

### 6.1 代码/诊断已完成

- 导航逻辑已从 `build()` 移到数据驱动 `_onNavTick`（阶段 N）+ 1 s 兜底定时器；
- 前台服务 `location` 型 + WakeLock；
- GO 瞬间先启动 FGS，再请求通知权限；
- 30 s 心跳覆盖 GPS 新鲜度、屏幕、Doze、FGS、TTS；
- TTS 6 s / 20 s 看门狗；
- 语音诊断页锁屏自检；
- 日志每 30 s 落盘，进程被杀后仍可回看最近一段。

### 6.2 真机验收清单（必须由用户完成）

1. 前台连续播报 3 分钟：转弯/公里/目标完成均有声；
2. 锁屏 10 分钟：心跳中 `gpsAge` 持续 <5 s，`fgs=true`；
3. 锁屏转弯：能看到 speak → start → done；
4. 锁屏每公里：公里播报有声；
5. 切到后台：GPS/语音继续；
6. 暂停/继续/结束：暂停立即静音，继续重新武装，结束不残留；
7. 若失败：记录看门狗错误/日志，区分“没提交、没出声、没播完”。

**结论**：本环境未连接 Vivo 真机，以上 7 项全部标记为**待真机验收**，不得写成已通过。

---

## 7. 折返治理：诚实状态

| 目标 | 状态 |
|---|---|
| 1 km 20 m 级接缝折返 | 已消除（`join_short_uturns 2→0`） |
| 1 km 接缝掉头 | 仍有 1 处（`join_uturns=1`，腿长 >80 m） |
| 2.5 km 接缝折返 | 仍有 5 处较长折返（`join_short_uturns=0`） |
| 删除折线点 | 未采用；没有为了“看起来干净”而切割真实折线 |
| 连通性/安全性 | 未因折返治理降低；闭合误差保持 0–0.59 m |

后续建议：自动锚点/道路图搜索，从候选生成阶段避免接缝折返；不要在事后删点。

---

## 8. 复现与交付

### 8.1 测试

```bash
cd <project-root>
python -m pytest -q
flutter test
flutter analyze lib test
```

### 8.2 后端

```powershell
powershell -ExecutionPolicy Bypass -File deploy\start_backend.ps1
# 健康检查应返回 version=0.7，features.turn_events=true
```

### 8.3 APK 构建（不记录密钥明文）

```bash
flutter build apk --debug \
  --dart-define=TAILNET_BASE_URL=https://your-device.your-tailnet.ts.net \
  --dart-define=AMAP_ANDROID_KEY=<从 android/amap_key.properties 读取>
flutter build apk --release \
  --dart-define=TAILNET_BASE_URL=https://your-device.your-tailnet.ts.net \
  --dart-define=AMAP_ANDROID_KEY=<从 android/amap_key.properties 读取>
```

### 8.4 交付物

| 文件 | 说明 |
|---|---|
| `dist/phase_p/RunLoop-环跑-Android-release-P0P1.apk` | Release APK（v2 签名） |
| `dist/phase_p/RunLoop-环跑-Android-debug-P0P1.apk` | Debug APK |
| `dist/phase_p/RunLoop_项目汇报_P0P1.pptx` | 20 页 16:9 可编辑 PPT，含备注/占位 |
| `dist/phase_p/RunLoop_项目汇报_P0P1.pdf` | 20 页 PDF 预览 |
| `dist/phase_p/slides/slide_01..20.png` | 每页 PNG 预览 |
| `dist/phase_p/截图补充清单.md` | 截图/录屏逐项清单 |
| `docs/phase_p_report.md` | 本报告 |

---

## 9. 未完成 / 未验证（必须如实告知）

1. **Vivo 真机锁屏语音**：未验收；只完成代码、诊断、看门狗与自检工具。
2. **真机方向/时机全量验收**：自动化与真实 API 已验证事件与文本，但真实跑步中的 GPS 漂移、路口形状仍需用户实测。
3. **2.5 km 骨架路线质量**：仍有 5 处接缝折返；锚点闭环质量更好，但 App 尚未开放锚点输入 UI。
4. **安全/车流/照明/路宽**：无真实数据，没有合成安全分；`road_safety`/`traffic_exposure` 仍为 `available=false`。
5. **50 km 弱网/移动网络**：只在本机 Tailscale/局域网条件回归；弱网耗时未验证。
6. **iOS / 云部署**：未实现；Tailscale 不是公网服务器，电脑必须开机在线。
7. **旧缓存路线**：没有 `turns` 字段的旧路线由 steps.action 派生，折线可能仍是旧版抽稀数据；建议重新生成以获得新几何。

---

## 10. 提交记录

| 提交 | 内容 |
|---|---|
| `5a90ad0` | 阶段 P0/P1 后端：TurnEvent + 保形折线 + 转弯不漏报；1 km 112 次/29.4 s → 18 次/4.4 s（1030 m） |
| `b35da0d` | 阶段 P0 客户端：TurnEvent 贯通、动态提前量、锁屏诊断、结束确认 |

未执行 `git reset --hard` / `git clean -fd`；未删除历史；未重新生成 Release 证书；未把高德 Web Key、Android Key、Tailscale 凭据写入 Git/APK/PPT/报告。
