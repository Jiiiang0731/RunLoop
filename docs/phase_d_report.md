# 阶段 D 报告：自定义里程与自动环线规划接入

## 1. 结论

- 后端路线 API（Flask）已封装现有 `backend/route_generator`，用固定坐标验证通过；
- Flutter 端已实现：目标距离输入（5/10/15/20 快捷 + 自定义）、生成闭环路线、候选路线地图展示（真实折线）、切换/选择/重新生成、所选路线接入运动记录（保存规划路线 + 实际轨迹）；
- **蔡甸区 15km 校准问题已修复**：新增「角度精修」（旋转环骨架跨过距离断层），回归测试 5/10/15/20km 共 8 条候选**全部满足 ±500m**，闭合误差均为 0.56m。

## 2. 修改文件清单

### 后端
- `backend/server.py`（新增）：Flask API，`GET /api/health`、`POST /api/route/generate`；Key 仅在后端读取。
- `backend/route_generator/calibrator.py`（改）：主循环后增加角度精修（`_REFINE_ANGLES`）。

### Flutter
- `lib/app/config.dart`：新增 `routeApiBaseUrl`（可 `--dart-define` 覆盖）。
- `lib/models/planned_route.dart`（新增）：候选路线模型 + 评分维度。
- `lib/services/route_api/route_api_service.dart`（新增）：调用后端、超时/错误处理。
- `lib/screens/home_screen.dart`：目标距离输入 + 生成按钮 + 加载/错误提示。
- `lib/screens/route_candidates_screen.dart`（新增）：地图绘制真实折线、候选卡片、切换/选择/重新生成。
- `lib/screens/run_screen.dart`：显示所选路线 + 当前位置，衔接运动记录。
- `lib/screens/run_summary_screen.dart`：保存规划路线。
- `lib/models/run_record.dart` / `lib/services/storage/database.dart`：新增 `planned_route` 字段与数据库 v2 迁移。
- `pubspec.yaml`：新增 `http`。

## 3. 后端启动命令

```bash
# 在项目根目录运行（默认监听 0.0.0.0:8000）
python backend/server.py
# 或指定端口/地址
set RUNLOOP_PORT=8001 && python backend/server.py
```

- 依赖：Flask（已安装）。Key 从 `config/amap_key.local` 读取，**不进 APK、不入库**。
- 本机 WLAN IP：`192.168.1.100`（手机同一 Wi-Fi 时访问 `http://192.168.1.100:8000`）。

### 如何查询电脑局域网 IP（Windows）

```powershell
ipconfig | findstr /i "IPv4"
# 或
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' }
```

## 4. 手机配置 BASE_URL 的方法

APK 中的默认后端地址为 `http://192.168.1.100:8000`（构建时注入）。若电脑 IP 变化，构建时覆盖：

```bash
flutter build apk --debug \
  --dart-define=AMAP_ANDROID_KEY=<你的AndroidKey> \
  --dart-define=ROUTE_API_BASE_URL=http://<你的电脑局域网IP>:8000
```

后续部署公网 HTTPS 后端时，仅需把 `ROUTE_API_BASE_URL` 换成公网地址重新构建即可，无需改代码。

## 5. 实际 API 请求与返回（示例）

请求：
```http
POST http://192.168.1.100:8000/api/route/generate
Content-Type: application/json

{"origin":{"lng":114.087279,"lat":30.536395},"target_m":15000,"tol_m":500,"seeds":[1,2,3],"points":10}
```

返回（节选）：
```json
{
  "success": true,
  "origin": {"lng": 114.087279, "lat": 30.536395},
  "target_m": 15000,
  "tol_m": 500,
  "total_api_calls": 308,
  "elapsed_s": 109.7,
  "candidates": [
    {"seed":1,"ok":true,"distance_m":14742.0,"error_m":-258.0,"closure_m":0.56,
     "score":74.4,"polyline":[[114.08,30.53],...]},
    {"seed":2,"ok":true,"distance_m":15096.0,"error_m":96.0,"closure_m":0.56,"score":77.6,"polyline":[...]},
    {"seed":3,"ok":true,"distance_m":14964.0,"error_m":-36.0,"closure_m":0.56,"score":76.2,"polyline":[...]}
  ]
}
```

## 6. 蔡甸区固定坐标测试表（114.087279, 30.536395, GCJ-02）

改进前（仅 R 缩放）：15km 三条 15615/13937/15617，均未达标。
改进后（R 缩放 + 角度精修）：

| 目标 | 种子 | 实际距离 | 误差 | 闭合误差 | 评分 | 生成耗时 |
| --- | --- | --- | --- | --- | --- | --- |
| 5km | 1 | 5092m | +92m ✓ | 0.56m | 66.7 | 48.4s（2 候选） |
| 5km | 2 | 5098m | +98m ✓ | 0.56m | 71.3 | |
| 10km | 1 | 9989m | −11m ✓ | 0.56m | 67.3 | 42.0s（2 候选） |
| 10km | 2 | 10366m | +366m ✓ | 0.56m | 74.5 | |
| 15km | 1 | 14742m | −258m ✓ | 0.56m | 74.4 | 67.1s（2 候选）/ 109.7s（3 候选） |
| 15km | 2 | 15096m | +96m ✓ | 0.56m | 77.6 | |
| 15km | 3 | 14964m | −36m ✓ | 0.56m | 76.2 | |
| 20km | 1 | 20350m | +350m ✓ | 0.56m | 70.4 | 40.9s（2 候选） |
| 20km | 2 | 20052m | +52m ✓ | 0.56m | 67.8 | |

> 说明：生成时间取决于候选数量与路网复杂度（2 候选约 40-67s，3 候选约 100-110s）。目标是 10s 内，实际受高德 API 延迟与校准迭代限制，未达 10s；优化方向：并行调用分段、减少候选数、缓存。

## 7. 新 APK 路径

- `dist/RunLoop-环跑-Android-debug.apk`（189 MB，含路线功能，默认后端 `http://192.168.1.100:8000`）
- `dist/RunLoop-环跑-Android.apk`（72.8 MB，正式版）

## 8. 尚未通过真机验证的内容

- 手机端未连 ADB，**未实测**：目标距离输入 → 生成 → 候选路线地图显示 → 选择 → 开始跑步 → 保存规划路线 + 轨迹 的完整链路；
- 需要手机与电脑同一 Wi-Fi、后端运行中，才能完成上述验证；
- 公网 HTTPS 部署未做（仅设计为可配置）。
