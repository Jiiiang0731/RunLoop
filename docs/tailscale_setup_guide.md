# Tailscale 私有网络部署指南（RunLoop 阶段 K）

> 目标：手机在任何网络（校园网 / 移动数据）都能通过 HTTPS 访问你 Windows 电脑上的
> RunLoop 后端，**零月租、不购买服务器/域名、不暴露公网**（不启用 Funnel）。
>
> 链路：`手机 App → Tailscale 加密隧道 → Windows Tailscale Serve (HTTPS 443) → 127.0.0.1:8000 waitress 后端`

---

## 第一部分：需要你亲手完成的操作（共 4 步，约 15 分钟）

后端代码、Serve 配置、证书申请命令、开机自启脚本全部由我完成——
但**账号注册与登录必须你本人操作**（凭据不经过我，也请不要发给我）。

### ☐ 第 1 步：Windows 电脑安装并登录 Tailscale

1. 浏览器打开官方下载页：**https://tailscale.com/download/windows**
   下载 `tailscale-setup-*.exe` 并安装（一路默认即可，会注册为系统服务）。
2. 安装完成后任务栏出现 Tailscale 图标 → 点击 **Log in**。
3. 浏览器会打开登录页：用 **GitHub / Google / Microsoft / Apple** 任一账号注册或登录
   （国内邮箱也可用 Email 注册）。个人使用自动落在 **Personal 免费版**
   （3 用户 / 100 设备，非商业用途，完全够用）。
4. 登录成功后告诉我，或自行验证：任务栏图标显示已连接。

### ☐ 第 2 步：管理控制台开启 MagicDNS 与 HTTPS 证书（关键！）

1. 浏览器打开 **https://login.tailscale.com/admin/dns**（用第 1 步的同一账号）。
2. 打开两个开关：
   - **MagicDNS** → Enable（自动分配 `机器名.尾网名.ts.net` 内网域名）；
   - **HTTPS Certificates** → Enable（允许设备申请 tailnet 内可信证书）。
3. 顺手看一眼 **https://login.tailscale.com/admin/settings**：
   确认 **Funnel 保持关闭**（我们不用它，不对公网开放）。

### ☐ 第 3 步：Android 手机安装 Tailscale 并登录同一账号

1. Google Play 搜索 **Tailscale** 安装；
   无 Play 服务的手机改用官网直装包：**https://tailscale.com/download/android**
   （页面提供 APK 下载）。
2. 打开 App → **用与电脑完全相同的账号登录**（这样两台设备进入同一 tailnet）。
3. 登录后主开关拨到 **Connect**。

### ☐ 第 4 步：告诉我「装好了」

我随后会自动完成（不需要你操作）：

| 我做 | 命令/动作 |
|---|---|
| 确认两端在同一 tailnet | `tailscale status` |
| 读取**真实** MagicDNS 主机名 | `tailscale status --json`（绝不编造地址） |
| 申请 HTTPS 证书 | `tailscale cert <主机名>` |
| 开启 Serve 反代 8000 | `tailscale serve --bg 8000` |
| 生成开机自启脚本 | 计划任务：Tailscale + waitress 后端 |
| 把真实地址写入 App 正式配置并出包 | `lib/app/config.dart` → release APK |

---

## 第二部分：验证清单（安装后由我执行，你可旁观）

- **A** 电脑侧：后端起在 127.0.0.1:8000，Serve 输出真实 HTTPS 地址；
- **B** 手机浏览器（连校园 Wi-Fi）打开 `https://<真实地址>/api/health` → 200 JSON；
- **C** 手机**关 Wi-Fi 用移动数据**再开一次 → 仍 200（证明不依赖同网）；
- **D** App（正式版）移动数据下真实生成一条路线；
- **E** 结论记录：无需同校园网；
- **F** 电脑睡眠/后端关闭 → App 显示明确错误提示，已保存路线仍可离线查看；
- **G** 重启电脑 → Tailscale 与后端自动恢复；防睡眠仅**建议**操作（见下）。

## 第三部分：电源设置（只说明，不擅自改）

Windows 睡眠会断开隧道（手机报网络错误，属预期）。**建议但不强制**：
接通电源时不自动睡眠（`powercfg /change standby-timeout-ac 0`）+ 合盖不睡眠。
我不会擅自修改你的电源计划；你同意的话回复「同意防睡眠」，我再执行并记录；
不同意也可以，跑长距离前手动保持电脑唤醒即可。

## 常见问题

- **Q：Tailscale 免费版会过期/限速吗？** Personal 计划对个人非商业用途长期免费，
  设备间流量不限速；100 设备上限远超本项目（2 台）。
- **Q：安全吗？** 端到端 WireGuard 加密；后端只监听 127.0.0.1，校园网扫不到；
  不开 Funnel 则公网完全不可达；高德 Key 只存电脑本地。
- **Q：换 Wi-Fi / 用流量要重连吗？** 不用，Tailscale 与所在网络无关。
- **Q：以后想买云服务器迁移？** 后端是标准 Flask+waitress，迁移只需把服务
  放到云主机+域名反代，App 改一行 BASE_URL（配置已单源化）。
