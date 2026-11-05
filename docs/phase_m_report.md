# 阶段 M 交付报告（锁屏语音 / 倒计时语音 / 目标播报 / 动态重规划 / 视觉 / 性能）

日期：2026-11-05 · 仓库：`<project-root>` · 分支：master

## 0. 诚实声明（任务书 §九 铁律）

本环境**无 Android 真机/模拟器**，也无法访问真实高德 Web 服务 API（后端
key 只存在于服务器环境）。因此：

- 所有代码均已实现并通过**离线**单元测试/契约测试/可复现基准（Dart 178 项、
  Python 146 项，全绿；analyze 仅剩 1 条既有 info）；
- 一切依赖真机的结论（锁屏语音、真实 GPS 偏航、帧率、TTS 首响、真实
  重规划端到端耗时、高德底图实拍）**一律标注「待真机」**，绝不冒充实测；
- App 内已内置取证工具（语音诊断页 + VoiceLog 执行日志），用户下次真机
  跑步即可导出证据核对，见 §10 清单。

## 1. 提交与文件清单

| 提交 | 阶段 | 变更 |
|---|---|---|
| `f839594` | A/B/C | 14 文件 +1972/−42：`TtsDiag.kt`（原生引擎探测）、`MainActivity.kt`、`AndroidManifest.xml`（电池白名单权限）、`voice_log.dart`、`tts_diagnostics.dart`、`tts_service.dart`（单例）、`voice_diagnostics_screen.dart`、`settings_screen.dart`、`countdown_overlay.dart`（重写）、`run_screen.dart`、`nav_announcer.dart`、3 个测试文件 |
| `293c4f4` | D 后端 | 5 文件 +750/−4：`backend/reroute.py`（新）、`backend/server.py`（/api/route/reroute + v0.6）、`backend/guard.py`（限流/并发闸）、`tests/test_reroute.py`（21 项）、`tests/test_server_api.py` |
| `9aa0f34` | D 前端/E | 8 文件 +1329/−22：`nav_state.dart`（六态状态机，新）、`reroute_api.dart`（客户端，新）、`nav_announcer.dart`（suspend/rebind）、`run_screen.dart`（编排+原子接入+横幅）、`route_style.dart`、3 个测试文件 |
| `e5d44aa` | F | 13 文件 +824/−62：`route_style.dart` v3、`map_icons.dart`（双形态箭头/去圆圈标注）、`turn_annotations.dart`（planArrowPlacements）、`route_candidates_screen.dart`、`run_screen.dart`（canonical 参考层）、`tools/visual_scheme_*.py`、`docs/visual/*`、测试 |
| `0e14ddf` | G | 6 文件 +554/−73：`run_recorder.dart`（O(1) 视图）、`tts_service.dart`（warmUp）、`main.dart`（预热）、`run_screen.dart`（增量缓存+节流）、`test/perf_bench_test.dart`、`tools/bench_reroute_compute.py` |

架构保持：现有 keystore、Tailscale Serve（`https://your-device.your-tailnet.ts.net`）、
高德 Android SDK key 在 APK 内 / Web 服务 key 仅在服务器——均未改动。

## 2. A（P0）：锁屏语音不可用的根因与证据体系

**根因调查（源码级核验，非猜测）**：

1. `AMapFlutterLocationPlugin` 为纯 FlutterPlugin，无生命周期 stop——定位
   流在锁屏下不因插件本身中断；
2. `flutter_tts 4.2.5` 使用 applicationContext，仅在 onDetachedFromEngine
   时 shutdown；`setAudioAttributesForNavigation()` = USAGE_ASSISTANCE_
   NAVIGATION_GUIDANCE + AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK（只 duck
   音乐，绝不永久停止他方音频）；
3. `flutter_foreground_task 11.0.3` 持有 PARTIAL_WAKE_LOCK，前台服务
   （serviceId 9101）在锁屏下保活；
4. 代码链路（定位→播报队列→TTS）在前台已验证正常 ⇒ 嫌疑收敛为
   **Vivo ROM 后台冻结/自启限制** 与 **默认 TTS 引擎缺真实中文能力**
   （设备提示「语言引擎中缺少中文语音数据」，仅装「腾讯视频」「AI
   Service CS」两个引擎）。

**为此落地的证据与修复体系（§2.3「实际执行日志和状态信息」）**：

- `VoiceLog`：每次 speak/start/done/cancel/error + 生命周期/FGS/系统事件
  带毫秒时间戳入内存环（300 条）并持久化最近一次会话
  （`voice_log_last_session_v1`）——锁屏期间是否真正调起 TTS、首响延迟
  多少、是否被系统打断，全部可事后取证；
- 原生 `TtsDiag.kt`（MethodChannel `runloop/tts_diag`）：直接用 Android
  TextToSpeech API 枚举全部引擎、探测 zh-CN 支持（含 embedded/network
  区分）、真实 speak 试验（单飞锁防并发），12s init / 10s speak 超时；
- 语音诊断页：电池白名单/自启动/后台定位引导 + 引擎列表探测/试听/一键
  选用 + VoiceLog 查看与复制（不含账号/密钥/隐私数据）；
- TTS 单例（`FlutterTtsEngine.shared`）：杜绝多实例互相覆盖回调；
  `applyEngine` 换引擎后 Dart 回调仍存活（原生 setEngine 重挂监听器）；
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 权限（用户已批准方案「新增权限
  + 引导」）。

**判定标准（§2.3：不能仅以前台播放正常为通过）**：待真机按 §10-1 步骤
导出锁屏期间的 VoiceLog（应含 fgs/lifecycle 与 speak→start→done 完整链）
后方可宣布修复成立。

## 3. B（P1）：倒计时语音

- 语音「三。」「二。」「一。」「开始跑步。」与数字显示严格同步（同一
  display 变更同时触发脉冲动画与 per-digit `flush:true` 播报，前一条被
  后一条打断，绝不叠字）；
- **数字重叠结构性修复（§3.2）**：单个 Text + ScaleTransition 脉冲
  （0.35→1.0，220ms easeOutCubic），固定 200×200 容器居中——不是「多个
  Text 叠加」，同一时刻屏幕上只可能存在一个数字，宽度不跳变，圆环进度
  与数字同步；
- GO 时序：「开始跑步」播报在 `onGo()` **之前**发出 ⇒ GO 时刻 == 倒计时
  结束时刻，TTS 完成与否绝不拖延起跑；出发播报改为「沿X前进」防与
  「开始跑步」重复；
- 引擎不可用 → 视觉倒计时完整可用（语音全部 try/catch 静默降级）；
  取消 → `engine.stop()` 清空语音队列且绝不触发 GO；
- 测试：`countdown_overlay_test.dart` 8 项（4 视觉 + 4 语音，FakeSpeech
  注入）全绿。真机听感待验证（§10-4）。

## 4. C（P1）：目标距离完成

- 达到用户设定目标一次性播报「X公里跑步目标已完成，您可以选择继续跑步
  或结束本次运动。」；`flush:false` 排队 ⇒ 第 15 公里整公里时先播配速
  再播目标（§4.2 示例场景有单测覆盖）；
- UI：完成卡片（🏆 + 已跑公里数）+「继续跑步」（关闭卡片继续记录）/
  「结束运动」（进入总结页）；**绝不自动结束**；无语音对话交互；
- 测试：`nav_announcer_test.dart`（配速/目标排队）+ run_screen 逻辑走查。
  真机播报待验证（§10-4）。

## 5. D（P0）：真实动态重规划 + E：新路线语音重绑定

**状态机（§5.1，非布尔）**：`NavStatus` 六态
ON_ROUTE→POSSIBLE_DEVIATION→OFF_ROUTE→REROUTING→REROUTED→(ON_ROUTE)
/ REROUTE_FAILED；全部迁移显式带锁（`beginReroute` 仅允许 offRoute/
rerouteFailed 进入，rerouted 为原子接入前的瞬态）。

**判定（§5.2，替代 120m 单阈值）**：阈值 = 精度×2 夹取 [25,60]m；
坏精度点（>60m）不投票不清票；需连续 ≥3 票且持续 ≥8s；行进方向与路线
切线夹角 >60° 时该点偏移门槛 ×0.6（置信度加权）；全部可配置
（`DeviationConfig`）。15 项单测覆盖（含抖动不误报、GPS 跳点免疫）。

**确认偏航（§5.3）**：立即停播旧步骤语音并清空待发队列
（`suspendForReroute`，掐断 idle 插播路径），保留原路线与 GPS 轨迹，
播「路线偏离，正在重新规划」，真实请求发出——旧转弯提示绝不再播（单测）。

**重规划链路（§5.4/5.6）**：`POST /api/route/reroute` ←
`RerouteClient`；后端在**剩余路线**上采样候选接回点（结构上不可能接回
历史段），每个候选用**真实高德步行 API** 规划连接段，评分 = 绕行米数
+ 12×转弯数，优先满足 |预计总里程 − 目标| ≤ 500m 的候选；合并 =
连接段 + 接回点 + 原剩余尾段（接缝去重）；响应含真实
`api_calls/elapsed_s/within_tolerance/estimated_total_m` 与明确错误码
（BAD_REQUEST/NO_REJOIN/AMAP_ERROR/RATE_LIMITED）。AMap Web key 仅在
服务器环境变量，APK 内绝无（有防泄漏单测断言响应不含 key）。

**客户端编排（§5.7）**：每次偏航事件 = 重规划锁 + 递增请求 ID（过期
结果按 ID 丢弃）；自动重试上限 2 次 + 30s 冷却 + 手动重试按钮不受冷却
限制；请求超时 25s；断网/失败 → 播「暂时无法重新规划路线，将继续记录
本次运动」，**记录不中断、绝不结束运动**；同一 GPS 点只投一票。

**原子接入 + E（§5.4#8-11/5.8）**：成功后单帧内切换 active 路径/折线/
steps（连接段 steps + 原剩余 steps 按新里程重定基，旧步骤 ID 与队列全部
作废），`rebind` 播「路线已经重新规划…」，越过接回点播「已重新接回原定
路线」；自然跑回原路线 → 「已回到规划路线」。steps 重定基在客户端完成
（节省上行带宽；已在 §5 报告中如实记录该设计决策）。

**容差诚实（§5.5）**：超差时横幅如实展示「新路线预计总里程 X 公里
（比原目标多 Y 公里）」+ 语音提示略长，绝不伪装达标。

**测试**：后端 21 项（候选采样只取剩余段/终点恒含/评分/合并几何/错误
码/限流/预算硬上限/key 不泄漏）+ 前端 24 项（状态机 15、客户端契约 6、
announcer suspend/rebind 3）。**真实高德 API 的请求/响应样例与端到端
耗时：待真机/服务器联调（§10-2），本机绝无冒充。**

## 6. 重规划前后路线对比

- 离线证据：`tests/test_reroute.py` 断言合并路线起点 = 当前位置、终点 =
  原路线终点（闭环语义保持）、连接段来自真实 planner 返回折线、里程
  重算诚实（`estimated_total_m = completed + connector + 剩余尾段`）；
- 视觉对比：`docs/visual/compare.png` 含重规划琥珀连接段 + canonical
  参考层渲染（模拟底图）；真实道路上的前后对比截图待真机（§10-3）。

## 7. 视觉方案（F，§6.1–6.4）

双方案内部对比已完成（任务书要求「至少两套」）：

- 渲染：`tools/visual_scheme_compare.py` → `docs/visual/scheme_a.png`、
  `scheme_b.png`、`compare.png`、`sunlight.png`（模拟底图 + 阳光直射变体，
  覆盖去/返共路双侧标注、五图层、重规划段）；
- 客观指标：`tools/visual_scheme_metrics.py`（WCAG 对比度/层间色差/双侧
  可见性像素验证），全表见 `docs/visual/README.md`；
- **定稿**：B 方案主体（深蓝细实线高对比渐变 #1565C0→#1E88E5、去=实心/
  返=空心箭头形状+颜色双编码、转弯标注去圆圈化）+ 吸收 A 方案白描边、
  GPS 橙 #FF3D00、重规划琥珀 #FFB300（层间色差实测更优）；
- 几何铁律：全部为样式/像素层改动，canonical 折线、导航文本、距离指标、
  GPS 轨迹零改动；圆角仅屏幕空间连接，绝不把线平滑出道路；路名/建筑名
  不被遮盖（细主线 2.8dp + 白描边 4.6dp）；
- 五图层显式化（§6.3）：canonicalRef(z4) / completed(z9-11) /
  remaining casing+core(z10/20) / reroute(z22/24) / gpsTrack(z28/30)，
  前方粗、已跑柔、重规划段琥珀独立、同路重叠由 ±16px 双侧标注解决；
- 高德真实底图截图：待真机（§10-3）。

## 8. 性能数据（G，§7.3 前后对比）

本机可复现基准（`flutter test test/perf_bench_test.dart`，2 小时长跑
末段场景 N≈7000 轨迹点、5km/1400 点路线、1Hz GPS）：

| 项 | 优化前 | 优化后 | 降幅 |
|---|---|---|---|
| B1 recorder.points 访问 ×200 | 6256µs | 75µs | **98.8%** |
| B2 轨迹 LatLng 换算 ×200 帧 | 41644µs | 475µs | **98.9%** |
| B3 完成/剩余切片 ×200 帧 | 6964µs | 1067µs（重切 100/200 帧） | **84.7%** |
| B4 地图原生序列化点数 ×200 帧 | 3 228 458 pts | 1 614 086 pts | **−50%** |
| B5 地图匹配（K 阶段成果复核） | 17541µs（全局扫描） | 3055µs（窗口化） | **82.6%** |
| B6 GPS 单帧管线绝对成本 | — | **23.4µs/帧**（≪16ms 帧预算 5%） | — |
| 后端重规划算法层 ×30 | — | **mean 1.2ms / p95 1.5ms**（`tools/bench_reroute_compute.py`） | — |

对照检查清单（§7.2 十项）：UI 重建（B1/B2/B3 缓存化）✓；地图重绘
（B4：Polyline 对象缓存 + 插件深比较相等即免原生更新；轨迹 2s 节流，
**记录数据零丢失**）✓；TTS 预初始化（启动 warmUp，倒计时「三。」首响
不含冷启动）✓；重复 TTS 实例（单例，A 阶段）✓；overlay 重建（候选页
静态 Marker 缓存 + 固定 id 原地更新，K 阶段已有）✓；全路线扫描（B5
窗口化投影，K 阶段已有，本次复核数据）✓；冗余相机更新（1Hz 目标位姿
+ 20Hz 插值渲染，L2 已有）✓；主线程计算（B6：单帧 23µs）✓；重复 API
调用（重规划在飞锁 + 请求 ID + 冷却 + 上限，D 阶段）✓；数据库阻塞 UI
（sqflite 全异步，写入仅发生在保存/结束时刻，跑步中零 DB I/O）✓。

**待真机**（方法学已内置）：页面帧率（DevTools Performance / `flutter
run --profile`）；TTS 延迟（VoiceLog「首响 Xms」时间戳，语音诊断页可
导出）；重规划端到端耗时（后端响应 `elapsed_s` + VoiceLog reroute 条目）。
绝不以离线基准冒充真机帧率。

## 9. APK 构建

本次构建时间 2026-11-05，产物 `build/app/outputs/flutter-apk/`：

| 产物 | 大小 | SHA256 |
|---|---|---|
| `app-debug.apk` | 189.3 MB | `232D32C282A568048FBAAEB1355BEA83E246843AF89BFA4A4B09FFD2D3DB134D` |
| `app-release.apk` | 75.0 MB | `B58FCA5DB3A9811E7C0809966934A84D7EDA0FDA7507D0BD3E27E29B3D0956E1` |

签名校验（`apksigner verify`）：两者均通过；release 证书
`CN=RunLoop, OU=RunLoop, O=RunLoop, L=Shanghai, C=CN` —— **沿用现有
keystore，可直接覆盖安装旧版**。Release 构建注入
`TAILNET_BASE_URL=https://your-device.your-tailnet.ts.net` 与高德 Android key；
高德 Web 服务 key 不在 APK 内（服务器环境变量）。

构建过程修复：`TtsDiag.kt` 兜底枚举里 `ResolveInfo` 误用不存在的
`.package` 属性 → 改为 `serviceInfo.packageName`（`mapNotNull` 过滤
无 serviceInfo 的条目），Debug/Release 均编译通过。

## 10. 待真机验证清单

1. **锁屏语音取证**：装新 APK → 语音诊断页确认引擎（建议「检测语音
   引擎」+「测试普通话」，若无 embedded zh 引擎按页面指引处理）→ 授予
   电池白名单/自启动 → 开始跑步 → 锁屏 ≥10 分钟 → 导出 VoiceLog：
   应见 fgs/lifecycle 条目与锁屏期间 speak→start→done 完整链。
2. **偏航实测 4 案例（§八）**：A 左转弯走错 → 8–12s 内确认偏航 →
   「路线偏离，正在重新规划」→ 琥珀连接段 → 「已重新接回原定路线」→
   后续提示与新路线一致；B 错过右转同上；C GPS 漂移（高楼旁）不误触发
   （坏精度点不投票）；D 飞行模式偏航 → 「暂时无法重新规划」+ 记录
   继续 + 手动重试按钮 → 恢复网络后重试成功。同时记录真实
   `/api/route/reroute` 请求/响应与 elapsed_s。
3. **视觉实拍**：预览页/跑步页（含重规划后）高德底图截图，核对细主线
   不遮路名、去/返双侧标注、五图层区分、阳光直射可读性。
4. **倒计时 + 目标播报**：语音倒计时与数字同步无叠字；设 1km 短目标
   验证「目标已完成」播报 + 卡片 + 继续/结束两分支；整公里配速与目标
   同刻的排队顺序。
5. **真机性能**：`flutter run --profile` + DevTools 记录跑步页帧率、
   VoiceLog 首响延迟、重规划端到端耗时，与 §8 离线基准互相印证。
6. **Vivo TTS 专项**：诊断页「检测语音引擎」结果截图（引擎列表/zh-CN
   支持/embedded 标志）；若两引擎均无真实 zh 能力，按 §十 决策回到
   「官方在线 TTS（付费）」评估——当前按用户决定**暂缓**，未集成任何
   非官方在线 TTS。
