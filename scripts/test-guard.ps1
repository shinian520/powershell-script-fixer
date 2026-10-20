<#
.SYNOPSIS
    ps-guard 的 9 例行为回归。
.DESCRIPTION
test-guard.ps1 - ps-guard.ps1 的行为回归（9 例）
用法: pwsh test-guard.ps1 [-Case <关键字>] [-Keep] [-WorkDir <目录>] [-Guard <ps-guard.ps1>]
默认在系统临时目录建工作区，跑完删除（-Keep 保留以便看现场）。
退出码: 0=全部通过  1=存在失败  2=被测工具缺失或 -Case 无匹配
.EXAMPLE
    pwsh test-guard.ps1 -Case guard-0
#>
# Write-Host 用于 CLI 人类可读输出，属刻意使用
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [string]$Case = '*',
    [switch]$Keep,
    [string]$WorkDir,
    [string]$Guard = (Join-Path $PSScriptRoot 'ps-guard.ps1')
)

# PowerShell 7 门禁：用运行时判断，不用 #Requires —— 后者在 5.1 下以 exit 1 中止，
# 与"存在语法错误"的退出码撞车，CI 分不清"环境不对"和"脚本有错"。
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: 需要 PowerShell 7+，当前 $($PSVersionTable.PSVersion)。这是调用环境问题（exit 2），不是脚本语法错误。"
    exit 2
}

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Guard)) {
    Write-Host "ERROR: 找不到被测工具 $Guard"
    exit 2
}

# 子进程用当前引擎自身路径，不查 PATH（与 ps-guard 一致）
$pwshExe = $null
try { $pwshExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $null = $_ }
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) {
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshExe = if ($c) { $c.Source } else { $null }
}
if (-not $pwshExe) { Write-Host 'ERROR: 找不到 pwsh'; exit 2 }

$Work = if ($WorkDir) { $WorkDir } else { Join-Path ([IO.Path]::GetTempPath()) ('guard-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
New-Item -ItemType Directory -Force -Path $Work | Out-Null

$FF0C = [char]0xFF0C   # ，
$FF1E = [char]0xFF1E   # ＞
$FF5B = [char]0xFF5B   # ｛
$FF5D = [char]0xFF5D   # ｝

function Set-File([string]$name, [string]$text, $encoding) {
    $p = Join-Path $Work $name
    $enc = if ($encoding) { $encoding } else { [Text.UTF8Encoding]::new($true) }
    [IO.File]::WriteAllText($p, $text, $enc)
    return $p
}

function Invoke-Guard([string[]]$guardArgs) {
    $out = & $pwshExe -NoProfile -File $Guard @guardArgs 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
}

$passed = 0; $failed = 0
function Assert([string]$name, [bool]$ok, [string]$info) {
    if ($ok) {
        $script:passed += 1
        Write-Host "PASS  $name"
    } else {
        $script:failed += 1
        Write-Host "FAIL  $name"
        if ($info) { Write-Host ('      ' + $info) }
    }
}

$all = @(
    @{ Id = 'guard-01'; Test = {
            $f = Set-File 'clean.ps1' "`$x = 1`nWrite-Host `$x`n"
            $r = Invoke-Guard @($f)
            Assert 'guard-01 干净文件 exit 0' ($r.Code -eq 0) "exit=$($r.Code)`n$($r.Text)"
        }
    }
    @{ Id = 'guard-02'; Test = {
            $f = Set-File 'polluted.ps1' "`$names = @(`"a.log`"$FF0C`n  `"b.log`"`n)`n"
            $r = Invoke-Guard @($f)
            $body = Get-Content -LiteralPath $f -Raw
            Assert 'guard-02 全角自愈后 exit 0 且内容已修' (($r.Code -eq 0) -and (-not $body.Contains($FF0C))) "exit=$($r.Code)`n$($r.Text)"
        }
    }
    @{ Id = 'guard-03'; Test = {
            $f = Set-File 'compare.ps1' "`$n = 5`nif (`$n > 0) { Write-Host ok }`n"
            $r = Invoke-Guard @($f)
            Assert 'guard-03 符号比较 exit 3' (($r.Code -eq 3) -and $r.Text.Contains('NEEDS_OPERATOR')) "exit=$($r.Code)`n$($r.Text)"
        }
    }
    @{ Id = 'guard-04'; Test = {
            # 夹具必须有真 ParseError：`$a = 1，` 这类行尾全角逗号会被 tokenizer 并进裸词、ps-lint 判 OK（已知盲区 7）
            $f = Set-File 'nofix.ps1' "`$names = @(`"a.log`"$FF0C`n  `"b.log`"`n)`n"
            $r = Invoke-Guard @($f, '-NoFix')
            $body = Get-Content -LiteralPath $f -Raw
            Assert 'guard-04 -NoFix 不回灌且文件未改' (($r.Code -eq 1) -and $body.Contains($FF0C)) "exit=$($r.Code)`n$($r.Text)"
        }
    }
    @{ Id = 'guard-05'; Test = {
            $f = Set-File 'broken.ps1' "`$s = `"未闭合`n"
            $r = Invoke-Guard @($f)
            Assert 'guard-05 结构性错误 exit 1 FEEDBACK' (($r.Code -eq 1) -and $r.Text.Contains('FEEDBACK')) "exit=$($r.Code)`n$($r.Text)"
        }
    }
    @{ Id = 'guard-06'; Test = {
            $missing = Join-Path $Work 'nope.ps1'
            $r = Invoke-Guard @($missing)
            Assert 'guard-06 路径不存在 exit 2' (($r.Code -eq 2) -and $r.Text.Contains('IO_ERROR')) "exit=$($r.Code)`n$($r.Text)"
        }
    }
    @{ Id = 'guard-07'; Test = {
            $f = Set-File 'runok.ps1' "Write-Host ok`n"
            $r = Invoke-Guard @($f, '-Verify')
            Assert 'guard-07 -Verify 试跑通过 exit 0' ($r.Code -eq 0) "exit=$($r.Code)`n$($r.Text)"
        }
    }
    @{ Id = 'guard-08'; Test = {
            $f = Set-File 'runbad.ps1' "`$x = 1`nif (`$x -eq 1) { throw 'boom' }`n"
            $r = Invoke-Guard @($f, '-Verify')
            Assert 'guard-08 -Verify 捕获运行期失败 exit 1' (($r.Code -eq 1) -and $r.Text.Contains('RUNTIME_FAIL')) "exit=$($r.Code)`n$($r.Text)"
        }
    }
    @{ Id = 'guard-09'; Test = {
            $f = Set-File 'json.ps1' "`$x = 1`n"
            $r = Invoke-Guard @($f, '-AsJson')
            $parsed = $null
            try { $parsed = $r.Text | ConvertFrom-Json } catch { $parsed = $null }
            Assert 'guard-09 -AsJson 可解析且含 status' (($null -ne $parsed) -and ($parsed[0].status -eq 'OK')) "exit=$($r.Code)`n$($r.Text)"
        }
    }
)

Write-Host "被测工具: $Guard"
Write-Host "工作目录: $Work"
Write-Host '--------------------------------'

$matched = @($all | Where-Object { $_.Id -like $Case })
if ($matched.Count -eq 0) {
    Write-Host "ERROR: -Case '$Case' 无匹配用例（不允许 0 通过 0 失败）"
    if (-not $Keep) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
    exit 2
}

foreach ($c in $matched) { & $c.Test }

Write-Host '--------------------------------'
Write-Host ("通过: {0}  失败: {1}" -f $passed, $failed)

if (-not $Keep) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
if ($failed -gt 0) { exit 1 }
exit 0
