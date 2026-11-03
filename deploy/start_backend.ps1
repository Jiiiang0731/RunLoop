# RunLoop 后端启动脚本（生产模式）
#
# 形态：waitress 仅监听 127.0.0.1:8000 —— 校园局域网/公网都碰不到这个端口。
# 对外暴露统一走 Tailscale Serve（见 setup_tailscale_serve.ps1）。
#
# 高德 Web Key：由 backend/server.py 读取 config/amap_key.local（已 gitignore），
# 或通过环境变量 RUNLOOP_AMAP_KEY 注入。Key 绝不进入 Git/日志/响应。
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$env:RUNLOOP_ENV  = 'production'
$env:RUNLOOP_HOST = '127.0.0.1'
$env:RUNLOOP_PORT = '8000'

# 控制台输出留痕（业务访问日志另见 logs/runloop-api.log，已脱敏）
New-Item -ItemType Directory -Force -Path (Join-Path $root 'logs') | Out-Null

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { throw '未找到 python，可执行文件需在 PATH 中' }

Write-Host 'RunLoop 后端启动中（127.0.0.1:8000，生产模式）…'
& $python.Source (Join-Path $root 'backend\serve.py') *>> (Join-Path $root 'logs\backend_console.log')
