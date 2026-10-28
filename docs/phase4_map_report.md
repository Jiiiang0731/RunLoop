# 阶段 4（第一部分）：高德地图 SDK 接入报告

## 1. 结论

地图 SDK 接入**构建层面已稳定**：debug 与 release APK 均构建成功，APK 内含高德地图原生库 `libAMapSDK_MAP_v8_1_0.so`（arm64-v8a / armeabi-v7a / x86_64）、API Key（manifest）、APSService，applicationId=`com.runloop.app`、应用名=`环跑`。

**真机渲染验证尚缺**：本环境无物理 Android 设备，无法验证地图瓦片实际加载与定位效果，需你安装 `dist/` 中的 APK 后确认（见 §6）。

## 2. 采用的 SDK 版本与依据

| 组件 | 版本 | 说明 |
| --- | --- | --- |
| 高德地图 SDK | `com.amap.api:3dmap:8.1.0` | 内嵌 `.so` 的 JAR；插件 `compileOnly` 即此版本 |
| 高德定位 SDK | `com.amap.api:location:5.6.0` | 纯 Java（无 .so）；插件 `compileOnly` 即此版本 |
| amap_flutter_map | 3.0.0（本地补丁版） | 官方插件，已 vendored 修复 Gradle 9 兼容性 |
| amap_flutter_location | 3.0.0（本地补丁版） | 同上 |
| amap_flutter_base | 3.0.0（本地补丁版） | 同上 |

**为什么不用 `3dmap-location-search:10.1.200_loc6.4.9_sea9.7.4`？**

证据（不盲目升级）：
1. `amap_flutter_map 3.0.0` 的 `android/build.gradle` 明确声明 `compileOnly 'com.amap.api:3dmap:8.1.0'`，插件 Java 字节码按 8.1.0 API 编译；
2. 插件自身示例也使用 `implementation 'com.amap.api:3dmap:8.1.0' + location:5.6.0`；
3. 运行时改用 10.1.200 会造成「编译期 8.1.0 / 运行期 10.1.200」版本错配，存在 `NoSuchMethodError/NoSuchFieldError` 风险。

如后续需升级 SDK（例如为适配 Android 15+ 的 16KB 页大小），应同步升级插件或改用官方新版 Flutter 插件，并真机回归。

## 3. 修改/新增的文件

### 项目配置
- `pubspec.yaml`：新增 amap_flutter_map / amap_flutter_location / amap_flutter_base / permission_handler(12.0.3) / sqflite / flutter_foreground_task / path；新增 `dependency_overrides` 指向 `packages/` 下补丁插件。
- `android/app/build.gradle.kts`：新增 `implementation("com.amap.api:3dmap:8.1.0")` 与 `implementation("com.amap.api:location:5.6.0")`（运行时 SDK，插件本身为 compileOnly）。
- `android/app/src/main/AndroidManifest.xml`：定位/网络/前台服务/通知权限 + AMap Key meta-data + `com.amap.api.location.APSService`。
- `android/settings.gradle.kts`：`mavenLocal()` + 阿里云/华为 Maven 镜像 + Flutter 引擎仓库（dependencyResolutionManagement）。
- `android/gradle.properties`：JDK17、HTTP 超时、`kotlin.incremental=false`。

### 本地补丁插件（vendored，勿长期依赖 pub 缓存）
- `packages/amap_flutter_map/`：jcenter→mavenCentral、补 namespace、compileSdkVersion 29→36、`FlutterMain`→`FlutterInjector.instance().flutterLoader()`、移除旧 `registerWith(PluginRegistry.Registrar)`、`hashValues`→`Object.hash`。
- `packages/amap_flutter_location/`：jcenter→mavenCentral、namespace、compileSdkVersion 36。
- `packages/amap_flutter_base/`：`hashValues`→`Object.hash`。

### Dart 代码（地图 + 定位 + 记录基础）
- `lib/app/config.dart`、`lib/utils/geo.dart`
- `lib/models/{track_point,run_record,location_result}.dart`
- `lib/services/location/location_service.dart`（高德定位封装，GCJ-02）
- `lib/services/run_recorder/{gps_filter,run_recorder}.dart`
- `lib/services/storage/database.dart`（sqflite）
- `lib/screens/{home,run,run_summary,history}_screen.dart`
- `lib/main.dart`
- `test/{geo,gps_filter,run_recorder}_test.dart`

## 4. 关键问题与修复（均为实际构建中遇到并解决）

| # | 问题 | 根因 | 修复 |
| --- | --- | --- | --- |
| 1 | 运行时缺 AMap SDK | 插件 `compileOnly`，宿主未声明运行时依赖 | App 增加 `implementation com.amap.api:3dmap/location` |
| 2 | `Could not find method jcenter()` | Gradle 9.3.1 移除了 `jcenter()`，插件旧 build.gradle 使用它 | 补丁替换为 `mavenCentral()` |
| 3 | `Unexpected character '?'` | 补丁写入带 UTF-8 BOM，Groovy 拒绝 | 以无 BOM 方式重写 |
| 4 | `Namespace not specified` | AGP 9 要求各模块声明 namespace | 补丁加 `namespace` |
| 5 | `compileSdkVersion 29` 太老 | AGP 9 要求 ≥30 才能编译 Java 9+ | 补丁改为 36 |
| 6 | `FlutterMain` 找不到 | Flutter 3.x 移除 `io.flutter.view.FlutterMain` | 改为 `FlutterInjector.instance().flutterLoader().getLookupKeyForAsset` |
| 7 | `PluginRegistry.Registrar` 找不到 | Flutter 3.x 移除 v1 插件注册 | 移除旧 `registerWith` 方法（v2 `onAttachedToEngine` 已存在） |
| 8 | `hashValues` 未定义 | Dart 移除 `hashValues` | 改为 `Object.hash` |
| 9 | `permission_handler_android` 要求 compileSdk 37 | 13.x 插件要求 37，但 SDK 只有 android-37.x（无 android-37），且会拉高到不存在的平台 | 降级 `permission_handler` 至 12.0.3（其 android 依赖 compileSdk 35） |
| 10 | mavenCentral 下载挂起 | 本环境 Gradle 访问 mavenCentral 极慢/挂起 | 镜像 + `mavenLocal()` 预置 AMap 构件 + HTTP 超时 |
| 11 | `Could not close incremental caches` | 多次强制杀构建导致 Kotlin 增量缓存损坏 | `flutter clean` + `kotlin.incremental=false` |

## 5. 构建结果

| 文件 | 用途 | 大小 | AMap .so |
| --- | --- | --- | --- |
| `dist/RunLoop-环跑-Android.apk` | 正式版（release 签名） | 70.4 MB | ✓ 3 ABI |
| `dist/RunLoop-环跑-Android-debug.apk` | 调试版 | 171.7 MB | ✓ 3 ABI |

`aapt2 dump badging` 结果：`package: name='com.runloop.app'`、`application-label:'环跑'`；manifest 含 `com.amap.api.v2.apikey`（值在构建时注入，未入库）。

## 6. 真机验证清单（需你完成）

把 `dist/RunLoop-环跑-Android-debug.apk`（或正式版）装到手机后确认：

1. 启动 App，地图是否显示真实瓦片（非灰/空白）；
2. 顶部是否显示当前坐标与精度（定位是否成功）；
3. 若地图空白但无崩溃：多为 Key/包名/SHA1 不匹配或网络问题；
4. 若闪退：提供 logcat 中 `com.amap` 相关报错。
5. 本 APK 的 Key 绑定：包名 `com.runloop.app`，Debug SHA1 `44:EC:…:DF:FF`，Release SHA1 `E1:3D:…:9A:8E`。

## 7. 已知限制

- 本环境无真机/无可用 GPS，**无法验证地图实际渲染与定位**，只能验证构建与 APK 内容。
- 使用的地图 SDK 8.1.0 较老，在 Android 15+（16KB 页大小）设备上可能存在原生库兼容性风险，需真机确认；若出现问题再评估升级。
- SDK Key 已随 APK 分发（Android 平台 Key 绑定包名+SHA1，属正常做法）；Web 服务 Key 仍不入库。
