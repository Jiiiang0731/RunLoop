# RunLoop 项目结构与修改指南

本文件说明 RunLoop 的目录设计、源码边界、构建产物边界，以及“想改某个功能应该去哪里”。

项目根目录必须是包含 `pubspec.yaml` 的目录：

`<project-root>`（本机示例：`D:\path\to\RunLoop-app`）

不要把 `build/`、`.dart_tool/` 或 `dist/` 当作项目根目录。

---

## 一、顶层目录树

```text
RunLoop-app/
├── lib/                         Flutter 应用源码（核心）
├── backend/                     Python 后端与路线算法（核心）
├── android/                     Android 原生工程（核心）
├── test/                        Flutter 自动化测试（核心）
├── tests/                       Python 自动化测试（核心）
├── packages/                    本地修补的高德 Flutter 插件（构建必需）
├── assets/                      应用图标与资源
├── config/                      后端 Key 模板与本地配置
├── deploy/                      Windows 后端 / Tailscale / 开机脚本
├── tools/                       诊断、回归、图标生成等辅助脚本
├── docs/                        架构、阶段报告、演示与开发文档
├── pubspec.yaml                 Flutter 依赖
├── pubspec.lock                 Flutter 锁定版本（应用项目建议提交）
├── analysis_options.yaml        Dart 静态分析配置
├── requirements.txt             Python 运行时依赖
├── requirements-dev.txt         Python 测试依赖
├── README.md                    中文说明
├── README.en.md                 英文说明
├── LICENSE                      MIT License
├── DISCLAIMER.md                中英文免责声明
├── .env.example                 Web Key 环境变量模板
├── .gitignore                   Git 排除规则
├── build/                       自动生成，不手改，不入 Git
├── .dart_tool/                  自动生成，不手改，不入 Git
├── .idea/                       IDE 本地配置，不入 Git
├── dist/                        本地交付物（APK / PPT / 归档）
└── .git/                        Git 历史
```

---

## 二、核心源码在哪里

### 1. Flutter 应用

| 路径 | 作用 |
|---|---|
| `lib/main.dart` | 应用入口、主题、路由 |
| `lib/app/config.dart` | 后端地址、高德 Android Key、偏航阈值、超时 |
| `lib/models/planned_route.dart` | 路线、步骤、TurnEvent、重复路段模型 |
| `lib/models/run_record.dart` | 跑步记录模型 |
| `lib/models/track_point.dart` | 单个 GPS 点（经纬度、精度、速度、方向） |
| `lib/models/km_split.dart` | 公里分段与配速 |
| `lib/models/location_result.dart` | 高德定位回调解析 |

### 2. 页面

| 路径 | 作用 |
|---|---|
| `lib/screens/home_screen.dart` | 首页、距离选择、权限申请、历史/设置入口 |
| `lib/screens/route_candidates_screen.dart` | 候选路线列表、地图预览、路线选择 |
| `lib/screens/run_screen.dart` | 跑步导航、GPS 进度、偏航、重规划、语音、暂停/结束 |
| `lib/screens/run_summary_screen.dart` | 跑步总结 |
| `lib/screens/history_screen.dart` | 历史记录 |
| `lib/screens/run_detail_screen.dart` | 单次跑步详情 |
| `lib/screens/settings_screen.dart` | 设置 |
| `lib/screens/voice_diagnostics_screen.dart` | 语音引擎诊断、锁屏语音自检 |
| `lib/screens/location_diagnostics_screen.dart` | 定位诊断 |
| `lib/screens/consent_screen.dart` | 隐私同意 |

### 3. 服务层

| 路径 | 作用 |
|---|---|
| `lib/services/route_api/route_api_service.dart` | 路线生成 API 客户端 |
| `lib/services/route_api/reroute_api.dart` | 偏航重规划 API 客户端与响应模型 |
| `lib/services/location/location_service.dart` | 高德持续定位封装 |
| `lib/services/run_recorder/run_recorder.dart` | GPS 轨迹、距离、配速、公里分段 |
| `lib/services/run_recorder/gps_filter.dart` | 漂移/跳点过滤 |
| `lib/services/nav/nav_announcer.dart` | 转弯/公里/目标播报状态机 |
| `lib/services/nav/tts_service.dart` | 系统 TTS 单例、队列、看门狗 |
| `lib/services/nav/tts_diagnostics.dart` | 原生 TTS 诊断通道 |
| `lib/services/nav/nav_state.dart` | 偏航状态机 |
| `lib/services/nav/heading_controller.dart` | GPS/路线切线/磁力计方向仲裁 |
| `lib/services/nav/follow_camera.dart` | 20Hz 相机平滑跟随 |
| `lib/services/nav/foreground_run_service.dart` | Android 前台服务与 WakeLock |
| `lib/services/nav/voice_log.dart` | 语音执行日志与心跳 |
| `lib/services/nav/compass_source.dart` | 磁力计封装 |
| `lib/services/nav/nav_settings.dart` | 语音/地图设置 |

### 4. 工具与组件

| 路径 | 作用 |
|---|---|
| `lib/utils/geo.dart` | 距离、方位角、坐标转换 |
| `lib/utils/route_path.dart` | 折线累计距离、投影、窗口化匹配 |
| `lib/utils/turn_annotations.dart` | 去/返程视觉标注、方向箭头布点 |
| `lib/utils/map_icons.dart` | 起点/位置/转弯图标生成 |
| `lib/utils/dual_track.dart` | 去/返程并排双轨视觉 |
| `lib/utils/route_style.dart` | 路线颜色、线宽、层级 |
| `lib/utils/heading_estimate.dart` | 最近 GPS 轨迹方向估计 |
| `lib/widgets/runner_arrow.dart` | 屏幕固定方向箭头 |
| `lib/widgets/countdown_overlay.dart` | 3-2-1 倒计时 |
| `lib/widgets/km_splits_table.dart` | 公里分段表 |
| `lib/widgets/end_run_dialog.dart` | 结束二次确认弹窗 |

### 5. Python 后端

| 路径 | 作用 |
|---|---|
| `backend/serve.py` | Waitress 生产入口 |
| `backend/server.py` | Flask 路由、序列化、限流、健康检查 |
| `backend/guard.py` | 每设备限流、并发闸、熔断、日志脱敏 |
| `backend/reroute.py` | 动态偏航与前向重规划 |
| `backend/route_generator/generator.py` | 候选生成顶层编排 |
| `backend/route_generator/calibrator.py` | 距离校准、变体早停、绕行修复 |
| `backend/route_generator/planner.py` | 高德 API、缓存、QPS 限速、重试 |
| `backend/route_generator/control_points.py` | 控制点骨架生成 |
| `backend/route_generator/variants.py` | 短/长距离骨架变体 |
| `backend/route_generator/loop_builder.py` | 分段真实规划与闭环拼接 |
| `backend/route_generator/scorer.py` | 候选评分 |
| `backend/route_generator/nav_metrics.py` | 转弯/直行/重复/接缝指标 |
| `backend/route_generator/nav_text.py` | 导航文字生成与安全合并 |
| `backend/route_generator/turn_events.py` | 统一 TurnEvent 模型 |
| `backend/route_generator/anchor_loop.py` | 锚点闭环模式 |
| `backend/route_generator/spur_fix.py` | 无效绕行修复 |
| `backend/route_generator/overlap.py` | 去/返程重叠检测 |
| `backend/route_generator/quality.py` | walk_type、连续性、数据缺口 |
| `backend/route_generator/geo.py` | 几何、坐标、保形简化 |
| `backend/route_generator/types.py` | 数据类 |
| `backend/route_generator/sampling.py` | 沿途 POI 采样 |
| `backend/route_generator/planner.py` | 含共享缓存与全局限速 |

### 6. Android 原生

| 路径 | 作用 |
|---|---|
| `android/app/src/main/AndroidManifest.xml` | 权限、前台服务、高德 Key 占位符、Activity |
| `android/app/build.gradle.kts` | applicationId、签名、AMap Key 注入、构建类型 |
| `android/settings.gradle.kts` | Gradle 插件版本 |
| `android/gradle/wrapper/gradle-wrapper.properties` | Gradle 版本与镜像 |
| `android/app/src/main/kotlin/com/runloop/app/MainActivity.kt` | Flutter Activity、原生诊断通道注册 |
| `android/app/src/main/kotlin/com/runloop/app/TtsDiag.kt` | TTS 引擎枚举、探测、真实朗读测试、设置页跳转 |
| `android/amap_key.properties` | 本地 Android Key（不入库） |
| `android/key.properties` | 本地 Release 签名配置（不入库） |

### 7. 测试

| 路径 | 内容 |
|---|---|
| `test/` | Flutter 单元/组件测试（路线、方向、播报、记录、结束确认等） |
| `tests/` | Python 后端测试（路线算法、缓存、评分、重规划、API 契约） |

---

## 三、我要修改某个功能，去哪里

### 1. 修改 App 首页 / 距离选择

- 页面：`lib/screens/home_screen.dart`
- 目标距离与候选数据：`lib/services/route_api/route_api_service.dart`
- 后端地址与阈值：`lib/app/config.dart`
- 距离预设/校验：首页状态与 `RouteApiService.generate` 参数。

### 2. 修改路线生成算法

- 总编排：`backend/route_generator/generator.py`
- 控制点：`backend/route_generator/control_points.py`、`variants.py`
- 距离校准/早停：`backend/route_generator/calibrator.py`
- 真实道路请求/缓存/限速：`backend/route_generator/planner.py`
- 评分：`backend/route_generator/scorer.py`
- 转弯/质量指标：`backend/route_generator/nav_metrics.py`
- 锚点模式：`backend/route_generator/anchor_loop.py`

### 3. 修改动态偏航 / 前向重规划

后端：

- `backend/reroute.py`：前向接回点、方向校验、剩余距离、替代路线、错误码；
- `backend/server.py`：`/api/route/reroute` 请求/响应字段；
- `backend/route_generator/planner.py`：重规划使用的真实步行请求。

Flutter：

- `lib/services/route_api/reroute_api.dart`：请求字段与响应模型；
- `lib/screens/run_screen.dart`：`_tryReroute`、`_applyReroute`、`_rebaseSteps`；
- `lib/services/nav/nav_state.dart`：偏航状态机；
- `lib/utils/heading_estimate.dart`：最近 GPS 方向估计；
- `lib/services/nav/nav_announcer.dart`：新路线播报重建。

### 4. 修改地图 / 导航路线绘制

- 跑步页地图与覆盖物：`lib/screens/run_screen.dart`
- 候选页地图预览：`lib/screens/route_candidates_screen.dart`
- 路线投影/切片：`lib/utils/route_path.dart`
- 方向箭头与转弯标注：`lib/utils/turn_annotations.dart`
- 图标：`lib/utils/map_icons.dart`
- 去/返程双轨：`lib/utils/dual_track.dart`
- 颜色/线宽/层级：`lib/utils/route_style.dart`

### 5. 修改语音播报

- 播报状态机：`lib/services/nav/nav_announcer.dart`
- TTS 单例/队列/看门狗：`lib/services/nav/tts_service.dart`
- 原生诊断：`lib/services/nav/tts_diagnostics.dart` + `android/app/src/main/kotlin/com/runloop/app/TtsDiag.kt`
- 语音设置：`lib/services/nav/nav_settings.dart`
- 诊断页：`lib/screens/voice_diagnostics_screen.dart`
- 前台保活：`lib/services/nav/foreground_run_service.dart`

### 6. 修改 Android 权限 / 后台服务

- 权限与 service 声明：`android/app/src/main/AndroidManifest.xml`
- 前台服务类型、签名、AMap Key 注入：`android/app/build.gradle.kts`
- Activity 与原生通道：`android/app/src/main/kotlin/com/runloop/app/MainActivity.kt`
- Flutter 侧前台服务：`lib/services/nav/foreground_run_service.dart`

### 7. 修改高德 Key / 后端地址

- Android SDK Key：`android/amap_key.properties`（本地）+ 构建参数 `--dart-define=AMAP_ANDROID_KEY=...`
- Web Service Key：`config/amap_key.local` 或 `RUNLOOP_AMAP_KEY`
- 后端地址：`lib/app/config.dart` 的 `TAILNET_BASE_URL` / `LAN_BASE_URL` / `ROUTE_API_BASE_URL`
- 签名：`android/key.properties`（本地）

### 8. 运行测试

```bash
# Flutter
flutter test
flutter analyze lib test

# Python
python -m pytest -q
```

---

## 四、源码、构建产物与本地文件边界

### 必须提交到 Git

- `lib/`、`backend/`、`android/` 源码；
- `test/`、`tests/`；
- `packages/` 本地高德插件补丁；
- `assets/`；
- `config/*.example`、`.env.example`、`android/*.example`；
- `docs/`、README、README.en.md、LICENSE、DISCLAIMER；
- `pubspec.yaml`、`pubspec.lock`、`requirements*.txt`、`analysis_options.yaml`、`.gitignore`；
- `deploy/` 脚本（不含真实地址/口令）。

### 自动生成，不入 Git

- `build/`；
- `.dart_tool/`；
- `.idea/`、`.vscode/`；
- `.pytest_cache/`、`__pycache__/`、`*.pyc`；
- `_build_*.log`；
- `.flutter-plugins*`；
- `android/.gradle/`、`android/local.properties`；
- `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`。

### 本地私有，绝不入 Git

- `config/amap_key.local`；
- `android/amap_key.properties`；
- `android/key.properties`；
- `android/keystore/*.jks`、`*.keystore`；
- `.env`；
- 包含真实 Tailnet 地址、账号、个人 GPS 轨迹的日志/截图/PPT；
- 签名证书与密码。

### 本地交付物

- `dist/final/`：最终 PPTX、PDF、APK 等，按隐私审查决定是否公开；
- `dist/phase_q/`：当前阶段 APK（本地）；
- `dist/archive/`：旧 APK、旧 PPT、旧日志归档；
- `dist/phase_p/`：用户编辑的 PPT 原始版本，保留，不覆盖。

> `dist/` 中的 APK、PPT、PDF 默认不作为公开源码提交；GitHub 仓库以源码、文档和必要的小型资源为主。

---

## 五、修改后的标准流程

```text
修改源码
  → python -m pytest -q
  → flutter test
  → flutter analyze lib test
  → 真实设备/真实 API 验证（如涉及）
  → 更新阶段报告或文档
  → 检查 git diff 与敏感信息
  → 提交可读的 commit
```

### 重新生成 APK

```bash
flutter build apk --debug \
  --dart-define=TAILNET_BASE_URL=https://your-device.your-tailnet.ts.net \
  --dart-define=AMAP_ANDROID_KEY=YOUR_ANDROID_SDK_KEY

flutter build apk --release \
  --dart-define=TAILNET_BASE_URL=https://your-device.your-tailnet.ts.net \
  --dart-define=AMAP_ANDROID_KEY=YOUR_ANDROID_SDK_KEY
```

产物在 `build/app/outputs/flutter-apk/`。

### 提交前检查

```bash
git status
git diff --stat
git diff
```

不要使用 `git add .` 直接提交；逐项确认没有 Key、证书、个人地址、个人轨迹或大型构建产物。
