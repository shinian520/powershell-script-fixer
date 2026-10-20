<#
.SYNOPSIS
    把本技能安装/更新到 .dsh/skills，自动解 MOTW 并做安装位自检。
.DESCRIPTION
install.ps1 - 把本技能安装（或更新）到 DeepSeek Harness 的 skills 目录
用法: pwsh install.ps1 [-Destination <skills 目录>] [-Force]
默认目标: %USERPROFILE%\.dsh\skills
行为: 复制技能根目录（本脚本所在目录的上一级）到 <Destination>\powershell-script-fixer；
      已存在同名目录时需 -Force 才会覆盖（防误删用户改动）。
退出码: 0=安装成功  2=参数/文件系统错误
.EXAMPLE
    pwsh install.ps1 -Force -Destination D:\skills
#>
# Write-Host 用于 CLI 人类可读输出（配合 exit code 供管道/CI 消费），属刻意使用
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [string]$Destination = (Join-Path $HOME '.dsh\skills'),
    [switch]$Force
)

# PowerShell 7 门禁：用运行时判断，不用 #Requires —— 后者在 5.1 下以 exit 1 中止，
# 与"存在语法错误"的退出码撞车，CI 分不清"环境不对"和"脚本有错"。
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: 需要 PowerShell 7+，当前 $($PSVersionTable.PSVersion)。这是调用环境问题（exit 2），不是脚本语法错误。"
    exit 2
}

$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$skillName = Split-Path -Leaf $skillRoot
$target = Join-Path $Destination $skillName

# 自检子进程用当前引擎自身路径，不查 PATH（受限账户里 PATH 可能不含 pwsh）
$pwshExe = $null
try { $pwshExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $null = $_ }
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) {
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshExe = if ($c) { $c.Source } else { $null }
}

if (-not (Test-Path -LiteralPath (Join-Path $skillRoot 'SKILL.md'))) {
    Write-Host "ERROR: 找不到 $skillRoot\SKILL.md，本脚本必须放在技能包内 scripts\ 目录下运行"
    exit 2
}

if ((Test-Path -LiteralPath $target) -and -not $Force) {
    Write-Host "ERROR: 目标已存在 $target；确认覆盖请加 -Force"
    exit 2
}

# 自我覆盖保护：当脚本本身就位于目标路径（"就地更新"）时，Remove-Item 会先删掉
# 正在运行的自己与复制源，随后 Copy-Item 必然失败，留下一个残缺的技能目录。
$srcFull = [IO.Path]::GetFullPath($skillRoot).TrimEnd('\', '/')
$dstFull = [IO.Path]::GetFullPath($target).TrimEnd('\', '/')
if ($srcFull -eq $dstFull) {
    Write-Host "ERROR: 当前包就在目标位置（$target），无法就地自我覆盖。"
    Write-Host '       请从包外目录运行 install.ps1，或先删除该目录再从解压出的新包安装。'
    exit 2
}

try {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -LiteralPath $skillRoot -Destination $target -Recurse -Force
} catch {
    Write-Host "ERROR: 安装失败 - $($_.Exception.Message)"
    exit 2
}

$guard = Join-Path $target 'scripts\ps-guard.ps1'
Write-Host "已安装: $target"

# 解 MOTW：从市场/浏览器下载的 ZIP 解出来的 .ps1 带 Zone.Identifier，
# 在 RemoteSigned 策略下会被判为"未签名远程脚本"而拒绝执行，表现为技能装好却跑不动。
if (-not $IsMacOS -and -not $IsLinux) {
    try {
        Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        Write-Host '已解除下载标记（Unblock-File）'
    } catch {
        Write-Host "WARN: Unblock-File 失败 - $($_.Exception.Message)"
    }
    $pol = Get-ExecutionPolicy
    if ($pol -in @('Restricted', 'AllSigned')) {
        Write-Host "WARN: 当前执行策略为 $pol，未签名脚本会被拒绝。可临时用 pwsh -ExecutionPolicy Bypass -File ... 运行"
    }
}

# 注意：必须是 ((Test-Path ...) -and $x)，直接写 `Test-Path -LiteralPath $g -and $x`
# 会把 -and 当成 Test-Path 的参数名并抛 "parameter cannot be found that matches parameter name 'and'"
if ((Test-Path -LiteralPath $guard) -and $pwshExe) {
    $r = & $pwshExe -NoProfile -File $guard (Join-Path $target 'scripts\ps-lint.ps1')
    if ($LASTEXITCODE -eq 0) {
        Write-Host '自检: ps-guard 对包内 ps-lint.ps1 判定通过（exit 0）'
    } else {
        Write-Host "WARN: 安装位自检退出码 $LASTEXITCODE，建议复查 $target"
    }
}
exit 0
