# 防睡眠设置（可选，需用户明确同意后运行 —— 阶段 K 规范⑪）
#
# ⚠️ 本脚本修改 Windows 电源设置，只做两件事、且仅限「接通电源(AC)」：
#   1. 展示当前 AC 待机/休眠超时；
#   2. 交互确认后把 AC 待机超时设为「从不」（0）。
# 不改电池(DC)策略、不改屏幕关闭时间、不动其他任何电源项。
# 手机侧无需设置：跑步时 App 保持屏幕常亮（WakeLock），与电脑睡眠无关。
#
# 恢复默认（例如 30 分钟）：powercfg /change standby-timeout-ac 30
$ErrorActionPreference = 'Stop'

Write-Host '=== 当前电源设置（AC=接通电源）==='
powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE |
    Select-String 'AC|当前交流|Current AC' | ForEach-Object { Write-Host $_.ToString().Trim() }

Write-Host ''
Write-Host '本脚本将执行：powercfg /change standby-timeout-ac 0'
Write-Host '效果：接通电源时电脑永不自动待机（后端/Tailscale 保持在线）。'
Write-Host '不修改：电池策略、屏幕关闭时间、手动睡眠按钮行为。'
Write-Host ''

$answer = Read-Host '确认修改吗？输入 yes 继续，其他任意键取消'
if ($answer -ne 'yes') {
    Write-Host '已取消，未做任何修改。'
    exit 0
}

powercfg /change standby-timeout-ac 0
Write-Host '✅ 已设置：接通电源时不自动待机。'
Write-Host '如需恢复：powercfg /change standby-timeout-ac 30'
Write-Host ''
Write-Host '补充（不改设置的做法）：临时保持唤醒可在需要时手动运行'
Write-Host '  powercfg /requestsoverride PROCESS svchost.exe SYSTEM  （不需要，仅说明）'
Write-Host '或跑马期间用 presentationsettings /start，结束后 /stop。'
