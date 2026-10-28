# RunLoop（环跑）

面向马拉松训练者的跑步 App：输入目标距离，自动生成一条尽可能接近目标距离、起终点闭合、尽量适合跑步的环形路线，并提供预览、导航、GPS 运动记录与历史统计。

> 项目展示名：**环跑** ｜ 英文名：**RunLoop**

## 当前进度

- ✅ 阶段 0：技术可行性报告 → `docs/feasibility.md`
- ✅ 阶段 1：15km 闭合环线最小验证 → `docs/test_report.md`（3 候选，误差 +274/−322/+185m，闭合 0.7m）
- ✅ 阶段 2：算法封装 + 路线评分 + 单元测试（25 用例通过）→ `backend/route_generator/`
- ✅ 阶段 3：环境安装（Flutter/Android SDK/JDK17）+ 项目创建 + APK 构建（debug/release）→ `dist/`
- ✅ 阶段 4（地图）：高德地图 SDK 接入 + 定位 + APK 构建（含原生库）→ `docs/phase4_map_report.md`
- ⏳ 阶段 4（GPS）：跑步记录/锁屏后台/总结（代码已就绪，待真机验证）

## 目录结构

```
runloop-app/
├── assets/app_icon/         # 应用图标（预留，替换后重建）
├── backend/                 # 路线算法 Python 参考实现 + 验证脚本
│   ├── verify_amap.py       #   高德 API 能力验证
│   ├── loop_gen.py          #   15km 闭环生成验证
│   └── out/                 #   验证结果 JSON
├── config/amap_key.local    # 本地密钥（gitignore，不入库）
├── docs/                    # 需求/可行性/架构/地图调研/测试报告
├── lib/                     # Flutter 源码（骨架已建，阶段 3 填充）
├── tests/                   # 测试
├── dist/                    # 最终 APK（阶段 6 产出）
├── .env.example
└── .gitignore
```

## 密钥配置说明（重要：不要提交真实密钥）

### 1. 高德 Web 服务 Key（用于路径规划/地理编码/坐标转换）
- 复制 `config/amap_key.local` 模板：把 Key 填到该文件首行（已 gitignore）。
- 或复制根目录 `.env.example` 为 `.env`。
- 移动端构建注入：`flutter run --dart-define=AMAP_WEB_KEY=你的Key`。
- 生产分发建议后端代理，避免 Key 随 APK 分发。

### 2. 高德 Android 地图 SDK Key（与 Web 服务 Key 是不同类型）

在高德开放平台「应用管理」为 RunLoop 应用添加 **Android 平台** Key，需要以下三个值（已实测获取）：

| 项 | 值 |
| --- | --- |
| applicationId（包名） | `com.runloop.app` |
| Debug SHA1 | `44:EC:63:3D:DC:0B:85:7C:FB:66:54:A2:55:FB:C7:19:49:33:DF:FF` |
| Release SHA1 | `E1:3D:D3:72:1D:A5:75:BA:E3:38:A0:6A:52:95:09:3E:89:A4:9A:8E` |

可复现获取命令（本机 JDK 17 位于 `<user-home>\jdk\jdk-17.0.21.0.2+1\bin`）：

```powershell
# Debug SHA1（默认 debug.keystore，口令 android）
keytool -list -v -keystore "$env:USERPROFILE\.android\debug.keystore" -alias androiddebugkey -storepass android

# Release SHA1（正式签名密钥，口令见 android/key.properties，勿外泄）
keytool -list -v -keystore android/keystore/runloop-release.jks -alias runloop -storepass <storePassword>
```

> ⚠️ Release SHA1 取决于 `android/keystore/runloop-release.jks`：若删除并重建该 keystore，SHA1 会变化，需到高德控制台同步更新。
> Android 地图 SDK Key 后续写入 `android/app/src/main/AndroidManifest.xml`（`<meta-data android:name="com.amap.api.v2.apikey" .../>`）。

## 运行阶段 1 验证脚本

```bash
python backend/verify_amap.py                 # 验证高德各接口能力
python backend/loop_gen.py --target 15000 --seeds 1,2,3   # 生成 3 条约 15km 闭环
```

结果写入 `backend/out/loop_result_3.json`。

## 软件图标

- 你的原始图标已存在于 `icon/RunLoop.ico`（130KB，Windows .ico），我会保留、不覆盖。
- 图标资源目录：`assets/app_icon/`。
- 支持格式：PNG（推荐 1024×1024 透明底）、.ico、.svg、.jpg。
- 更新流程（阶段 6）：把新图标放入 `assets/app_icon/` → 我识别格式并转换为 Android mipmap + 自适应图标 → 配置 `android:label="环跑"` → 重新 `flutter build apk` → 校验 APK 内含新图标。
- 若提供 iOS，同样预留 `assets/app_icon/ios/` 结构。

## 构建状态与 APK

✅ 已成功构建（Flutter 3.47.8 / Android SDK 36 / JDK 17），含高德地图 SDK：

| 文件 | 用途 | 大小 |
| --- | --- | --- |
| `dist/RunLoop-环跑-Android.apk` | 正式版（Release 签名 + R8 优化） | 70.4 MB |
| `dist/RunLoop-环跑-Android-debug.apk` | 调试版（Debug 签名） | 188.7 MB |

- 应用名 **环跑**，applicationId `com.runloop.app`（已用 aapt 校验）。
- 地图 SDK：`com.amap.api:3dmap:8.1.0` + `location:5.6.0`（与插件 `compileOnly` 版本一致）；APK 内含 `libAMapSDK_MAP_v8_1_0.so`（arm64-v8a/armeabi-v7a/x86_64）。
- **AMap Key 采用构建注入**（不硬编码、不入库）：Key 存于 `android/amap_key.properties`（gitignore），manifest 用 `${AMAP_API_KEY}` 占位符；Dart 侧用 `--dart-define=AMAP_ANDROID_KEY=...`。构建命令：
  ```bash
  flutter build apk --debug --dart-define=AMAP_ANDROID_KEY=<你的Android SDK Key>
  flutter build apk --release --dart-define=AMAP_ANDROID_KEY=<你的Android SDK Key>
  ```
- 环境：Flutter SDK `<user-home>\flutter`，Android SDK `<user-home>\Android`，JDK 17 `<user-home>\jdk\jdk-17.0.21.0.2+1`。
- 国内镜像：Gradle/Flutter 走腾讯云镜像，Maven 依赖走阿里云镜像 + mavenLocal；AMap 插件已 vendored 到 `packages/` 并打补丁（修复 Gradle 9 兼容性）。

## 已知限制（阶段 1 时点）

- 高德骑行服务对本 Key 返回 `10002 SERVICE_NOT_AVAILABLE`（未开通），首版用步行路径规划。
- 路线安全属性（绿道/主干道/红绿灯/坡度/照明）无法直接从步行 API 获得，将尽量用可获取数据规避，并提示用户实地确认。
- 后台定位需真机验证厂商电池策略，不能假设必然持续可用。

详见各 `docs/*.md`。
