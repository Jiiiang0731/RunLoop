# Release 启动崩溃排查报告

## 1. 崩溃根因（证据）

**设备状态**：本机 ADB 无可用真机（`adb devices` 仅显示残留 `emulator-5554 offline`；Windows 中 `Android Composite ADB Interface` 状态 Unknown），无法抓取 logcat。

**替代证据（不依赖真机）**：用 `apkanalyzer dex packages` 对比 debug 与 release APK 中 `com.amap` 类数量：

| APK | `com.amap` 类条目 |
| --- | --- |
| debug APK | **12133**（完整） |
| release APK（修复前） | **仅 13**，且全部是 `com.amap.api.location.APSService`（因在 Manifest 中被声明才保留） |

**根因**：Release 启用了 R8 混淆。高德地图/定位 SDK 以**纯 JAR**（非 AAR）发布，未携带 consumer ProGuard 规则；R8 将未被直接引用的 `com.amap.api.*`（以及 `com.autonav`/`com.loc`）类当作死代码剥离。App 启动时 `main()` → `LocationService.init()` → 调用高德定位隐私初始化，无法加载 `AMapLocationClient` 等类，导致启动闪退。

这与用户描述「正式版启动闪退、Debug 可用」完全吻合（debug 不混淆）。

## 2. 修复

1. 新增 `android/app/proguard-rules.pro`：保留 `com.amap.api.**`、`com.autonavi.**`、`com.loc.**`、`com.amap.flutter.**` 及 `APSService`，并 `-dontwarn`。
2. `android/app/build.gradle.kts` 的 release 构建增加 `proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")`。
3. 验证：修复后 release APK 的 `com.amap` 类条目 **13 → 11553**，含 `AMap.OnMapClickListener`、`AMap.OnCameraChangeListener` 等关键接口。

## 3. 同时修复的合规问题（Part 2 检查发现）

原 `main()` 无条件调用 `AMapFlutterLocation.updatePrivacyAgree(true)`，属于「未经用户同意即视为同意」。已改为：

- 新增 `lib/screens/consent_screen.dart` 隐私同意页；
- `lib/main.dart` 增加同意门禁：用 SharedPreferences 记忆 `privacy_agreed`，**仅用户同意后**才调用 `LocationService.init()` 初始化高德 SDK；
- Manifest 中 Key 依旧通过占位符注入，未入库。

## 4. 修改的文件

| 文件 | 变更 |
| --- | --- |
| `android/app/proguard-rules.pro` | 新增（AMap keep 规则） |
| `android/app/build.gradle.kts` | release 增加 proguardFiles |
| `lib/main.dart` | 隐私同意门禁 |
| `lib/screens/consent_screen.dart` | 新增同意页 |
| `pubspec.yaml` | 新增 shared_preferences |

## 5. Debug / Release 对照

| 项 | debug | release（修复前） | release（修复后） |
| --- | --- | --- | --- |
| `com.amap` 类 | 12133 | 13（被剥离） | 11553 |
| AMap 原生库 | ✓ 3 ABI | ✓ 3 ABI | ✓ 3 ABI |
| R8 混淆 | 关 | 开 | 开（AMap 已保留） |

## 6. 修复后 APK

- `dist/RunLoop-环跑-Android.apk`（71.2 MB，正式版）
- `dist/RunLoop-环跑-Android-debug.apk`（188.7 MB，调试版）

## 7. 真机实测

**未完成**：本机无可用 ADB 设备。需你完成最小操作后我可继续：

1. 用 USB 线连接手机到电脑；
2. 手机「开发者选项」中开启「USB 调试」；
3. 手机弹出「允许 USB 调试吗？」时点「允许」（勾选「一律允许」）；
4. 我执行 `adb devices` 应显示 `device`，随后抓 logcat 验证。

## 8. 已知限制

- 修复依据为 APK 静态分析（apkanalyzer），**尚未经真机运行验证**；请安装修复后的 APK 确认不再闪退。
- 地图 SDK 8.1.0 在 Android 15+（16KB 页大小）设备上仍有原生库兼容风险，需真机确认。
- `flutter analyze` 报告的 607 条告警均来自 vendored 老插件（`packages/`），不影响构建；`flutter test` 12 项通过。
