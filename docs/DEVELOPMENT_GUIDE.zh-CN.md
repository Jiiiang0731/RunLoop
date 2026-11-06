# RunLoop Windows 开发与 IDE 使用指南

本文说明如何在 Windows 上使用 IntelliJ IDEA、Android Studio 和 PyCharm 打开、运行和继续开发 RunLoop。

项目根目录：

`<project-root>`（本机示例：`D:\path\to\RunLoop-app`）

判断标准：目录中应同时存在 `pubspec.yaml`、`lib/`、`backend/`、`android/`、`test/`、`tests/`。

---

## 一、先明确：这是一个混合项目

RunLoop 同时包含：

- Flutter/Dart 手机端：`lib/`、`test/`、`android/`；
- Python 后端：`backend/`、`tests/`、`requirements.txt`；
- 文档与脚本：`docs/`、`deploy/`、`tools/`。

同一个根目录可以被不同 IDE 打开，但不同 IDE 的能力不同。

### 推荐组合

| 开发任务 | 推荐 IDE |
|---|---|
| Flutter App（页面、导航、语音、地图） | IntelliJ IDEA + Flutter/Dart 插件，或 Android Studio |
| Python 后端（路线算法、重规划、测试） | PyCharm，或 IntelliJ IDEA + Python 插件 |
| 只改文档 / Markdown | VS Code、Typora 或任意编辑器 |

### 重要边界

- **IntelliJ IDEA**：安装 Flutter 和 Dart 插件后，可以开发、运行和构建 Flutter 项目，同时也可以安装 Python 插件处理后端。
- **Android Studio**：Flutter 官方支持最完整，适合 Flutter/Android 开发；也能打开 Python 文件，但不是主要 Python IDE。
- **PyCharm**：适合 Python 后端和 pytest；它**不是**完整的 Flutter IDE，不能替代 IntelliJ IDEA/Android Studio 运行 Flutter App。
- 不要因为项目能在一个 IDE 中打开，就认为该 IDE 能完成所有构建任务。

> JetBrains 官方插件会随版本更新。安装前请在 IDE 的 Plugins 市场搜索 “Flutter” 和 “Dart”，确认当前 IDE 版本受支持。若插件不可用，请使用 Android Studio。

---

## 二、公共环境检查

在 PowerShell 中执行：

```powershell
git --version
flutter --version
dart --version
python --version
java -version
flutter doctor
```

要求：

- Flutter 3.47.x（本项目 3.47.8）；
- Dart 3.13.x；
- Python 3.10+（本项目 3.13）；
- JDK 17 或 21 LTS（本项目也使用过 JDK 25）；
- Android SDK Platform 36 / Build Tools 36.0.0；
- `flutter doctor` 中的 Flutter、Android toolchain、Android Studio 项目尽量为绿色。

如果 `flutter` 不在 PATH，请把 `C:\Users\<name>\flutter\bin` 加入用户环境变量。

首次使用 Android SDK：

```powershell
flutter doctor --android-licenses
```

逐项输入 `y` 接受许可。

---

## 三、IntelliJ IDEA 配置

### 1. 安装与插件

1. 安装 IntelliJ IDEA（Community 或 Ultimate 均可尝试）；
2. 打开 `Settings` → `Plugins`；
3. 搜索并安装 **Flutter** 和 **Dart**；
4. 重启 IDE。

### 2. 配置 Flutter SDK

`Settings` → `Languages & Frameworks` → `Flutter`：

- Flutter SDK path：`C:\Users\<name>\flutter`
- Dart SDK 通常会自动识别为 `flutter\bin\cache\dart-sdk`

如果 Flutter 一栏不存在，说明 Flutter 插件未安装成功。

### 3. 配置 JDK

`File` → `Project Structure` → `Project`：

- SDK：JDK 17 或 21；
- Language level：与 JDK 匹配。

`Project Structure` → `SDKs` 可以添加本机 JDK 路径。

### 4. 配置 Android SDK

`Settings` → `Languages & Frameworks` → `Android SDK`：

- Android SDK location：例如 `C:\Users\<name>\Android\Sdk`；
- SDK Platforms：安装 Android 36；
- SDK Tools：安装 Android SDK Build-Tools 36.0.0、Android SDK Platform-Tools。

同时确认系统环境变量 `ANDROID_HOME` 指向同一路径。

### 5. 打开项目

1. `File` → `Open`；
2. 选择包含 `pubspec.yaml` 的项目根目录；
3. 等待 Flutter/Dart 索引；
4. 在终端执行：

```bash
flutter pub get
```

### 6. 连接手机

1. 手机开启“开发者选项”和“USB 调试”；
2. USB 连接电脑，手机弹出授权时选择允许；
3. 终端执行：

```bash
flutter devices
```

能看到设备后，在 IDEA 右上角选择 Flutter 运行配置和设备，点击运行。

如果没有 Flutter 运行配置：

- `Run` → `Edit Configurations` → `+` → `Flutter`；
- Dart entrypoint 选择 `lib/main.dart`；
- 选择设备后运行。

### 7. 构建 APK

在 IDEA 的 Terminal 中执行：

```bash
flutter build apk --debug \
  --dart-define=TAILNET_BASE_URL=https://your-device.your-tailnet.ts.net \
  --dart-define=AMAP_ANDROID_KEY=YOUR_ANDROID_SDK_KEY
```

Release 构建还需要 `android/key.properties` 和你的 keystore，详见 README。

### 8. 运行测试

- 在 `test/` 中右键测试文件 → Run；
- 或终端执行：

```bash
flutter test
flutter analyze lib test
```

---

## 四、PyCharm 配置

PyCharm 适合 Python 后端和 `tests/`。它也可以打开整个项目根目录，但请不要期望它运行 Flutter App。

### 1. 打开项目

`File` → `Open`，选择项目根目录。

### 2. 创建并配置虚拟环境

在 PyCharm Terminal 或 PowerShell：

```powershell
cd D:\DeepSeekHarness\RunLoop-app
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements-dev.txt
```

PyCharm：

`Settings` → `Project` → `Python Interpreter` → `Add Interpreter` → `Existing`：

选择：

```text
<project-root>\.venv\Scripts\python.exe
```

### 3. 标记源码目录

右键 `backend` → `Mark Directory as` → `Sources Root`。

这样 `from backend...` 的导入能被正确索引。

### 4. 配置高德 Web Key

二选一：

- 复制 `config\amap_key.example` 为 `config\amap_key.local`，首行填 Web Service Key；
- 在运行配置中设置环境变量 `RUNLOOP_AMAP_KEY`。

### 5. 运行后端

创建 Run Configuration：

- Script path：`<project-root>\backend\serve.py`
- Working directory：`<project-root>`
- Python interpreter：`.venv\Scripts\python.exe`
- 环境变量：`RUNLOOP_AMAP_KEY=...`（如果不用本地文件）

运行后访问：

```text
http://127.0.0.1:8000/api/health
```

### 6. 运行 Python 测试

- 右键 `tests/` → `Run 'pytest in tests'`；
- 或 Terminal：

```powershell
python -m pytest -q
```

### 7. PyCharm 的能力边界

- 可以：编辑/运行/调试 Python 后端、运行 pytest、查看 Flask 日志；
- 不可以：直接运行 Flutter App、执行 `flutter build apk`、使用 Flutter 热重载；
- 可以在 PyCharm 中编辑 Dart 文件，但没有完整的 Flutter 工具链支持。

Flutter 前端请使用 IntelliJ IDEA + Flutter 插件，或 Android Studio。

---

## 五、Android Studio 配置（Flutter 推荐）

1. 安装 Android Studio；
2. `Settings` → `Plugins` → 安装 Flutter、Dart；
3. `Settings` → `Languages & Frameworks` → `Android SDK` 安装 Platform 36 和 Build-Tools 36.0.0；
4. `Open` 选择项目根目录；
5. 等待 `flutter pub get`；
6. 连接手机，选择设备，点击 Run；
7. 构建 APK 可在 Terminal 使用 `flutter build apk`。

Android Studio 对 Flutter/Android 的兼容性通常最稳定；如果 IntelliJ IDEA 的 Flutter 插件版本不匹配，优先使用 Android Studio。

---

## 六、常用命令

| 目的 | 命令 |
|---|---|
| 安装 Flutter 依赖 | `flutter pub get` |
| 运行 App（调试） | `flutter run` |
| Flutter 测试 | `flutter test` |
| Flutter 静态分析 | `flutter analyze lib test` |
| Debug APK | `flutter build apk --debug ...` |
| Release APK | `flutter build apk --release ...` |
| Python 依赖 | `pip install -r requirements-dev.txt` |
| 启动后端 | `python backend/serve.py` |
| Python 测试 | `python -m pytest -q` |
| 健康检查 | `curl http://127.0.0.1:8000/api/health` |
| Tailscale Serve | `tailscale serve --bg 8000` |
| 查看设备 | `flutter devices` |
| 安装 APK | `adb install -r <apk>` |

---

## 七、常见环境问题

### 1. `flutter` 命令找不到

把 `C:\Users\<name>\flutter\bin` 加入 PATH，重新打开终端。

### 2. `flutter doctor` 报 Android license 未接受

```powershell
flutter doctor --android-licenses
```

### 3. Gradle 下载慢或失败

`android/gradle/wrapper/gradle-wrapper.properties` 当前使用腾讯云镜像。若你所在网络无法访问该镜像，可改为官方 Gradle 分发地址，或配置可用的代理。不要随意升级 Gradle/AGP 版本，先确认 Flutter 与 JDK 兼容。

### 4. JDK 版本不匹配

Android Gradle Plugin 需要较新的 JDK。优先使用 JDK 17 或 21 LTS；如果构建日志提示 Java 版本错误，检查 `java -version` 和 IDE 的 Project SDK 是否一致。

### 5. 高德定位失败

- `android/amap_key.properties` 是否绑定 `com.runloop.app`；
- Debug/Release SHA-1 是否与当前证书一致；
- 手机是否授予定位权限；
- 使用 App 的“定位诊断”页查看原生回调。

### 6. 后端启动报 `ModuleNotFoundError`

确保工作目录是项目根目录，并使用：

```powershell
python backend\serve.py
```

`backend/serve.py` 会把项目根目录加入 `sys.path`。

### 7. `pytest` 找不到测试

在项目根目录执行：

```powershell
python -m pytest -q
```

不要进入 `backend/` 后执行。

### 8. PyCharm 无法运行 Flutter

这是预期行为。PyCharm 不是完整 Flutter IDE。请使用 IntelliJ IDEA 或 Android Studio。

### 9. 锁屏语音仍不工作

请使用 App 的“语音诊断”页做锁屏自检，并检查 Vivo/iQOO 的自启动、后台耗电和电池白名单。项目代码已提供前台服务、TTS 看门狗和日志；具体系统限制需要真机验证。

---

## 八、推荐开发流程

```text
1. 打开项目根目录
2. flutter pub get
3. 配好 Python venv / 高德 Key / Tailscale
4. 后端启动并健康检查
5. 连接手机，flutter run
6. 修改代码
7. python -m pytest -q
8. flutter test
9. flutter analyze lib test
10. 真机/真实 API 验证
11. 检查 git diff 与敏感信息
12. 提交
```

改代码前先确认改的是哪个层：

- 页面问题 → `lib/screens/`；
- 导航/语音 → `lib/services/nav/`；
- 路线算法 → `backend/route_generator/`；
- 偏航重规划 → `backend/reroute.py` + `lib/services/route_api/reroute_api.dart` + `lib/screens/run_screen.dart`；
- Android 权限/后台 → `android/app/src/main/AndroidManifest.xml`、`MainActivity.kt`、`foreground_run_service.dart`。
