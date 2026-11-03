# Tailscale Serve 一次性配置 + 验证（阶段 K 规范⑥）
#
# 做什么：
#   1. 检查 tailscale 已安装、已登录；
#   2. 从 `tailscale status --json` 读取本机【真实】MagicDNS 名（绝不编造地址）；
#   3. 检查后端已在 127.0.0.1:8000 运行；
#   4. `tailscale serve --bg 8000`：Tailnet 内 HTTPS(443) → 本机 8000（自动签发证书）；
#   5. 经 Tailnet 回环验证 /api/health；
#   6. 打印正式版 APK 应注入的 TAILNET_BASE_URL。
#
# 安全红线：不启用 Funnel（不对公网开放）；后端只绑回环。
# 前置：Tailscale 控制台 → DNS 页已开启 MagicDNS + HTTPS Certificates
#      （见 docs/tailscale_setup_guide.md）。
$ErrorActionPreference = 'Stop'

# 1. 安装与登录检查
$ts = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $ts) {
    throw '未找到 tailscale 命令。请先安装 Tailscale（https://tailscale.com/download/windows）并登录。'
}

$statusRaw = & tailscale status --json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $statusRaw) {
    throw 'tailscale 未登录或状态不可读。请先运行「tailscale up」完成登录。'
}
$status = $statusRaw | ConvertFrom-Json

# 2. 真实 MagicDNS 主机名（形如 my-pc.tail1234.ts.net）
$dnsName = ''
if ($status.Self -and $status.Self.DnsName) { $dnsName = $status.Self.DnsName.TrimEnd('.') }
if (-not $dnsName) {
    throw ('本机没有 MagicDNS 名称。请到 Tailscale 控制台 → DNS → 开启 ' +
         '「MagicDNS」与「HTTPS Certificates」后重试。')
}
$httpsUrl = "https://$dnsName"
Write-Host "本机 Tailnet 地址（读取自 tailscale status，非编造）：$httpsUrl"

# 3. 后端健康检查（回环）
try {
    $local = Invoke-RestMethod 'http://127.0.0.1:8000/api/health' -TimeoutSec 5
} catch {
    throw ('后端未在 127.0.0.1:8000 运行。请先执行 deploy\start_backend.ps1（或等开机任务拉起）。' +
         " 原始错误：$($_.Exception.Message)")
}
Write-Host "本地后端 OK：version=$($local.version) env=$($local.env) breaker=$($local.breaker)"

# 4. Serve：HTTPS(443) → 127.0.0.1:8000（幂等；证书由 Tailscale 自动签发续期）
& tailscale serve --bg 8000
if ($LASTEXITCODE -ne 0) { throw "tailscale serve 配置失败（exit $LASTEXITCODE）" }

# 4b. 确认 Funnel 保持关闭（红线检查）
$funnel = & tailscale funnel status 2>&1 | Out-String
Write-Host '--- tailscale funnel status ---'
Write-Host $funnel.Trim()
if ($funnel -match 'Funnel on|funnel on') {
    Write-Warning '检测到 Funnel 处于开启状态！违反部署红线（不得暴露公网），请立即：tailscale funnel 443 off'
}

# 5. 经 Tailnet 验证
Start-Sleep -Seconds 2
try {
    $remote = Invoke-RestMethod "$httpsUrl/api/health" -TimeoutSec 20
    Write-Host "✅ Tailnet HTTPS 验证通过：$httpsUrl/api/health -> version=$($remote.version)"
} catch {
    throw ("Tailnet HTTPS 验证失败：$($_.Exception.Message)`n" +
         '排查：① 控制台 HTTPS Certificates 是否开启；② tailscale serve status；' +
         '③ 稍等 30 秒证书签发后重试。')
}

# 6. 正式版构建参数
Write-Host ''
Write-Host '=== 正式版 APK 构建命令（复制即用）==='
Write-Host "flutter build apk --release --dart-define=TAILNET_BASE_URL=$httpsUrl --dart-define=AMAP_ANDROID_KEY=<你的AndroidKey>"
Write-Host ''
Write-Host '手机侧验证：连接 Tailnet（Android Tailscale 客户端开启）后浏览器打开'
Write-Host "  $httpsUrl/api/health"
