# Phase L 交付报告：语音导航 · 每公里配速 · 环形倒计时 · Heading-Up 地图 · 视觉融合 · 图标恢复

日期：2026-11-04 ｜ 基线：Phase K（`d292dd0`，设备实测通过）→ `2cca70c`（模块 0 + A 骨架）→ 本次提交

---

## 0. 交付清单

| 交付物 | 位置 / 状态 |
| --- | --- |
| 源码 | 本仓库 `lib/` `test/` `tools/` `android/`（提交见 git log） |
| Release APK | `build/app/outputs/flutter-apk/app-release.apk`（现有 keystore 签名，未重新生成） |
| Debug APK | `build/app/outputs/flutter-apk/app-debug.apk` |
| 依赖说明 | §3 |
| 语音导航使用说明 | §4 |
| 权限与隐私说明 | §5 |
| 测试报告 | §6（Python 125 绿 / Flutter 105 绿 / analyze 0 错误） |
| 回归矩阵（10 项） | §7（逐项标注「代码级验证」/「需真机确认」） |
| 图标问题调查与修复 | §1 |
| 截图或如实说明 | §8（本环境无真机，如实说明） |
| 未解决问题与技术局限 | §9（不隐瞒） |

---

## 1. 图标问题：调查结论与修复（规范十一，必须项）

### 1.1 为什么官方图标一直没被用上（根因调查）

git 历史证据：

1. `dc16c8d`（阶段 0/1：可行性报告 + 高德 API 验证）——`icon/RunLoop.ico` 在这一提交进入仓库。**此时项目还没有 Flutter 工程**，没有任何 `android/` 目录，.ico 只是设计素材。
2. `99d270b`（阶段 3：安装工具链、创建项目）——`android/app/src/main/res/mipmap-*/ic_launcher.png` 由 **Flutter 模板脚手架生成**，内容是 Flutter 默认绿底图标。
3. 阶段 3 至今的所有构建中，`AndroidManifest.xml` 引用的是 `@mipmap/ic_launcher`（模板默认），**没有任何脚本或手工步骤把 `icon/RunLoop.ico` 转换进 `res/`**。Flutter 不会自动读取仓库根目录下的 `icon/` 文件夹（`flutter_launcher_icons` 之类的工具也从未引入）。

结论：这是一个「素材入库早于工程创建、工程创建时未接线」的集成遗漏，而非转换失败——.ico 从未参与过任何构建。

### 1.2 修复方式

新增 `tools/gen_icons.py`（Pillow，Python 3）：

- 从 `RunLoop.ico` 提取最高分辨率 256×256 帧作为唯一源图；
- 实测源图：黑色线条 + 橙色 `(240,96,0)` 主体，白色不透明背景，艺术内容 142×142 居中（bbox 57,57,199,199），圆形裁切安全（半对角 100.4 < 128）；
- **传统图标**：`mipmap-{mdpi…xxxhdpi}/ic_launcher.png`（48/72/96/144/192，LANCZOS 缩放）+ `ic_launcher_round.png`（4× 超采样圆形裁切）；
- **Adaptive Icon（Android 8+）**：`drawable-*dpi/ic_launcher_foreground.png`（108→432dp 画布，艺术内容缩至 66/108 安全区居中、外部透明）+ `drawable/ic_launcher_background.xml`（纯白 shape）+ `mipmap-anydpi-v26/ic_launcher{,_round}.xml`；
- **设计决策**：不提供 `monochrome` 层——前景 bbox 内含白色像素，单色化会渲染成实心方块，违背「保持原设计」的要求；
- Manifest 补 `android:roundIcon="@mipmap/ic_launcher_round"`；应用名保持「环跑」（`android:label` 原本即是）；Debug/Release 共用同一 `res/`，天然统一。

### 1.3 验证（APK 内容级，Debug 与 Release 均通过）

对构建产物逐项核对：

- Debug APK：全部 `res/mipmap-*`、`res/drawable-*dpi`、`mipmap-anydpi-v26` 条目按原名存在；
- Release APK：资源路径被混淆（正常优化），经 aapt2 资源表解析后**全部密度条目在位**（详见 §6.3）；
- 像素抽检：`ic_launcher.png` 四角为不透明白 `(255,255,255,255)`（我们的图标），**不是** Flutter 默认的绿色图标；round 版四角透明；foreground 四角 alpha=0，内容 bbox (84,84,348,348)＝264px 艺术区在 432px 画布居中——与设计一致；
- Manifest：`android:label="环跑"`、`icon`/`roundIcon` 引用在位。

---

## 2. 各模块实现要点

### A 语音导航（规范一/二）

- **TTS**：`flutter_tts 4.2.5`（系统 TTS，零付费 API）。评估记录见 `docs/voice_navigation_assessment.md`。
  - `setAudioAttributesForNavigation()` → `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE`：与音乐共存（音频焦点 + 音乐自动压低 ducking）、优先路由到蓝牙耳机/有线耳机/扬声器；
  - 播报文本全部来自**真实高德步行导航步骤**（`RouteStep.action/road/cumulativeM`），绝不依据地图箭头猜测；
  - 距离用**窗口化地图匹配后的沿路里程** `alongM`（Phase K 已设备验证的 `projectNear` + 0.5m tie-break + 120m 全局兜底）。
- **播报规则**（`lib/services/nav/nav_announcer.dart`，纯 Dart 状态机，50 个新测试中的 22 个覆盖它）：
  - 提前播报：默认距转弯 50m（可设 20–150m），「前方 50米右转进入中山路」；
  - 到位确认：越过触发线（cum−8m）时「现在右转」；
  - 近距连续转弯（下一步 ≤80m）合并为一条：「前方 50米右转进入A路，随后约 30米左转进入B路」，且两步各自仍有到位确认；
  - 直行只在**路名变化**时播「沿X路继续直行」，不重复刷「继续直行」；
  - 每步唯一 ID（`pre-{i}` / `now-{i}` / `end-{i}` 去重集合），GPS 回跳不重播；
  - 转弯播报用 flush 队列（打断旧语音），公里配速用 add 队列（不互相打断）；
  - 偏航：立即打断并播「已偏离规划路线，请返回蓝色路线」，偏航期间静默、自动标记已越过的步骤（回归后不补播旧指令），回归播「已回到规划路线」；
  - 暂停：立即 `stop()` 并静默；继续：重新武装下一条 pre（防暂停点恰在窗口内导致漏播）；结束：立即停止并清空；
  - 公里播报排队 + 15s 过期丢弃 + 转弯后 3s 静默期（转弯优先，绝无陈旧积压）。
- **缺中文语音引擎绝不静默失败**：`TtsService.diagnose()` 区分 `noEngine` / `languageNotInstalled` / `languageUnavailable`，设置页与跑步页横幅给出**明确的中文修复指引**（去系统设置装 Google/讯飞等 TTS 并下载中文语音包），此时跑步功能不受影响。
- **设置页**（首页齿轮进入）：语音导航开关、每公里配速开关、试听按钮、音量滑条、语速滑条、提前播报距离（30/50/80/100m 快捷选项），全部持久化（SharedPreferences），默认全开。
- **无麦克风权限**：Manifest 未申请 RECORD_AUDIO，TTS 只播不录。
- **后台/锁屏播报**：依赖前台服务（§FGS），进程存活即播报存活。

### B 每公里配速（规范三）

- `RunRecorder` 增强（复用现有类，未另起炉灶）：
  - 距离＝GpsFilter 过滤后的累计里程（跳点 >100m、精度 >50m 拒绝；漂移不累计）——GPS 丢失期间**不产生假分段**；
  - 1000m 边界**线性插值**：`frac=(boundary−prevDist)/stepDist`，同时插值高精度活动秒（毫秒级 `_activeSecondsNow()`），排除暂停时段；
  - `end()` 时剩余 ≥30m 记录**末段 partial split**（<50m 不给配速避免噪声放大）；
  - 新增可注入 `clock`，分段计时完全可测试。
- `KmSplit` 模型：JSON `i/d/s` 三键；`announcement()` →「第 N 公里完成，本公里配速 X 分 Y 秒」（整分为「X 分整」）。
- 持久化：`run_records.km_splits TEXT`（DB v3→v4，`ALTER TABLE` 迁移，旧记录解析为空列表向后兼容）。
- 展示：结束页 + **新增历史详情页**（`RunDetailScreen`，历史列表点击任意记录进入）：公里数 / 本公里用时 / 本公里配速表格，全部真实值；末段标注「（X.XX km）」。
- 播报：跑步中每过 1km 播「第 N 公里完成，本公里配速…」，**转弯优先、公里排队**（见 §A）。

### C 三秒环形倒计时（规范四）

- `lib/widgets/countdown_overlay.dart`：环形进度（顺时针消减圆弧）+ 居中大数字 3→2→1→**GO!**（绿色）；
- 每秒轻震动、GO 时中等震动（HapticFeedback，无新权限）；
- 「取消」按钮：GO 前可点 → `onCancelled` → 直接退出页面，**不产生任何记录**；GO 后禁用（防重复回调）；
- **计时起点＝GO 的准确时刻**：`RunRecorder.start()` 在 `onGo` 回调中调用，倒计时 3 秒绝不计入跑步时间；
- 快速退出：`dispose()` 释放 AnimationController，无残留定时器（widget 测试用 `pumpAndSettle` 验证无 pending timers）；
- 复用现有 `RunRecorder`，零侵入。

### D Heading-Up 地图（规范五，最重要）

- **方向源仲裁**（`lib/services/nav/heading_controller.dart`）——按规范 5.2 警告，**刻意不用磁力计/方向传感器**（跑步摆臂 + 手机姿态变化下磁航向不可靠，实测普遍抖动 ±30°）：
  1. GPS course（`LocationResult.bearing`，仅 `locationType==1` 时有效）：速度 ≥1.2 m/s 且精度 ≤40m 时采用；
  2. 路线切线方向（地图匹配点处 `RoutePath.bearing`）：速度 ≥0.4 m/s 时兜底（慢走/等灯时 GPS course 失效但人仍沿路线）；
  3. 两者皆无 → **冻结当前方向**（静止绝不旋转，规范 5.2#5）。
- 平滑：指数最短弧插值 `α=1−e^(−dt/τ)`，τ=0.8s；0°/360° 环绕用 `((to−from)%360+540)%360−180` 最短弧（350°→10° 走 +20° 而非 −340°，测试覆盖）；残差 <0.5° 直接吸附消除抖动。
- 相机：2D（tilt 恒 0，无 3D 倾斜）；heading-up 时地图 bearing=航向、跑者 marker 不旋转；north-up 时地图 bearing=0、marker 旋转=航向（含 >3m 轨迹方向兜底）。
- 防卡顿：相机死区（位移 <1.5m 且转角 <2° 不下发 moveCamera）；跟跑者居中；手动平移地图（相机目标距跑者 >40m）自动退出跟随 → 右下角出现「恢复跟随」按钮；AppBar 一键切换 heading-up / north-up（**默认 heading-up**；预览页仍 north-up）。

### E 已跑路线视觉融合（规范六）

- 规划路线数据层**保持独立**：已完成部分单独一条折线 `planned-done`（灰蓝 `0x9978909C`、2.4dp、z=8），压在未完成段（casing z=10 / core z=20）之下，与 GPS 轨迹（z=30/40）同色系不冲突；
- 未完成段用新增 `RoutePath.fromDistance(along)` 从匹配点**裁剪尾部**（与 `upTo` 共享插值端点，测试证明两段无缝衔接、无重叠丢失）；
- **匹配用的坐标与显示的坐标完全一致**——绝不为视觉效果偏移任何线（规范 6.2 铁律，Phase K 已验证的窗口匹配原样保留）；
- 折线 ID 稳定（`planned-done` / `planned-casing` / `planned-core` / `track-*`）→ AMap 插件原地增量更新，不重建图层；
- 真实偏离肉眼可见：GPS 轨迹独立绘制，偏航时灰蓝已完成段停止增长、橙色轨迹离开蓝色路线；
- 转弯标注（Phase J 的 annotations）原样保留。

### F 跑步页布局（规范七）

- **顶部**：下一步转向卡片（转向图标 + 距离大字 + 动作 + 「进入 XX路」）；偏航时替换为橙色偏航横幅；
- **中部**：导航地图（flex 3），公里完成 toast 轻量悬浮于地图底部中央 4 秒自动消失，不遮挡关键区域；
- **底部**（flex 2）：总距离 56px 大字 + 目标进度条 + 四指标（当前配速大字 / 平均配速 / 时长大字 / 剩余）+ 暂停·继续 / 结束按钮；
- 「剩余」＝规划路线总长 − 沿路里程（真实路径剩余，非直线距离）；
- 户外可读性：深色底 + 高对比大字（延续 Phase K 设计语言）。

### FGS 前台服务（规范 2.6 后台要求 / F#10）

- `flutter_foreground_task 11.0.3`：`serviceId 9101`、`ForegroundServiceTypes.location`、低优先级通知渠道（无声、常驻）；
- 通知：「环跑正在记录 · 定位、计时与语音导航运行中 · 点击返回应用」，点击回 App；
- GO 时刻启动（同时请求通知权限，Android 13+），结束时 `await stop()` 释放 WakeLock/通知/服务；
- Manifest 按插件要求手动声明 service（`foregroundServiceType="location"`，插件清单不自带）；
- `allowAutoRestart: false`——进程被杀**不**自动重启服务，杜绝「重复记录」风险（回归项 #10）；
- 定位链路（AMap SDK 后台定位）与语音（TTS 引擎在 App 进程内）均随前台服务存活 → 锁屏 GPS + 锁屏语音的 Android 14+ 合规基础。**仅前台运行方案不可接受**——本实现即为真后台方案。

---

## 3. 新增依赖说明

| 依赖 | 版本 | 用途 | 备注 |
| --- | --- | --- | --- |
| `flutter_tts` | ^4.2.5 | 系统 TTS 语音播报 | 零付费；AGP 9.1 兼容已验证（构建仅有无害的 Built-in Kotlin 提示）；Manifest 增加 `<queries>` TTS_SERVICE |
| `flutter_foreground_task` | ^11.0.3 | 前台服务（后台定位/计时/语音） | 需在 app Manifest 手动声明其 service（已做）；无新增第三方原生库冲突 |

未升级任何既有依赖（规范要求：升级前评估兼容性——flutter_tts 4.2.5 直接满足，无需动其他包）。`pubspec.lock` 仍被 .gitignore 排除（既有约定）。国内镜像 `pub.flutter-io.cn` 拉取正常。

---

## 4. 语音导航使用说明（用户向）

1. **首次使用**：首页右上角 ⚙ 进入「语音导航设置」。顶部诊断卡显示引擎状态：
   - 绿色「语音引擎正常」→ 可直接使用；
   - 橙色提示 → 按卡片上的中文指引操作（一般是：系统设置 → 无障碍/语言和输入法 → 文字转语音(TTS) → 安装 Google TTS 或讯飞语记等引擎，并**下载中文(zh-CN)语音包**）。装好后点「重新检测」。
2. **试听**：设置页「试听」按钮会播「语音测试：前方五十米右转，进入环城路」。听不到→检查媒体音量与引擎状态。
3. **开关与参数**：语音导航总开关、每公里配速播报开关、音量、语速、提前播报距离（默认 50m）。
4. **跑步中**：GO 后自动开始播报；与音乐 App 共存——播报瞬间音乐自动压低（ducking），播完恢复；蓝牙耳机优先。
5. **锁屏**：可以锁屏，前台通知「环跑正在记录」会常驻，GPS、计时、语音全部继续。结束跑步或杀进程后通知消失。
6. **偏航**：听到「已偏离规划路线」→ 看地图橙色横幅回到蓝色路线即可，语音会自动恢复且不会补播错过的转弯。

## 5. 权限与隐私说明

| 权限 | 状态 | 用途 |
| --- | --- | --- |
| ACCESS_FINE/COARSE_LOCATION、ACCESS_BACKGROUND_LOCATION、FOREGROUND_SERVICE(_LOCATION) | Phase K 已有 | 跑步定位 |
| POST_NOTIFICATIONS | Phase K 已有（FGS 通知需要，运行时请求已带 try/catch 降级） | 前台服务通知 |
| **RECORD_AUDIO（麦克风）** | **未申请**（规范 2.6 明确禁止） | TTS 只播不录 |
| 新增运行时权限 | **无** | 本期未引入任何新权限 |

隐私：语音全部由**设备本地系统 TTS 合成**，无音频上传；公里分段仅存本机 SQLite；无新增网络端点（后端仍是 Phase K 的 Tailscale Serve 私有链路）。

## 6. 测试报告

### 6.1 自动化测试（本机全绿）

| 套件 | 结果 |
| --- | --- |
| Python 后端 `pytest tests` | **125 passed**（Phase K 原样，未破坏） |
| Flutter `flutter test` | **105 passed**（原 55 + 新增 50） |
| `flutter analyze lib test` | **0 error / 0 warning**（仅 1 条 Phase K 有意保留的 info：route_api_service.dart `use_null_aware_elements`）；vendored `packages/amap_flutter_base` 的告警为插件自带、非本期代码 |

### 6.2 新增 50 个测试的分布

| 文件 | 数量 | 覆盖 |
| --- | --- | --- |
| `test/nav_announcer_test.dart` | 16 | 提前/到位/合并播报、直行抑制、终点、偏航全流程、暂停继续结束、开关、公里排队/过期/静默期、KmSplit 模型 JSON/文案 |
| `test/km_split_test.dart` | 8 | 1000m 边界插值精度、暂停时间剔除、跳点过滤、GPS 丢失不造假分段、末段 partial、DB JSON 往返、旧记录兼容、bearing 门控（locationType≠1 丢弃） |
| `test/heading_controller_test.dart` | 10 | 方向源仲裁（GPS 优先/路线兜底/冻结/精度门控）、最短弧 350→10、指数收敛+吸附、归一化、dt≤0、reset、非法 bearing |
| `test/countdown_overlay_test.dart` | 4 | 3→2→1→GO 时序、onGo 时刻、取消不触发 onGo（含 GO 后禁用）、快速退出无残留定时器 |
| `test/route_path_split_test.dart` | 6 | upTo/fromDistance 互补衔接、边界 clamp、空/单点路线 |
| `test/nav_settings_test.dart` | 3 | 默认值、持久化往返、非法输入 clamp |

### 6.3 构建产物

| 产物 | 命令 | 结果 |
| --- | --- | --- |
| Release APK | `flutter build apk --release --dart-define=TAILNET_BASE_URL=https://your-device.your-tailnet.ts.net --dart-define=AMAP_ANDROID_KEY=…` | √ Built `app-release.apk`（**74.6 MB**，现有 keystore 签名，Gradle 108.7s） |
| Debug APK | `flutter build apk --debug --dart-define=AMAP_ANDROID_KEY=…` | √ Built `app-debug.apk`（189 MB，Gradle 18.7s） |

Release APK 内容级核验（aapt2 资源表 + 像素抽检）：

- `mipmap/ic_launcher`、`ic_launcher_round` 全 5 密度 + `anydpi-v26` XML、`drawable/ic_launcher_foreground` 全 5 密度、`ic_launcher_background` XML 均在资源表中（release 资源路径被混淆为短名，属正常优化）；
- 像素抽检 `ic_launcher@xxxhdpi`：四角 `(255,255,255,255)` 不透明白＝官方图标（非 Flutter 默认）；round 版四角透明；foreground 432px 内容区 bbox (84,84,348,348)＝264px 艺术区精确居中；
- 合并清单：`ForegroundService` 已声明且 `foregroundServiceType=0x8`（**location**）、`exported=false`；`android:label="环跑"`；`icon`/`roundIcon` 引用在位；`TTS_SERVICE` queries 在位；**无 RECORD_AUDIO**。

## 7. 回归矩阵（规范 8.3 十项）

| # | 场景 | 验证方式 | 状态 |
| --- | --- | --- | --- |
| 1 | GPS 漂移不误报偏航 | GpsFilter（acc>50/jump>100 拒绝）+ 120m 偏航阈值 + 窗口匹配 tie-break；`gps_filter_test` / `km_split_test` 跳点用例 | ✅ 代码级验证（Phase K 已真机通过，逻辑未变） |
| 2 | 偏航回归后地图不跳变 | 匹配 hint 机制原样保留；相机死区 1.5m/2° | ✅ 代码级验证 ⚠️ 建议真机复测 |
| 3 | 折返/重叠路段进度不错腿 | 窗口化 `projectNear`（±250m hint）Phase K 真机验证，本期未改动 | ✅ 沿用已验证逻辑 |
| 4 | 暂停即停语音与计时 | `onPause()` 先 `tts.stop()` 再 `recorder.pause()`；分段测试证明暂停 900s 不计入 | ✅ 测试覆盖 |
| 5 | 继续后恢复播报 | `onResume(alongM)` 重新武装下一条 pre；测试覆盖 | ✅ 测试覆盖 |
| 6 | 锁屏后 GPS 持续 | FGS(location) + AMap 后台定位（Phase K 已真机验证锁屏轨迹） | ⚠️ 需真机确认（新 FGS 通道） |
| 7 | 锁屏后语音持续 | TTS 在 App 进程内，FGS 保活；音频属性 NAVIGATION | ⚠️ 需真机确认 |
| 8 | 耳机拔出表现 | 音频焦点由系统管理（USAGE_ASSISTANCE_NAVIGATION_GUIDANCE）；本 App 无音频播放中断逻辑需要 | ⚠️ 需真机确认（预期：TTS 自动切扬声器，系统行为） |
| 9 | 结束释放全部资源 | `_end()`: announcer.onEnd(stop) → await FGS.stop() → recorder.end() → dispose 链（tts.dispose/controller/timers）；倒计时 dispose 测试无残留 | ✅ 代码级验证 ⚠️ 通知消失需真机看一眼 |
| 10 | 进程回收不产生重复记录 | `allowAutoRestart:false`（不自启服务）；记录仅在用户点「结束」时写库；DB v4 迁移幂等 | ✅ 代码级验证 ⚠️ 建议真机「最近任务划掉」复测 |

**如实声明**：标注 ⚠️ 的 5 项依赖真实 Android 运行时行为，本开发环境（Windows，无连接设备）无法执行真机场景，已全部做成自动化可验证的部分并在上表注明剩余风险点。安装 `app-release.apk` 后建议按上表 ⚠️ 项过一遍（约 15 分钟）。

## 8. 截图说明（如实）

本环境无法启动 Android 模拟器或连接真机（无 ADB 设备），**无法提供运行截图**。已提供的替代证据：APK 内图标像素级抽检（§1.3，脚本可复现）、105 个自动化测试、`flutter analyze` 零错误零告警。Phase K 的真机验证（路线生成/移动数据/Tailscale 后端）由用户在设备上确认通过。

## 9. 未解决问题与技术局限（不隐瞒）

1. **真机回归 5 项待确认**（§7 ⚠️）：锁屏 GPS/语音、耳机拔出、通知消失、进程回收——代码路径已按 Android 14+ FGS 规范实现，但系统级行为只能真机确认。
2. **Adaptive 图标前景为 256px 源图放大**：432px(xxxhdpi) 前景由 256px 帧 LANCZOS 上采样约 1.7×，在最新旗舰机 120Hz 大屏上极限放大可能略软；传统 mipmap（最大 192px）为缩小采样，锐利。若有矢量源文件（SVG/AI）可一键重新生成更锐利的 adaptive 前景（`tools/gen_icons.py` 参数化预留）。
3. **磁力计刻意未用**（规范 5.2 授权的选择）：静止看地图时方向冻结在最后可信航向，不随手机转动——这是「跑步不抖」优先的取舍；如需静止时罗盘转向可后续加开关。
4. **TTS 引擎质量因机而异**：国产 ROM 若无中文 TTS 引擎，设置页会给出安装指引（Google TTS / 讯飞语记），但无法替用户安装；部分 ROM 省电策略可能杀前台服务——通知常驻 + WakeLock 已尽力，若出现请将该 App 加入电池白名单。
5. **公里 toast 4 秒**：与语音播报冗余设计，若嫌打扰可关「每公里配速播报」开关（toast 与语音同开关）。
6. **iOS**：本期仅 Android（与 Phase K 范围一致）；flutter_tts / FGS 的 iOS 分支代码已留（IOSNotificationOptions），未验证。
