# RunLoop 技术架构与模块设计

## 1. 总体架构

```
┌─────────────────────────────────────────────┐
│ Flutter 客户端（Android 优先）               │
│  screens/ widgets/ models/                  │
│  services:                                  │
│   location      定位（WGS-84→GCJ-02）        │
│   map_provider  地图与路径服务接口(可替换)      │
│   route_generator 环线生成与距离校准(核心)      │
│   navigation    导航与偏航检测                │
│   run_recorder  GPS 运动记录(前台服务)         │
│   storage       本地持久化(SQLite)            │
│   stats         跑量统计                      │
└──────────────┬──────────────────────────────┘
               │ HTTP（v1 直连；可切后端代理）
        ┌──────▼────────┐
        │ 高德 Web 服务   │  地理编码 / 步行路径规划 / 坐标转换
        │ （GCJ-02）      │
        └───────────────┘
```

## 2. 关键架构决策

1. **环线生成放端内（Dart 移植）**：算法本身只做「控制点 + 调用步行规划 + R 缩放迭代」，无重计算，可端内运行，避免个人用户自建服务器。
   - 依据：阶段 1 已用 Python 验证算法（单候选 5–11s、11–33 次调用），Dart 移植等价。
   - Python 版保留为**算法参考实现与测试基准**（`backend/`），后续可选 FastAPI 化供多用户。
2. **密钥管理**：Web 服务 Key 属私密凭证，**不硬编码**。v1 通过 `--dart-define=AMAP_WEB_KEY=...` 构建注入；分发场景改用后端代理。本地密钥文件 `config/amap_key.local` 已 gitignore。
3. **地图渲染**：优先 `amap_flutter_map`（官方 Flutter 地图 SDK），需**另一枚 Android 端 SDK Key**（绑定包名 + SHA1，见 README）。地图服务封装为 `map_provider` 接口，便于替换。
4. **本地存储**：`sqflite`（SQLite），保存运动记录/设置，重启不丢。
5. **后台定位**：`flutter_background_geolocation` + 前台服务，见可行性报告 §6。

## 3. 数据模型（初版）

`RunRecord`（运动记录）：
- `id`, `startTime`, `endTime`, `durationSec`, `movingSec`
- `distanceM`（累计真实跑距）, `avgPaceSecPerKm`
- `trackPoints`（JSON：`[ {lat,lng(GCJ-02), wgsLat,wgsLng, accuracyM, timestamp} ]`）
- `rpe`（1–10 主观疲劳）, `note`
- `routeId`（关联规划路线，可空）
- `pauseCount`, `maxSpeed`, `calories`（可选）

`PlannedRoute`（规划路线，可收藏）：
- `id`, `targetM`, `actualM`, `errorM`, `closureM`
- `startLat/startLng`（GCJ-02）, `polyline`（JSON）, `segments`, `score`, `seed`, `createdAt`

`UserSettings`：距离容差、起点搜索半径、路线偏好等（键值表）。

统计（`stats` 服务）一律从 `RunRecord` 实时计算：今日/本周/本月/累计跑量、最长单次、平均配速趋势、LSD 次数。周起始日可配置，正确处理时区与删除后重算。

## 4. 模块职责边界

- `route_generator`：纯 Dart，输入（起点、目标距离、偏好、seed）→ 输出候选路线；不依赖 UI。
- `map_provider`：抽象接口 `MapProvider { planWalking(a,b); geocode(); convert(); render(); }`，高德为唯一实现，未来可插 OSM。
- `navigation`：路线匹配、最近点投影、下一转向点、偏航检测（偏离 50m 且持续 N 秒才提示）。
- `run_recorder`：GPS 采集、滤波、距离累加、暂停/继续/结束、前台服务生命周期。
- `stats`：纯函数式统计，单测覆盖（跨日/时区/删除）。

## 5. 目录结构（已在仓库建立骨架）

```
runloop-app/                 # 本仓库根目录（即项目根）
├── assets/app_icon/         # 图标资源（预留，已含 .gitkeep）
├── backend/                 # 路线算法 Python 参考实现 + 验证脚本 + 输出
├── config/amap_key.local    # 本地密钥（gitignore，不入库）
├── docs/                    # 需求/架构/地图调研/测试报告
├── lib/                     # Flutter 源码（app/screens/widgets/models/services/*）
├── tests/                   # Dart/Python 单元测试
├── dist/                    # 最终 APK（预留）
├── .env.example             # 密钥配置模板
├── .gitignore
└── README.md
```

## 6. 密钥配置与图标更新（要点）

- Web 服务 Key：`config/amap_key.local`（本地）/ `--dart-define`（构建注入），禁止入库。
- Android 地图 SDK Key：阶段 3 前需用户在高德控制台创建（绑定包名 `com.runloop.app` + 调试/发布 SHA1），写入 `android/app/src/main/AndroidManifest.xml` 与 `android/key.properties`（gitignore）。
- 图标：`icon/RunLoop.ico` 已存在 → 阶段 6 转 PNG + 自适应图标；替换 `assets/app_icon/` 后重跑 `flutter_launcher_icons` 再构建。
