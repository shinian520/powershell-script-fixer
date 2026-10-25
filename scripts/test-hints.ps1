#Requires -Version 7
<#
.SYNOPSIS
    报错细化回归：分类 / 可疑字符码位 / 可自动修 / 建议 / 上下文 / 汇总。
.DESCRIPTION
    6 例，全部走 -AsJson 断言结构化字段（人读输出另有两条子串断言）。
    退出码 0 = 全部通过。
.EXAMPLE
    pwsh scripts\test-hints.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param()

$ErrorActionPreference = 'Stop'

$lint = Join-Path $PSScriptRoot 'ps-lint.ps1'
if (-not (Test-Path -LiteralPath $lint)) { Write-Host "ERROR: 缺少 $lint"; exit 2 }

$pwshExe = $null
try { $pwshExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $null = $_ }
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) {
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshExe = if ($c) { $c.Source } else { $null }
}
if (-not $pwshExe) { Write-Host 'ERROR: 找不到 pwsh'; exit 2 }

$work = Join-Path ([IO.Path]::GetTempPath()) ('hints-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$nl = [char]10

$passed = 0
$failed = 0
function Assert([string]$name, [bool]$ok, [string]$info) {
    if ($ok) { $script:passed += 1; Write-Host "PASS  $name" }
    else { $script:failed += 1; Write-Host "FAIL  $name"; if ($info) { Write-Host ('      ' + $info) } }
}
function Set-Fixture([string]$name, [string]$text) {
    $p = Join-Path $work $name
    [IO.File]::WriteAllText($p, $text, [Text.UTF8Encoding]::new($false))
    return $p
}
function Get-Json([string]$path) {
    $raw = & $pwshExe -NoProfile -File $lint $path -AsJson 2>&1
    return ($raw -join "`n") | ConvertFrom-Json
}

# 1) 全角标点：分类 + 可自动修 + 码位
$f = Set-Fixture 'fw.ps1' ('$names = @("a.log"' + [char]0xFF0C + $nl + '  "b.log"' + $nl + ')' + $nl)
$o = Get-Json $f
$e = $o[0].errors[0]
Assert 'hint-01 全角分类/可自动修/码位' (
    ($e.category -eq '全角/非 ASCII 标点') -and ($e.autoFixable -eq $true) -and ($e.codePoint -eq 'U+FF0C')
) "cat=$($e.category) auto=$($e.autoFixable) cp=$($e.codePoint)"

# 2) 缺右花括号：结构性，不可自动修
$f = Set-Fixture 'brace.ps1' ('function X {' + $nl + '  $a = 1' + $nl)
$o = Get-Json $f
$e = $o[0].errors[0]
Assert 'hint-02 缺括号分类=括号未闭合且不可自动修' (
    ($e.category -eq '括号/引号未闭合') -and ($e.autoFixable -eq $false)
) "cat=$($e.category) auto=$($e.autoFixable)"

# 3) 哈希表冒号
$f = Set-Fixture 'hash.ps1' ('$h = @{' + $nl + "  name: 'a'" + $nl + '}' + $nl)
$o = Get-Json $f
Assert 'hint-03 哈希表语法分类且提示要改成 =' (
    ($o[0].errors[0].category -eq '哈希表语法') -and ($o[0].errors[0].hint -match '等号')
) "cat=$($o[0].errors[0].category) hint=$($o[0].errors[0].hint)"

# 4) 未闭合字符串
$f = Set-Fixture 'str.ps1' ('$s = "oops' + $nl)
$o = Get-Json $f
Assert 'hint-04 字符串未闭合分类' ($o[0].errors[0].category -eq '字符串未闭合') "cat=$($o[0].errors[0].category)"

# 5) 上下文与汇总：errors[].context 非空、含出错行源码；summary.byCategory 计数 == 错误数
$f = Set-Fixture 'ctx.ps1' ('$n = 5' + $nl + 'if ($n ' + [char]0xFF1E + ' 0) { 1 }' + $nl)
$o = Get-Json $f
$ctx = @($o[0].errors[0].context)
$ctxOk = ($ctx.Count -ge 2) -and ([bool](@($ctx) | Where-Object { $_ -match '^\s+> ' }))
$sumOk = (($o[0].summary.byCategory.PSObject.Properties | Measure-Object -Property Value -Sum).Sum -eq $o[0].count)
Assert 'hint-05 上下文含源码行且汇总计数一致' ($ctxOk -and $sumOk) "ctx=$($ctx.Count) ctxOk=$ctxOk sumOk=$sumOk"

# 6) 人读输出：分类/建议/汇总三字样齐全，且每条错误都有一行 LxCx
$raw = (& $pwshExe -NoProfile -File $lint $f 2>&1) -join "`n"
$total = [int]([regex]::Match($raw, 'FAIL: (\d+)').Groups[1].Value)
$listed = @($raw -split "`n" | Where-Object { $_ -match '^\s+L\d+C\d+:' }).Count
Assert 'hint-06 人读输出含分类/建议/汇总且条目完整' (
    $raw.Contains('分类:') -and $raw.Contains('建议:') -and $raw.Contains('汇总:') -and ($listed -eq $total)
) "listed=$listed total=$total`n$raw"

Write-Host '--------------------------------'
Write-Host ("通过: {0}  失败: {1}" -f $passed, $failed)
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
if ($failed -gt 0) { exit 1 }
exit 0
