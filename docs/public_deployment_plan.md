# 公网部署与架构准备方案（阶段 E）

> 当前后端为电脑局域网 Flask（`http://192.168.1.100:8000`），不能直接面向公众。
> 本文说明切换为公网 HTTPS 的方案，**不要求本阶段实际部署**。

## 1. 现状与切换点

- App 通过 `AppConfig.routeApiBaseUrl`（`--dart-define=ROUTE_API_BASE_URL`）访问后端；
- 默认值只是开发用局域网地址，**构建时可覆盖为公网 HTTPS**，无需改代码；
- 高德 Web 服务 Key 只在后端 `config/amap_key.local` 读取，**不进 APK、不入 Git**。

## 2. 公网部署方式

```
手机 App ──HTTPS──> Nginx (443) ──> Gunicorn/Uvicorn (127.0.0.1:8000) ──> Flask app
```

- 进程：`gunicorn -w 2 -k gthread -b 127.0.0.1:8000 backend.server:app`（Flask 生产部署，不用 `app.run`）。
- 反向代理：Nginx 终止 TLS、限流、超时。
- 容器化：Dockerfile + docker-compose（可选）。

## 3. 域名与 HTTPS

1. 购买域名并解析 A 记录到服务器 IP；
2. 用 Let's Encrypt（certbot）签发证书，Nginx 配置 301 跳转 + HSTS；
3. 证书自动续期（certbot renew + cron）。

## 4. 高德 Web Key 的安全管理

- 只存放在服务器环境变量 / 密钥管理（如 `AMAP_WEB_KEY`），代码不落盘明文；
- 重启/轮换 Key 不影响 App（App 只认后端地址）；
- 监控高德控制台的调用量与配额，设置告警。

## 5. 用户请求限制、配额与异常

| 项 | 方案 |
| --- | --- |
| 限流 | Nginx `limit_req`（按 IP）+ 应用层令牌桶（按设备/用户） |
| 单次生成调用量 | 后端已限制 `max_api_calls`（默认 600）与 `max_candidates` |
| 错误响应 | 统一 JSON：`{success:false, error, error_code}`；HTTP 429/500 明确 |
| 超时 | 请求级超时 + 生成阶段超时；失败不返回假数据 |
| 配额不足 | 捕获高德 infocode，返回可读错误，不伪造路线 |

## 6. 隐私保护

- 路线生成**无状态**：后端不持久化用户 GPS/轨迹（仅内存中计算）；
- 跑步记录、轨迹、规划路线全部存**手机本地 SQLite**；
- 无账号体系，不上传个人数据；
- 日志脱敏：不记录完整坐标与 Key。

## 7. 成本评估

- **高德 Web 服务调用**：单次路线生成约 150–300 次调用（受目标距离与校准影响）。
  - 例：1000 用户 × 每天 1 条 ≈ 15–30 万次/天；需按高德配额档位评估费用/申请企业配额。
  - 优化方向：分段缓存（已实现）、默认只生成 1 条候选（已实现）。
- **服务器**：2C4G 小型 VPS 即可（Flask 计算轻，主要瓶颈是高德 API 延迟）。
- **带宽**：单次响应含折线+步骤，约 100–300 KB，流量成本低。

## 8. 本地开发模式 vs 公网模式切换

| 模式 | 配置 |
| --- | --- |
| 本地开发 | `--dart-define=ROUTE_API_BASE_URL=http://<电脑局域网IP>:8000` |
| 公网生产 | `--dart-define=ROUTE_API_BASE_URL=https://api.example.com` |

两者代码完全一致，仅构建参数不同。可在 App 内增加「开发者选项」显示当前后端地址，便于排查。

## 9. 上线前检查清单

- [ ] HTTPS 证书有效、HSTS 开启
- [ ] 限流与超时生效
- [ ] Key 仅服务端持有
- [ ] 错误码与前端提示对齐
- [ ] 高德配额告警
- [ ] 隐私说明更新（App 内隐私政策）
