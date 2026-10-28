# RunLoop（环跑）

面向马拉松训练者的跑步 App：输入目标距离，自动生成一条尽可能接近目标距离、起终点闭合、尽量适合跑步的环形路线，并提供预览、导航、GPS 运动记录与历史统计。

> 项目展示名：**环跑** ｜ 英文名：**RunLoop**

## 当前进度

- ✅ 阶段 0：技术可行性报告 → `docs/feasibility.md`
- ✅ 阶段 1：15km 闭合环线最小验证 → `docs/test_report.md`（3 候选，误差 +274/−322/+185m，闭合 0.7m）
- ✅ 阶段 2：算法封装 + 路线评分 + 单元测试（25 用例通过）→ `backend/route_generator/`
- ⏳ 阶段 3 起：Flutter 移动端（安装 Flutter/Android SDK/JDK，创建 Android 项目，确定 applicationId 与 SHA1）

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

### 2. 高德 Android 地图 SDK Key（阶段 3 需要，与 Web 服务 Key 是不同类型）
- 在高德开放平台「应用管理」新建 Android 平台 Key，绑定：
  - 包名：`com.runloop.app`
  - 调试/发布 SHA1 指纹（`keytool -list -v -keystore ...`）
- 写入 `android/app/src/main/AndroidManifest.xml`（`<meta-data android:name="com.amap.api.v2.apikey" .../>`）与 `android/key.properties`（gitignore）。

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

- **当前环境尚未安装 Flutter 与 Android SDK，暂不能构建 APK**（详见 `docs/feasibility.md` §2）。
- 磁盘（C 94GB / D 244GB 空闲）与网络满足安装条件；计划阶段 3 安装 Flutter SDK + Android SDK + JDK 17/21 并实测构建。
- 最终 APK 目标：`dist/RunLoop-环跑-Android.apk`（调试版 + 发布版分别说明用途）。

## 已知限制（阶段 1 时点）

- 高德骑行服务对本 Key 返回 `10002 SERVICE_NOT_AVAILABLE`（未开通），首版用步行路径规划。
- 路线安全属性（绿道/主干道/红绿灯/坡度/照明）无法直接从步行 API 获得，将尽量用可获取数据规避，并提示用户实地确认。
- 后台定位需真机验证厂商电池策略，不能假设必然持续可用。

详见各 `docs/*.md`。
