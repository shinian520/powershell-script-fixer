<#
.SYNOPSIS
    把 pre-commit 门禁装进当前 git 仓库（或卸载）。
.DESCRIPTION
install-hooks.ps1 - 把 pre-commit 门禁装进当前 git 仓库（或卸载）
用法: pwsh install-hooks.ps1            # 安装/更新
      pwsh install-hooks.ps1 -Uninstall # 移除本工具写入的钩子
行为: 在 <git-dir>/hooks/pre-commit 写一个 sh 转发脚本（LF 换行、无 BOM），
      转调本目录的 pre-commit.ps1；已存在他人钩子时拒绝覆盖（除非 -Force，会先备份）。
退出码: 0=成功  2=不在 git 仓库 / 写入失败 / 已有他人钩子
.EXAMPLE
    pwsh install-hooks.ps1 -Uninstall
#>
# Write-Host 用于 CLI 人类可读输出，属刻意使用
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [switch]$Uninstall,
    [switch]$Force
)

# PowerShell 7 门禁：用运行时判断，不用 #Requires —— 后者在 5.1 下以 exit 1 中止，
# 与"存在语法错误"的退出码撞车，CI 分不清"环境不对"和"脚本有错"。
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: 需要 PowerShell 7+，当前 $($PSVersionTable.PSVersion)。这是调用环境问题（exit 2），不是脚本语法错误。"
    exit 2
}

$ErrorActionPreference = 'Stop'

$gitDir = & git rev-parse --git-dir 2>$null
if ($LASTEXITCODE -ne 0 -or -not $gitDir) {
    Write-Host 'ERROR: 当前目录不在 git 仓库内，先在项目根目录 git init'
    exit 2
}
$top = [string](& git rev-parse --show-toplevel)
if (-not [IO.Path]::IsPathRooted([string]$gitDir)) { $gitDir = Join-Path (Get-Location).Path ([string]$gitDir) }

$hooksDir = Join-Path ([string]$gitDir) 'hooks'
$hookPath = Join-Path $hooksDir 'pre-commit'
$marker = '# managed-by: powershell-script-fixer'

if ($Uninstall) {
    if (Test-Path -LiteralPath $hookPath) {
        $cur = Get-Content -LiteralPath $hookPath -Raw
        if ($cur -like "*$marker*") {
            Remove-Item -LiteralPath $hookPath -Force
            Write-Host "已移除门禁: $hookPath"
        } else {
            Write-Host "未改动: $hookPath 不是本工具写入的（缺少标记行）"
        }
    } else {
        Write-Host "未发现钩子: $hookPath"
    }
    exit 0
}

New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null

if ((Test-Path -LiteralPath $hookPath) -and -not $Force) {
    $cur = Get-Content -LiteralPath $hookPath -Raw
    if ($cur -notlike "*$marker*") {
        Write-Host "ERROR: 已存在非本工具写入的钩子 $hookPath；确认覆盖请加 -Force（会先备份为 .bak-时间戳）"
        exit 2
    }
}
if (Test-Path -LiteralPath $hookPath) {
    $bak = '{0}.bak-{1}' -f $hookPath, (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    Copy-Item -LiteralPath $hookPath -Destination $bak -Force
    Write-Host "已备份原钩子: $bak"
}

$preCommit = Join-Path $PSScriptRoot 'pre-commit.ps1'
$rel = [IO.Path]::GetRelativePath($top, $preCommit) -replace '\\', '/'

# sh 钩子必须 LF + 无 BOM；用 WriteAllText 精确控制字节
$sh = @(
    '#!/bin/sh'
    $marker
    '# 转调 PowerShell 侧门禁，逻辑见 scripts/pre-commit.ps1'
    'TOP=$(git rev-parse --show-toplevel) || exit 0'
    ('exec pwsh -NoProfile -File "$TOP/{0}"' -f $rel)
) -join "`n"
[IO.File]::WriteAllText($hookPath, $sh + "`n", [Text.UTF8Encoding]::new($false))

# 非 Windows 平台需要可执行位；失败不致命，给出提示即可
try { & chmod 755 $hookPath 2>$null } catch { $null = $_ }

Write-Host "已安装门禁: $hookPath"
Write-Host "  转调: $rel"
Write-Host '  暂停某一次: git commit --no-verify'
Write-Host '  移除: pwsh install-hooks.ps1 -Uninstall'
exit 0
