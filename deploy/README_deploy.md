# RunLoop 部署手册（Tailscale 个人免费版，零月租）

> 形态：**Windows 本机 waitress（仅 127.0.0.1:8000）← Tailscale Serve（Tailnet 内 HTTPS）← 手机**
> 红线：不启用 Funnel、不暴露公网、不把局域网/localhost 地址打进正式版 APK、AMap Web Key 只存服务器。
> 账号/安装/手机端步骤见 `docs/tailscale_setup_guide.md`（用户清单）。

## 一次性部署（在开发机上，按顺序）

| 步骤 | 命令 | 说明 |
| --- | --- | --- |
| 1 | `powershell -File deploy\start_backend.ps1` | 启动后端（生产模式，回环 8000）。验证：`Invoke-RestMethod http://127.0.0.1:8000/api/health` |
| 2 | `powershell -File deploy\setup_tailscale_serve.ps1` | 读取**真实** MagicDNS 名 → `tailscale serve --bg 8000` → 经 Tailnet 验证 HTTPS → 打印正式版构建命令 |
| 3 | `powershell -File deploy\register_autostart.ps1` | 注册登录自启：优先任务计划（需管理员），自动降级到用户启动文件夹 VBS（无需提权）。**本机已注册完成**（Startup\RunLoopBackend.vbs） |
| 4 | `powershell -File deploy\set_awake.ps1` | **可选**：AC 防睡眠（交互确认后才修改；不改电池策略） |

第 2 步成功后会打印形如下面的构建命令（主机名以你机器实际为准，脚本从
`tailscale status --json` 读取，绝不手工编造）：

```
flutter build apk --release --dart-define=TAILNET_BASE_URL=https://<机器名>.<tailnet>.ts.net --dart-define=AMAP_ANDROID_KEY=<AndroidKey>
```

## 手机侧验证矩阵（A–G，详见 docs/tailscale_setup_guide.md）

- A/B：手机连 Tailnet → 浏览器开 `https://<机器名>.../api/health` 应返回 JSON；
- C：关 Wi-Fi 用移动数据 + Tailscale 开启 → 同一地址仍可达（WireGuard 隧道走蜂窝）；
- D：正式版 App 移动数据下生成真实路线；
- E：手机与电脑**不需要**同一校园网；
- F：电脑睡眠/后端停止 → App 出现明确中文错误（含重试提示），已保存路线仍可离线查看/开跑；
- G：重启电脑 → 无需手动操作，任务自动拉起后端 + Tailscale。

## 常见问题

- `tailscale serve` 报证书错误：控制台 DNS 页确认「HTTPS Certificates」已开启，等 30 秒重试。
- 手机浏览器打不开 HTTPS 地址：确认 Android Tailscale 客户端处于 Connected；确认没开 Funnel 以外的代理。
- 后端 503 `UPSTREAM_QUOTA`：AMap 当日配额触顶，熔断器 120s 自动半开探测；不要刷接口。
- **8000 端口被占 / 出现 0.0.0.0:8000 监听**：多半是旧版开发服务器残留
  （`python backend/server.py`，阶段 J 及以前默认绑全网卡）。处理：
  `Get-NetTCPConnection -LocalPort 8000 -State Listen` 找到非 127.0.0.1 的
  PID → `Stop-Process -Id <pid> -Force`。生产形态只允许 127.0.0.1:8000
  （waitress，`deploy\start_backend.ps1`）。
- 换电脑/重装：重跑第 1–3 步即可；MagicDNS 名不变则 APK 无需重打。
- 以后要迁公网（可选路径）：腾讯云轻量 HK 38–54 元/月 + 域名 ICP 备案 1–4 周；届时只需换
  `TAILNET_BASE_URL` 注入值并重打 APK，服务端代码零改动。

## 安全清单（当前实现）

- [x] waitress 仅绑 127.0.0.1（`Get-NetTCPConnection` 可验证无 0.0.0.0:8000）
- [x] Tailscale Serve 仅 Tailnet 可见；Funnel 关闭（setup 脚本会检查并告警）
- [x] AMap Key：`config/amap_key.local`（gitignore）/环境变量；不进 Git、日志、响应
- [x] 限流（generate 8/10min、80/天；pois 30/h，按设备哈希）+ 并发闸 + 熔断
- [x] 日志脱敏：坐标只留 2 位小数；设备 ID 只存 sha256 前 8 位
