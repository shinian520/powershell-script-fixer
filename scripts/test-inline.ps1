#Requires -Version 7
<#
.SYNOPSIS
    -Inline 模式回归：AI 直接执行的 pwsh 语句（不落盘）能否被同样地预检/自愈/试跑。
.DESCRIPTION
    7 例：lint 干净 / lint 全角 / lint 符号比较 / guard 自愈 / guard -Verify 抓运行期错 /
    标准输入（中文不得乱码）/ 无输入必须报参数错。
    退出码 0 = 全部通过。
.EXAMPLE
    pwsh scripts\test-inline.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param()

$ErrorActionPreference = 'Stop'

$lint = Join-Path $PSScriptRoot 'ps-lint.ps1'
$guard = Join-Path $PSScriptRoot 'ps-guard.ps1'
foreach ($t in @($lint, $guard)) {
    if (-not (Test-Path -LiteralPath $t)) { Write-Host "ERROR: 缺少 $t"; exit 2 }
}

# 子进程用当前引擎自身路径，不查 PATH（与 ps-guard 一致）
$pwshExe = $null
try { $pwshExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $null = $_ }
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) {
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshExe = if ($c) { $c.Source } else { $null }
}
if (-not $pwshExe) { Write-Host 'ERROR: 找不到 pwsh'; exit 2 }

$passed = 0
$failed = 0
function Assert([string]$name, [bool]$ok, [string]$info) {
    if ($ok) { $script:passed += 1; Write-Host "PASS  $name" }
    else { $script:failed += 1; Write-Host "FAIL  $name"; if ($info) { Write-Host ('      ' + $info) } }
}

$FF0C = [char]0xFF0C
$fullwidth = '$x = @("a"' + $FF0C + ' "b")'

# 1) 干净语句
$o = & $pwshExe -NoProfile -File $lint -Inline '$x = 1' 2>&1; $c = $LASTEXITCODE
Assert 'inline-01 lint 干净语句 exit 0' (($c -eq 0) -and (($o -join '').Contains('OK'))) "exit=$c"

# 2) 全角标点
$o = & $pwshExe -NoProfile -File $lint -Inline $fullwidth 2>&1; $c = $LASTEXITCODE
Assert 'inline-02 lint 全角 exit 1' ($c -eq 1) "exit=$c"

# 3) 符号比较
$o = & $pwshExe -NoProfile -File $lint -Inline 'if ($n > 0) { 1 }' 2>&1; $c = $LASTEXITCODE
Assert 'inline-03 lint 符号比较 exit 3' ($c -eq 3) "exit=$c"

# 4) guard 自愈并把修好的语句打回来
$o = & $pwshExe -NoProfile -File $guard -Inline $fullwidth 2>&1; $c = $LASTEXITCODE
$fixed = ($o -join "`n")
Assert 'inline-04 guard 自愈 exit 0 且给出修后语句' (($c -eq 0) -and $fixed.Contains('$x = @("a", "b")')) "exit=$c`n$fixed"

# 5) -Verify 抓运行期错
$o = & $pwshExe -NoProfile -File $guard -Inline 'throw "boom"' -Verify 2>&1; $c = $LASTEXITCODE
Assert 'inline-05 guard -Verify 运行期失败 exit 1' ($c -eq 1) "exit=$c"

# 6) 标准输入：中文/全角不得乱码
$fromStdin = $fullwidth | & $pwshExe -NoProfile -File $guard -Inline - 2>&1
$c = $LASTEXITCODE
$text = ($fromStdin -join "`n")
Assert 'inline-06 标准输入中文不乱码且修好' (($c -eq 0) -and $text.Contains('$x = @("a", "b")') -and -not $text.Contains('锛')) "exit=$c`n$text"

# 7) 既无文件也无语句 → 参数错
$o = & $pwshExe -NoProfile -File $guard 2>&1; $c = $LASTEXITCODE
Assert 'inline-07 无输入 exit 2' ($c -eq 2) "exit=$c"

# 8) 内联模式不得在临时目录留垃圾
$leftover = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Filter 'psguard-inline-*' -ErrorAction SilentlyContinue).Count
Assert 'inline-08 临时目录无残留' ($leftover -eq 0) "残留=$leftover"

Write-Host '--------------------------------'
Write-Host ("通过: {0}  失败: {1}" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
