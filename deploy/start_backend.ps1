# RunLoop 后端启动脚本（生产模式）
#
# 形态：waitress 仅监听 127.0.0.1:8000 —— 校园局域网/公网都碰不到这个端口。
# 对外暴露统一走 Tailscale Serve（见 setup_tailscale_serve.ps1）。
#
# 高德 Web Key：由 backend/server.py 读取 config/amap_key.local（已 gitignore），
# 或通过环境变量 RUNLOOP_AMAP_KEY 注入。Key 绝不进入 Git/日志/响应。
# 注：EAP 用 Continue——PS 5.1 下 Stop + *>> 流重定向时，python 的良性 stderr
# 输出也会误抛终止脚本；失败由 waitress 自身退出码/日志体现。
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$env:RUNLOOP_ENV  = 'production'
$env:RUNLOOP_HOST = '127.0.0.1'
$env:RUNLOOP_PORT = '8000'

# 控制台输出留痕（业务访问日志另见 logs/runloop-api.log，已脱敏）
New-Item -ItemType Directory -Force -Path (Join-Path $root 'logs') | Out-Null

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { throw '未找到 python，可执行文件需在 PATH 中' }

# 幂等守卫：端口已被监听 = 已有实例在跑 → 记录后直接退出。
# 防止启动文件夹/重复触发拉起的第二实例与首实例争抢 backend_console.log
# （*>> 句柄被首实例长期持有，会静默失败），也避免 Windows SO_REUSEADDR
# 语义下 127.0.0.1:8000 被双绑的混乱。
$port = [int]$env:RUNLOOP_PORT
$listening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($listening) {
    $msg = '[{0}] autostart: 端口 {1} 已在监听（PID {2}），本实例退出' -f
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $port, $listening.OwningProcess
    Add-Content -Path (Join-Path $root 'logs\autostart.log') -Value $msg -Encoding UTF8
    Write-Host $msg
    exit 0
}

Write-Host 'RunLoop 后端启动中（127.0.0.1:8000，生产模式）…'
# -u：无缓冲输出，崩溃 traceback 实时落盘（排查宕机原因不留盲区）
& $python.Source '-u' (Join-Path $root 'backend\serve.py') *>> (Join-Path $root 'logs\backend_console.log')
