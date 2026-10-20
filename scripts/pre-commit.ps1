<#
.SYNOPSIS
    git 提交前门禁：暂存的 .ps1/.psm1 必须通过 ps-lint。
.DESCRIPTION
pre-commit.ps1 - git 提交前门禁：对本次暂存的 .ps1/.psm1 跑 ps-lint，不通过就拦截提交
用法: pwsh pre-commit.ps1 [-Lint <ps-lint.ps1>]
通常由 .git/hooks/pre-commit 调用（见 install-hooks.ps1），也可手动跑做本地预演。
退出码: 0=放行（含"不在 git 仓库内"与"没有暂存脚本"）  1=拦截
设计取舍: 只跑 ps-lint，不跑 fix（会自动改内容、破坏"暂存区 == 你确认过的内容"），
          也不跑 -Verify（pre-commit 里执行任意脚本风险与耗时都不可接受）。
.EXAMPLE
    pwsh pre-commit.ps1
#>
# Write-Host 用于 CLI 人类可读输出，属刻意使用
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [string]$Lint = (Join-Path $PSScriptRoot 'ps-lint.ps1')
)

# PowerShell 7 门禁：用运行时判断，不用 #Requires —— 后者在 5.1 下以 exit 1 中止，
# 与"存在语法错误"的退出码撞车，CI 分不清"环境不对"和"脚本有错"。
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: 需要 PowerShell 7+，当前 $($PSVersionTable.PSVersion)。这是调用环境问题（exit 2），不是脚本语法错误。"
    exit 2
}

$ErrorActionPreference = 'Stop'

# 同 ps-guard：用当前引擎自身的路径，避免 PATH 缺失导致子进程起不来、$LASTEXITCODE 残留 0 而假通过
$pwshExe = $null
try { $pwshExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $null = $_ }
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) {
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshExe = if ($c) { $c.Source } else { $null }
}
if (-not $pwshExe) {
    Write-Host 'ERROR: 找不到 pwsh，门禁无法执行（放行而不是假装通过）'
    exit 2
}

if (-not (Test-Path -LiteralPath $Lint)) {
    Write-Host "WARN: 找不到 ps-lint（$Lint），跳过门禁"
    exit 0
}

$staged = & git diff --cached --name-only --diff-filter=ACM 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host '提示: 当前不在 git 仓库内，跳过 ps-lint 门禁'
    exit 0
}

$repoRoot = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { exit 0 }

$targets = [System.Collections.Generic.List[string]]::new()
foreach ($rel in @($staged)) {
    if ($rel -notmatch '\.ps(m)?1$') { continue }
    $abs = Join-Path ([string]$repoRoot) $rel
    if (Test-Path -LiteralPath $abs -PathType Leaf) { $targets.Add($abs) }
}

if ($targets.Count -eq 0) {
    Write-Host '提示: 本次提交没有暂存的 PowerShell 脚本，跳过门禁'
    exit 0
}

Write-Host "ps-lint 门禁: 检查 $($targets.Count) 个暂存脚本"
$out = & $pwshExe -NoProfile -File $Lint @($targets.ToArray()) 2>&1
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 2 }
foreach ($l in $out) { Write-Host ([string]$l) }

if ($code -eq 0) {
    Write-Host '门禁通过'
    exit 0
}

Write-Host ''
Write-Host "提交被拦截（ps-lint exit $code）"
Write-Host '  语法错(1):  pwsh scripts\fix-ps-punct.ps1 <文件> → git add → 重新提交'
Write-Host '  符号比较(3): 把 > 改成 -gt/-ge/-lt/-le → git add → 重新提交'
Write-Host '  调用错误(2): 文件路径/权限问题，与脚本内容无关'
Write-Host '  想跳过这一次: git commit --no-verify（仅限确认过风险时）'
exit 1
