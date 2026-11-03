# 注册开机自启（阶段 K 规范⑪）：登录时后台拉起 RunLoop 后端。
#
# 说明：
# - Tailscale 安装器自带系统服务/登录自启，无需在此注册（脚本末尾会检查状态）；
# - 后端任务以「登录时」触发、受限权限（/rl limited）、隐藏窗口运行；
# - 取消自启：schtasks /delete /tn RunLoopBackend /f
$ErrorActionPreference = 'Stop'

$startScript = Join-Path $PSScriptRoot 'start_backend.ps1'
if (-not (Test-Path $startScript)) { throw "缺少 $startScript" }

# 优先 pwsh（PowerShell 7），退回系统自带 powershell
$shell = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $shell) { $shell = Get-Command powershell }

$action = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' `
    -f $shell.Source, $startScript)

schtasks /create /f /tn 'RunLoopBackend' /tr $action /sc onlogon /rl limited | Out-Null
Write-Host '✅ 已注册登录自启任务 RunLoopBackend：'
schtasks /query /tn 'RunLoopBackend' /fo LIST | Select-String 'TaskName|Status|任务名|状态'

Write-Host ''
# Tailscale 自启状态检查（只读，不修改）
$ts = Get-Command tailscale -ErrorAction SilentlyContinue
if ($ts) {
    & tailscale status 2>$null | Select-Object -First 1 | ForEach-Object { Write-Host "Tailscale 当前状态：$_" }
    Write-Host '（Tailscale 由安装器随系统自启；若上表为空请手动运行 tailscale up）'
} else {
    Write-Host '提示：尚未安装 Tailscale——安装后无需再运行本脚本注册 Tailscale 自启。'
}
