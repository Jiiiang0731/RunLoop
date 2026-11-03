# 阶段 K 验收报告（环跑 RunLoop）

> 生成日期：2026-11-03 ｜ 回归代码基线：master `58875e6`；追加提交：`f789cc0`（回归数据+本报告）、
> `3246cb2`（部署实测+自启注册）、`b679a85`（连续性/离线测试）——均不影响回归所测服务端代码。
> 验收分区约定：**【代码测试】**本机可复现的自动化测试；**【Tailscale 公网测试】**需真实 Tailnet 环境；
> **【真机测试】**需 Android 手机；**【未验证】**如实列出、绝不冒充通过。
> 铁律回顾：±500m 容差绝对化（决策①）；标注/视觉永不改真实几何（规范③④）；
> 绝不把局域网版冒充正式公网部署（规范⑥）。

## 1. 阶段 K 目标与完成状态总览

| # | 规范条目 | 状态 | 证据 |
| --- | --- | --- | --- |
| ① | 路线视觉重设计（细主线/轻描边/分层/小巧稀疏箭头/保留生长动画） | ✅ 代码完成 | `86ccad1`；【真机测试】待用户装机确认观感 |
| ② | 真实重复段识别 + 去/返两侧标注（像素级侧偏、青/紫、随缩放） | ✅ 代码完成 | overlap v2 + turn_annotations；【代码测试】123+45 全绿 |
| ③ | 消灭无意义绕行（真实步行 API 替换，禁直线） | ✅ 代码完成 | spur_fix v2 三段式；回归数据见 §5 |
| ④ | 数据连续性拆分（canonical/animation/display/turnAnnotations/gpsTrack）+ 移除 ±10m 偏移拆分 | ✅ 代码完成 | `86ccad1`；一帧共存交接 |
| ⑤ | 保留阶段 J 机制（骨架变体+质量选优）；fig8/petal 纯凭实测定去留 | ✅ 完成 | 实测否决，数据见 §4.3 |
| ⑥ | 部署：Windows + Tailscale Personal 免费方案，waitress 仅 127.0.0.1:8000，Serve HTTPS，无 Funnel | ✅ 代码/脚本完成 | `b8f6e50`+`58875e6`；【Tailscale 公网测试】待用户安装后执行 A–G |
| ⑦ | App 配置：DEBUG=LAN / PRODUCTION=Tailnet HTTPS，单一来源，远程配置，release 无 LAN/localhost | ✅ 代码完成 | `ea34e0d`；release APK 待真实地址注入 |
| ⑧ | 安全：Key 仅服务端、限流、设备配额、并发闸、熔断、日志脱敏 | ✅ 完成 | `b8f6e50`；【代码测试】test_guard 13 + test_server_api 17 |
| ⑨ | 隐私：默认不上传 GPS、应用内隐私声明 | ✅ 完成 | `7a9ae68` consent_screen 六条声明 |
| ⑩ | 离线：选中路线全量入库、无网可看可跑、服务器宕机明确报错 | ✅ 代码完成 | `7a9ae68`；【真机测试】待飞行模式验证 |
| ⑪ | 开机自启 + 合理防睡眠（不擅改电源设置，先说明） | ✅ 已注册 | 启动文件夹 `RunLoopBackend.vbs` 已写入（任务计划需管理员，自动降级）；后端已实测拉起；set_awake.ps1 需用户确认，未执行 |
| ⑫ | 测试全绿 + 蔡店 5/10/15/20km 回归（spur 前后对比） | ✅ 完成 | Python 123 ✅ Dart 45 ✅；回归 7/7 达标（637 次真实调用），数据见 §5 |

## 2. 交付物清单

### 2.1 提交记录（阶段 K）

| 提交 | 内容 |
| --- | --- |
| `8690eb6` | 绕行修复 v2：跨段合并拼接 + 容差感知 + 割线重校；骨架探索结论 |
| `b8f6e50` | 后端生产化：waitress 回环监听 + 限流/熔断/并发闸 + 日志脱敏 |
| `c2e73e2` | Tailscale 部署指南（用户安装/授权清单 + 验证矩阵 A–G + 电源建议） |
| `ea34e0d` | App 配置重构（DEBUG=LAN / PRODUCTION=Tailnet）+ 远程配置 + 设备标识 |
| `86ccad1` | 视觉 v2 细线 + 真实重复段配对 + 去/返转弯标注（纯视觉层） |
| `7a9ae68` | 离线完整性 + 隐私声明 + 首页公告/未配置横幅 |
| `58875e6` | Tailscale 部署脚本（回环后端 + Serve 验证 + 自启 + 可选防睡眠） |
| `f789cc0` | 最终蔡店回归（冻结代码 7/7 达标）+ 本报告初版 + 旧代码基线存档 |
| `3246cb2` | 部署实测：后端拉起、自启注册（启动文件夹降级）、清剿残留 0.0.0.0 监听 |
| `b679a85` | 数据连续性/离线完整性测试（JSON 往返无损/幂等 + 设备 ID 契约） |

### 2.2 关键文件

- 服务端：`backend/serve.py`（waitress 入口）、`backend/server.py`（create_app 工厂 + `/api/client-config`）、`backend/guard.py`（限流/熔断/并发闸/脱敏）、`backend/route_generator/spur_fix.py`、`calibrator.py`、`overlap.py`
- App：`lib/app/config.dart`、`lib/utils/route_style.dart`、`lib/utils/turn_annotations.dart`、`lib/utils/map_icons.dart`、`lib/screens/route_candidates_screen.dart`、`lib/services/device_id.dart`、`lib/services/client_config_service.dart`
- 部署：`deploy/start_backend.ps1`、`deploy/setup_tailscale_serve.ps1`、`deploy/register_autostart.ps1`、`deploy/set_awake.ps1`、`deploy/README_deploy.md`、`docs/tailscale_setup_guide.md`

## 3. 【代码测试】自动化测试结果

| 套件 | 数量 | 结果 | 说明 |
| --- | --- | --- | --- |
| Python `tests/`（pytest） | 123 | ✅ 全绿 | 含 spur_fix 跨段/容差 20 项、guard 13 项、server API 契约 17 项、overlap v2 配对 5 项 |
| Dart `test/`（flutter test） | 45 | ✅ 全绿 | route_path 24 + run_recorder 3 + turn_annotations 12 + offline_data 6（离线 JSON 往返无损/幂等 + 设备 ID 契约） |
| `flutter analyze`（lib/test） | — | ✅ 0 error / 0 warning | 仅 1 条 info 级 lint（use_null_aware_elements，保留 if 写法以兼容 SDK 约束） |
| debug APK 构建 | — | ✅ `√ Built app-debug.apk` | Gradle 76s；exit 1 为 SDK XML 版本警告（良性） |

关键单测举要：
- **overlap v2 路口交错配对**：X 路去程与 Y 路去程在路口相邻（v1 按「相邻区间」会错配为一组），v2 按空间链接多数票正确配成 (X去,X返)/(Y去,Y返)，并断言 `start集合 != {0,10}`；
- **跨段拼接完整性**：合并段后 `_build_index_map` 有效、首尾点去重假设成立、二次修复零尝试；
- **容差感知**：`target±tol` 之外的修复直接拒绝（attempts 记录 reject:"tolerance"，零 API 浪费）；
- **熔断半开重探失败重新开路**（修复了原「半开无限探测」死锁隐患）；
- **标注纯视觉铁律**：`buildTurnAnnotations` 前后 canonical 折线逐点相等。

## 4. 算法与实现要点

### 4.1 绕行修复三段式（规范③，全部真实步行 API，绝无直线）

1. **Stage 1 激进修复**：`fix_spurs(best)` 全量修复（≤3 处/轮，多轮），省距后仍在 ±500m 内 → 无条件采纳（守卫已保证更短、转弯不增、重复不增）；
2. **Stage 2 割线重校**：省距导致超差时，按 (R, 修复后距离) 样本做割线法迭代 ≤3 次（首次比例法），R 限幅 [0.6,1.8]×best_R，预算门控 `calls+(n_points+12) ≤ max_calls`；采纳条件 = 达标 **且** 评分 ≥ best−5.0（质量优先，决策②）；
3. **Stage 3 容差感知部分采纳**：`fix_spurs(target_m, tol_m)` 只保留不破坏达标的修复（规划调用命中缓存≈零成本），否则诚实回退 `spur_revert`。

**实测路网悬崖**（15km 蔡店，割线法记录）：修复后距离对 R 的响应
`11868m@R×1.0 → 20533m@×1.202 → 14045m@×1.071 → 20425m@×1.09`
——×1.071 与 ×1.09 之间存在河流/屏障导致的不连续跳变，15000m 目标在该骨架族内不可达 → 按设计诚实回退，残余折返交由标注层可视化。**绝不把超差结果包装成通过**（决策①）。

真实垃圾绕行修复案例（A 组采纳）：1577m 纯死胡同往返（替换后 1.0m）、1303.8m 折返（步级吸附后跨度 1908.8m，替换 605m，转弯 4→2）。

### 4.2 spur_fix 参数（集中配置，全部实测调参）

CELL_M=25 ｜ MATCH_M=25 ｜ 跨度 150–1200m ｜ 折返比 ≥0.5 ｜ 最小省距 80m ｜ 转弯角 ≥45° ｜ 每轮 ≤3 处 ｜ 吸附跨度上限 2400m（防步级吸附过度扩张）｜ 割线重校 ≤3 次 ｜ 评分松弛 −5.0。

### 4.3 骨架探索结论（决策④：fig8/petal 纯凭实测）

`backend/out/bench_phase_k_explore.json`（594 次真实 API 调用，蔡店 15km 双种子）：
- **fig8**：两种子均超差（err +611/+659m），重复率 ≈0.48 → **否决**；
- **petal(n=9)**：达标但质量差——评分 28.9–34.6（冠军 51.0）、重复率 0.54–0.60、转弯最多 50 次 → **否决**；
- 代码保留（有测试覆盖）但不进默认 `plan_variants`；默认仍为阶段 J 冠军组合 [lean_ell, base, lean_cir]。

### 4.4 重复段识别 v2（规范②）

网格哈希配对链接（25m 格 / 28m 匹配半径 / 反向 ≥120° 或同向 ≤20° / index_gap 25 防紧转角自配）→ 重叠边聚 run → **转角 >60° 切分子段**（路口处两条路各自成段）→ 子段间按链接落点**多数票互相认领**（每子段只配一次）→ 输出 pass1/pass2 + direction + 累计里程区间。v1 的「相邻区间两两配对」在路口场景系统性错配，v2 已修复并有专项测试。

### 4.5 去/返转弯标注几何（纯视觉层）

- 位置：重复段两 pass 的中点（服务端累计里程标注）+ U 形折返尖点前后（本地检测 ≥135° 翻转）；成对出现、两侧对称；
- 侧偏：屏幕像素定位——`米 = 16px × mpp(zoom, lat)`，`mpp = 156543.03392·cos(lat)/2^zoom`；垂线方向 = 行进方位 + 90°（地理垂线在相机旋转下两侧对称性不变，故只需随 zoom 重算）；
- 联动：`onCameraMove` 节流 200ms/0.25 级 → 重算位置；Marker id 稳定（ta-*）→ 插件原地更新不重建；
- 颜色：去程青 `#00796B` / 返程紫 `#7B1FA2`；白圆底人字图标（30px）与实心方向箭头（36px）明显区分；
- 限量：单路线 ≤12 枚、对间距 ≥90m、成对完整性（孤枚丢弃）；
- **铁律**：只读 canonical 折线，永不写回；导航/GPS/偏航/距离指标零影响（单测断言）。

### 4.6 视觉 v2（规范①）

| 参数 | 阶段 J | 阶段 K v2 |
| --- | --- | --- |
| 主线宽 | 5.5dp | **2.8dp**（规范 2–3dp） |
| 描边 | 9.5dp 白 90% | **4.6dp 白 80%（轻描边）** |
| 未选中 | 3.0dp α60 | 2.0dp α46 |
| GPS 轨迹 | 4.5/8.0dp | 3.4/5.2dp |
| 方向箭头 | 48px、每 2.5km、3–8 枚 | **36px、每 3.5km、2–5 枚（小巧稀疏）** |
| 生长动画 | ✅ | ✅ 保留（阶段 J 验收资产） |

### 4.7 数据连续性拆分（规范④⑤）

- **canonical**：服务端折线，App 内只读（导航/偏航/里程/GPS 同源）；
- **animation**：RoutePath + 固定 id 生长线（逐帧原地 setPoints，30fps 节流）；
- **display**：静态整条细主线（`sel-casing-N`/`sel-core-N` 稳定 id），**±10m 重复段偏移拆分已移除**（折线零失真，重复信息由标注层表达）；
- **交接**：动画完成瞬间「一帧共存」——静态线（下）+ 满进度生长线（上）同帧，`postFrameCallback` 再移除生长层 → 切换零空窗；
- **turnAnnotations / gpsTrack**：独立层（见 §4.5；gpsTrack 仅跑步页，橙 3.4dp）。

## 5. 蔡店回归（5/10/15/20km，真实 API）【代码测试】

> 坐标 `(114.087279, 30.536395)` GCJ-02。最终代码（`58875e6` 基线）全量重跑：
> A 单候选 seed2 × 4 距离 + B App 默认首条（修复开）+ B0（修复关）+ C 三候选。
> 共 637 次真实 HTTP（其余命中本地缓存回放）；结果 `backend/out/bench_phase_k.json`，
> 旧代码基线存档 `bench_phase_k_oldcode.json`。
> **字段语义**：`spur_saved_m` = Stage1 激进修复的**尝试级**总省距（不代表净采纳）；
> 净效果以最终 dist/err 及与 B0/旧代码对比为准（决策①：±500m 硬约束优先）。

### 5.0 结果总表（最终代码）

| 场景 | 目标 | dist(m) | err(m) | 达标 | score | turns | rep | 尝试修复 | 残留绕行 | rec调用/耗时 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A seed2 | 5km | 5159.8 | +159.8 | ✅ | 46.6 | 16 | 0.344 | 3 处 / −1570.1m | 3 | 49c / 13.3s |
| A seed2 | 10km | 9831.5 | −168.5 | ✅ | 39.2 | 21 | 0.352 | 3 处 / −2874.7m | 3 | 74c / 17.9s |
| A seed2 | 15km | 14504.0 | −496.0 | ✅ | 51.0 | 24 | 0.355 | 2 处 / −2242.4m | 3 | 132c / 35.8s |
| A seed2 | 20km | 20376.0 | +376.0 | ✅ | 50.3 | 32 | 0.336 | 2 处 / −1470.6m | 4 | 157c / 45.4s |
| B 首条(修复开) | 15km | 14874.0 | −126.0 | ✅ | 69.3 | 17 | 0.322 | 2 处 / −2880.0m | 3 | 69c / 18.7s |
| B0 首条(修复关) | 15km | 14874.0 | −126.0 | ✅ | 69.3 | 17 | 0.322 | — | 3 | 21c / 1.1s（全缓存） |
| C 三候选 | 15km | 14874.0 | −126.0 | ✅ | 69.3 | 17 | 0.322 | 2 处 / −2880.0m | 3 | 69c / 3.0s（rec）|

**7/7 全部达标（±500m 内），闭合误差全部 0.56m，构建失败 0。**

### 5.1 新旧代码对比（旧 = 单次线性重校版 `bench_phase_k_oldcode.json`）

| 场景 | 旧 err → 新 err | 旧尝试省距 → 新尝试省距 | 结局 |
| --- | --- | --- | --- |
| A 5km | −417 → **+160**（更居中） | 574 → **1570.1** | 新代码经割线重校采纳**更干净的等距路线**：turns 17→16、密度 3.68→3.08、score 47.8→46.6（−1.2，在 −5 质量松弛内，换 1.5km 级垃圾绕行消除） |
| A 10km | −168.5 → −168.5（相同） | 547.5 → **2874.7** | 大修复会击穿容差（修复后 ≈7504m）→ Stage3 容差感知**部分采纳**了与旧代码相同的达标子集，最终几何一致（零回退） |
| A 15km | −496 → −496（相同） | 287.6 → **2242.4** | 同上：部分采纳，最终几何一致 |
| A 20km | +425.5 → **+376.0** | 1125.8 → **1470.6** | 采纳更优子集，误差收窄 49.5m；残留检出 2→4（几何变化后新增可检出小区间，如实记录） |
| B/C 15km | −126 → −126（相同） | 1303.8 → **2880.0** | **实测路网悬崖** → 诚实回退（见 §4.1 悬崖序列），最终 = 未修复的达标路线，与 B0 完全一致；残余折返由标注层可视化 |

**结论**：跨段拼接修复让 Stage1 可发现的垃圾绕行扩大到旧代码的 2.7~5.2 倍；
三段式策略保证「能安全采纳的绝不错过、不能安全采纳的绝不硬塞」——所有场景
最终误差与旧代码持平或更好，无一例把超差结果冒充达标（决策①）。
质量优先的代价（决策②）：rec 调用数上升（13→49、30→69 等），仍远低于 800 预算，
单路线墙钟 13–45s。

### 5.2 spur 前后对比（规范⑫，B0=修复关 / B=修复开，同种子同缓存）

- 该种子（15km seed1）B 与 B0 最终几何一致：三处尝试共 2880m 省距全部因
  ±500m 硬约束不可安全采纳（修复后 ≈11994m，重校遭遇 §4.1 悬崖）→ `spur_revert`；
- **前后对比的有效样本在 A 组**：5km（−417→+160 且密度下降）、20km（+425.5→+376）
  为净改善；10/15km 为「更大候选被发现但按约束不采纳」的守约样本；
- 如实说明：本次回归未出现「修复开比修复关最终距离显著更短」的单种子对照
  （B0 场景恰逢悬崖回退）。修复净收益的直接证据是 A-5km 重校采纳（垃圾绕行
  消除后以相同目标距离重建）与尝试级省距的 2.7~5.2 倍扩大。

## 6. 【Tailscale 公网测试】部署验证（A–G）

**当前状态：Tailnet 链路未验证（等待用户完成安装清单）；本机侧前置已全部就绪并实测。**

本机已实测（2026-11-03 14:20）：
- waitress 生产后端经 `deploy/start_backend.ps1` 拉起，`GET http://127.0.0.1:8000/api/health`
  → 200 `{"breaker":"closed","env":"production","served":0,"service":"runloop-route-api","status":"ok","version":"0.5"}`；
- `Get-NetTCPConnection -LocalPort 8000 -State Listen` → **仅 127.0.0.1:8000**；
  （排查中发现并终止了一个上午遗留的旧版开发服务器 `python backend/server.py`，
  它绑 0.0.0.0:8000 对局域网可见——阶段 J 调试残留，非阶段 K 代码；已写入
  `deploy/README_deploy.md` 常见问题）；
- 登录自启已注册：任务计划需管理员权限被拒 → 自动降级写入用户启动文件夹
  `Startup\RunLoopBackend.vbs`（隐藏窗口、无需提权）；
- 早前 smoke（`b8f6e50` 时，端口 8001）：`Server: RunLoopAPI/0.5` 头、
  同机局域网 IP `192.168.1.100:8001` 拒绝连接 → 回环红线成立；
- Funnel：从未开启（setup 脚本内置红线检查，检测到开启即告警）。

| 项 | 内容 | 状态 |
| --- | --- | --- |
| A | PC 后端 + `tailscale serve --bg 8000` → 真实 HTTPS 地址 | ⏳ 待用户安装 |
| B | 手机浏览器经 Tailnet 打开 `/api/health` | ⏳ |
| C | 手机关 Wi-Fi（仅移动数据 + Tailscale）仍可达 | ⏳ |
| D | 正式版 App 移动数据下生成真实路线 | ⏳（需 release APK） |
| E | 手机与电脑无需同一校园网 | ⏳ |
| F | 电脑睡眠/后端停止 → App 明确中文报错；已存路线离线可看可跑 | ⏳ |
| G | 重启电脑自动拉起后端 + Tailscale | ⏳ |

**地址纪律**：`setup_tailscale_serve.ps1` 从 `tailscale status --json` 读取真实 MagicDNS 名并打印构建命令——**绝不手工编造地址**；release APK 只在 A 项实测通过后构建。

## 7. 【真机测试】Android 端

**当前状态：未验证（debug APK 已构建，待用户安装）。**

- `build/app/outputs/flutter-apk/app-debug.apk`（LAN 配置 `http://192.168.1.100:8000`，仅同校园网 debug 用）；
- **release 构建链路已预验证**（2026-11-03，不含地址注入的干跑）：`√ Built app-release.apk (73.5MB)`，
  签名（android/key.properties 沿用）、R8、图标字体树摇全部通过——最终构建只剩注入真实
  `TAILNET_BASE_URL` 一步，风险已排除。干跑产物已改名
  `app-release-dryrun-no-tailnet.apk`（未注入地址 → 装机后如实显示「服务器地址未配置」
  红条离线模式，**不可当正式版使用**，仅证明工具链）；
- 待验证项：细线观感/标注两侧对称与缩放跟随/生长动画无回退/切换路线无空窗/飞行模式下已存路线可看可跑/服务器宕机错误提示文案/远程配置公告；
- release APK：待 Tailnet 真实地址 → `flutter build apk --release --dart-define=TAILNET_BASE_URL=https://<实测地址> --dart-define=AMAP_ANDROID_KEY=<AndroidKey>`（签名沿用 `android/key.properties`，不重新生成）。

## 8. 集中配置清单（决策⑥等）

| 配置 | 值 | 位置 | 备注 |
| --- | --- | --- | --- |
| 偏航判定 | 120m | `AppConfig.offRouteMeters` | **未做长距离标定**（蔡店实测为短距离场景） |
| 投影窗口 | 250m | `AppConfig.matchWindowM` | 同上 |
| 距离容差 | ±500m 绝对 | 服务端 clamp [100,500] | 决策①：永不重新包装 |
| 生成预算 | per_seed 240 / 单次 ≤800（服务端 clamp ≤1500） | calibrator / server | 决策②质量优先 |
| 限流 | generate 8/10min、80/天；pois 30/h（按设备哈希） | `guard.DEFAULT_RULES` | 429 + Retry-After |
| 熔断 | 连续 3 次节流 → 开路 120s，半开单探测 | `guard.CircuitBreaker` | 503 UPSTREAM_QUOTA |
| 并发闸 | generate 1 / pois 2（可调） | `guard.ConcurrencyGate` | 429 SERVER_BUSY |
| 远程配置 | `/api/client-config`，App 缓存 24h | server + client_config_service | 增强而非依赖 |

## 9. 安全与隐私实现（规范⑧⑨）

- AMap Web Key：仅 `config/amap_key.local`（gitignore）或环境变量；单测断言 Key 明文**从不**出现在任何响应/日志/异常文本；
- 日志脱敏：坐标 → 2 位小数（≈km 级）；设备 ID → sha256 前 8 位；RotatingFileHandler 5MB×3；生产模式错误详情掩码；
- 设备标识：本地随机串 `rl-<ts36>-<20随机>`（无硬件标识符），同意隐私政策后才生成；
- GPS 轨迹：默认只存本机 SQLite；跑步数据不上传；
- 请求体上限 256KB；参数全量校验（target 1–50km、tol ≤500、seeds ≤3、candidates ≤3）。

## 10. 已知限制与后续路径

1. 120m/250m 偏航参数未做长距离标定（用户决策⑥：保持集中配置 + 注明）；
2. 15km 蔡店存在路网悬崖（§4.1），目标距离在特定骨架族内不可达时诚实回退——属路网客观限制，非缺陷；
3. fig8/petal 骨架已实测否决，代码保留未启用；
4. 云迁移路径（可选未来）：腾讯云轻量 HK 38–54 元/月 + 域名 ICP 备案 1–4 周；届时仅换 `TAILNET_BASE_URL` 注入值重打 APK，服务端零改动；
5. Tailscale Personal 免费版限制：3 用户/100 设备、非商业用途——当前单人使用完全够用。

## 11. 用户操作清单（最小集）

1. 按 `docs/tailscale_setup_guide.md` 完成：PC 安装登录 Tailscale → 控制台开 MagicDNS + HTTPS Certificates → 手机装 Tailscale 登录同一账号；
2. 回复我「装好了」→ 我运行 `deploy/setup_tailscale_serve.ps1` 完成 A–C/E 验证并读取真实地址（后端 waitress 已在运行、登录自启已注册，这两项无需你操作）；
3. （可选）回复「同意防睡眠」→ 我运行 `deploy/set_awake.ps1`（仅 AC 待机=从不，可随时恢复）；
4. 安装 `app-debug.apk` 真机试用（同校园网）；我拿到真实地址后构建 release APK 供移动数据验证 D/F/G；
5. 重启一次电脑验证 G（自启）。
