# 注册开机自启（阶段 K 规范⑪）：登录后后台拉起 RunLoop 后端。
#
# 双通道（自动降级，无需用户提权）：
#   1. 任务计划 RunLoopBackend（/sc onlogon 需要管理员权限，失败则降级）；
#   2. 用户启动文件夹 RunLoopBackend.vbs（任何权限都可用，窗口隐藏）。
# 取消自启：
#   schtasks /delete /tn RunLoopBackend /f
#   del "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\RunLoopBackend.vbs"
#
# 说明：Tailscale 安装器自带系统服务/登录自启，无需在此注册（末尾仅只读检查）。
$ErrorActionPreference = 'Stop'

$startScript = Join-Path $PSScriptRoot 'start_backend.ps1'
if (-not (Test-Path $startScript)) { throw "缺少 $startScript" }

# 优先 pwsh（PowerShell 7），退回系统自带 powershell
$shell = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $shell) { $shell = Get-Command powershell }

$action = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' `
    -f $shell.Source, $startScript)

# 通道 1：任务计划（需要管理员；非管理员会 Access denied → 降级）
# 注：PS 5.1 下原生命令 stderr + EAP=Stop 会误抛，临时降级再恢复。
$ErrorActionPreference = 'SilentlyContinue'
schtasks /create /f /tn 'RunLoopBackend' /tr $action /sc onlogon /rl limited 2>&1 | Out-Null
$taskOk = ($LASTEXITCODE -eq 0)
if ($taskOk) {
    Write-Host '✅ 已注册登录自启（任务计划 RunLoopBackend）'
    schtasks /query /tn 'RunLoopBackend' /fo LIST 2>&1 |
        Select-String 'TaskName|Status|Task To Run|任务名|状态|要运行的任务' |
        ForEach-Object { Write-Host ('   ' + $_.ToString().Trim()) }
} else {
    # 通道 2：用户启动文件夹（VBS 隐藏窗口启动，无闪烁）
    $startup = [Environment]::GetFolderPath('Startup')
    $ErrorActionPreference = 'Stop'
    if (-not $startup) { throw '无法定位用户启动文件夹' }
    $vbs = Join-Path $startup 'RunLoopBackend.vbs'
    $vbsAction = $action -replace '"', '""'
    $lines = @(
        'Set sh = CreateObject("WScript.Shell")',
        ('sh.Run "' + $vbsAction + '", 0, False')
    )
    Set-Content -Path $vbs -Value $lines -Encoding ASCII
    Write-Host '✅ 任务计划需要管理员权限，已改用启动文件夹（无需提权）：'
    Write-Host "   $vbs"
}
$ErrorActionPreference = 'Stop'

Write-Host ''
# Tailscale 自启状态检查（只读，不修改）
$ts = Get-Command tailscale -ErrorAction SilentlyContinue
if ($ts) {
    $ErrorActionPreference = 'SilentlyContinue'
    $line = & tailscale status 2>&1 | Select-Object -First 1
    $ErrorActionPreference = 'Stop'
    Write-Host "Tailscale 当前状态：$line"
    Write-Host '（Tailscale 由安装器随系统自启；若上面为空请手动运行 tailscale up）'
} else {
    Write-Host '提示：尚未安装 Tailscale——安装后无需再运行本脚本注册 Tailscale 自启。'
}
