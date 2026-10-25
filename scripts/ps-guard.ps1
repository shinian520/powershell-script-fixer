<#
.SYNOPSIS
    一条命令闭环：预检 -> 自愈 -> 复检 -> Stop 模式试跑，只回一个退出码与一句 ACTION。
.DESCRIPTION
ps-guard.ps1 - 一条命令完成「预检 -> 自愈 -> 复检 -> 试跑」的 PowerShell 脚本守卫

用法:
  pwsh ps-guard.ps1 <file.ps1> [<file2.ps1> ...] [-NoFix] [-Verify] [-TimeoutSec 30] [-AsJson]
  pwsh ps-guard.ps1 -Inline "if ($x > 0) { 'a' }" [-Verify]     # AI 直接执行的语句
  Get-Content x.ps1 -Raw | pwsh ps-guard.ps1 -Inline -           # 从标准输入读

退出码: 0=通过（语法干净，试跑通过）
        1=需回灌重写（仍有语法错 / 试跑失败），报错已抓取，可直接贴回模型
        2=读取/调用错误（路径不存在、传入目录、缺工具、未给输入）
        3=需人工处理（检出 `>` 当比较用的写法，须改 -gt/-ge/-lt/-le）
  多目标取最严重，优先级 2 > 1 > 3 > 0（与 ps-lint / fix-ps-punct 一致）。
默认行为：发现语法错就调 fix-ps-punct 自愈；-NoFix 关闭自愈；-Verify 额外做 Stop 模式试跑。
.PARAMETER Path
    一个或多个 .ps1 路径。与 -Inline 二选一。
.PARAMETER Inline
    直接给一段语句/脚本文本；内部写入临时文件走同一条闭环，结束后打印修好的语句并删除临时文件。
.PARAMETER NoFix
    只诊断，不改文件。
.PARAMETER Verify
    额外用 Stop 模式另起进程试跑（抓"语法合法但运行期错"）。
.PARAMETER TimeoutSec
    试跑超时秒数，默认 30。
.PARAMETER AsJson
    结构化输出；-Inline 时返回单个对象（含 fixed 字段）。
.EXAMPLE
    pwsh ps-guard.ps1 script.ps1 -Verify
.EXAMPLE
    pwsh ps-guard.ps1 -Inline 'if ($n > 0) { Write-Host ok }'
#>
# Write-Host 用于 CLI 人类可读输出（配合 exit code 供管道/CI 消费），属刻意使用
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Path,
    [string]$Inline,
    [switch]$NoFix,
    [switch]$Verify,
    [int]$TimeoutSec = 30,
    [switch]$AsJson,
    [switch]$AllowLegacy
)

# 版本门禁：默认要求 PowerShell 7；只有 5.1 的机器可用 -AllowLegacy（或环境变量 PSFIX_ALLOW_LEGACY=1）降级运行。
# 刻意不用 #Requires —— 它在 5.1 下直接以 exit 1 中止，会与"存在语法错误"的退出码撞车，CI 分不清。
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $legacyAllowed = ($AllowLegacy -eq $true) -or ($env:PSFIX_ALLOW_LEGACY -eq '1')
    if (-not $legacyAllowed) {
        Write-Host "ERROR: 需要 PowerShell 7+（当前 $($PSVersionTable.PSVersion)）。这是调用环境问题（exit 2），不是脚本语法错误。"
        Write-Host '       目标机只有 5.1：加 -AllowLegacy 或设 PSFIX_ALLOW_LEGACY=1 降级运行；差异见 references/powershell-versions.md'
        exit 2
    }
    Write-Host "WARN: 以 Windows PowerShell $($PSVersionTable.PSVersion) 降级运行（JSON 转义与启动开销可能与 7 不同）"
    # 让子工具（ps-lint / fix-ps-punct）也走降级，否则它们各自以 exit 2 拒绝，
    # 会被本脚本误判成"调用错误"，把真实结果盖掉。
    $env:PSFIX_ALLOW_LEGACY = '1'
}

$ErrorActionPreference = 'Stop'

# -Inline：把语句写进临时文件，走完全相同的闭环；结束时打印修好的语句并删除临时文件。
# 这样不必为"语句"再写一套解析/修复逻辑，语句与脚本的行为天然一致。
$inlineTmp = $null
$inlineMode = $false
if ($Inline -eq '-' -and [Console]::IsInputRedirected) {
    # 按字节读标准输入再显式按 UTF-8 解码：直接 [Console]::In.ReadToEnd() 会走控制台输入编码（常是 GBK），
    # 导致管道传入的中文/全角字符变乱码（实测 "，" → "锛?"）。
    $ms = [IO.MemoryStream]::new()
    [Console]::OpenStandardInput().CopyTo($ms)
    $bytes = $ms.ToArray()
    try { $Inline = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { $Inline = [Console]::InputEncoding.GetString($bytes) }
}
if ($PSBoundParameters.ContainsKey('Inline') -and $Inline -ne '') {
    $inlineMode = $true
    $inlineTmp = Join-Path ([IO.Path]::GetTempPath()) ('psguard-inline-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($inlineTmp, $Inline, [Text.UTF8Encoding]::new($false))
    $Path = @($inlineTmp)
}
if (-not $Path) {
    Write-Host 'ERROR: 需要给出文件路径，或用 -Inline 传入语句文本'
    exit 2
}

$lintTool = Join-Path $PSScriptRoot 'ps-lint.ps1'
$fixTool = Join-Path $PSScriptRoot 'fix-ps-punct.ps1'
foreach ($t in @($lintTool, $fixTool)) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host "ERROR: 缺少工具 $t"
        exit 2
    }
}

# 子进程一律用"当前引擎自己的可执行文件"，不查 PATH。
# 原因：受限服务账户/精简容器里 PATH 可能不含 pwsh，此时 `& pwsh` 会失败，
# 而失败时 $LASTEXITCODE 保持旧值（常见为 0）→ 被判成"通过"，属于最危险的静默假阳性。
$pwshExe = $null
try { $pwshExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $null = $_ }
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshExe = if ($cmd) { $cmd.Source } else { $null }
}
if (-not $pwshExe) {
    Write-Host 'ERROR: 找不到 PowerShell 7 可执行文件（pwsh），无法调用 ps-lint / fix-ps-punct'
    exit 2
}

# 优先级序数与退出码是两张表：优先级 IO(3) > FEEDBACK(2) > NEEDS_OPERATOR(1) > OK(0)，
# 退出码却是 2/1/3/0。直接比退出码大小会让 3 压住 1（历史 bug，勿改回）。
$rank = @{ 'OK' = 0; 'FIXED' = 0; 'NEEDS_OPERATOR' = 1; 'FEEDBACK' = 2; 'RUNTIME_FAIL' = 2; 'IO_ERROR' = 3 }
$rankToExit = @{ 0 = 0; 1 = 3; 2 = 1; 3 = 2 }
$worst = 0

function Invoke-Tool([string]$tool, [string[]]$toolArgs) {
    $out = & $pwshExe -NoProfile -File $tool @toolArgs 2>&1
    $code = $LASTEXITCODE
    # 子进程没起来时 $LASTEXITCODE 为 $null：必须按调用错误处理，不能落成 0
    if ($null -eq $code) {
        return [pscustomobject]@{ Code = 2; Out = @($out | ForEach-Object { [string]$_ }) + @('子进程未返回退出码（启动失败？），按调用错误处理') }
    }
    return [pscustomobject]@{ Code = [int]$code; Out = @($out | ForEach-Object { [string]$_ }) }
}

function Invoke-ScriptVerify([string]$scriptPath, [int]$limitSec) {
    $tag = [guid]::NewGuid().ToString('N')
    $tmpDir = [IO.Path]::GetTempPath()
    $outFile = Join-Path $tmpDir "$tag.out"
    $errFile = Join-Path $tmpDir "$tag.err"
    $codeFile = Join-Path $tmpDir "$tag.code"
    # 试跑脚本写成临时 .ps1 再用 -File 调用：5.1 的 Start-Process -ArgumentList 不会给含空格的
    # 元素加引号，直接传 "-Command & { ... }" 会被截断，导致试跑永远"通过"（实测踩过）。
    # 退出码由子进程写进哨兵文件：5.1 下 Start-Process -PassThru 的 ExitCode 常为空，
    # 读它会把"成功"误判成失败（实测 ok.ps1 被判 RUNTIME_FAIL）。
    $wrapper = Join-Path $tmpDir "$tag.verify.ps1"
    $safePath = $scriptPath -replace "'", "''"
    $nl2 = [Environment]::NewLine
    $body = @(
        "`$ErrorActionPreference = 'Stop'"
        "`$exitCode = 0"
        "try { & '$safePath' } catch { `$exitCode = 1; Write-Error `$_ }"
        "[IO.File]::WriteAllText('$codeFile', [string]`$exitCode)"
        "exit `$exitCode"
    ) -join $nl2
    [IO.File]::WriteAllText($wrapper, $body + $nl2, [Text.UTF8Encoding]::new($true))
    $timedOut = $false
    try {
        $spArgs = @{
            FilePath               = $pwshExe
            ArgumentList           = ('-NoProfile -File "{0}"' -f $wrapper)
            PassThru               = $true
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
        }
        # -NoNewWindow 只在 Windows 上有意义；5.1 没有 $IsWindows 变量，按版本判定
        $onWindows = ($PSVersionTable.PSVersion.Major -lt 7) -or $IsWindows
        if ($onWindows) { $spArgs['NoNewWindow'] = $true }
        $proc = Start-Process @spArgs
        if (-not $proc.WaitForExit($limitSec * 1000)) {
            $timedOut = $true
            try { $proc.Kill($true) } catch { $null = $_ }
        }
        # 退出码只信哨兵文件：没有它说明子进程没跑到收尾（崩溃/被杀），按 1 处理
        $code = 1
        if ($timedOut) {
            $code = 124
        } elseif (Test-Path -LiteralPath $codeFile) {
            $raw = (Get-Content -LiteralPath $codeFile -Raw -ErrorAction SilentlyContinue)
            if ($raw -and $raw.Trim() -match '^\d+$') { $code = [int]$raw.Trim() }
        }
        $stdout = if (Test-Path -LiteralPath $outFile) { @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue) } else { @() }
        $stderr = if (Test-Path -LiteralPath $errFile) { @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) } else { @() }
        return [pscustomobject]@{ Code = $code; TimedOut = $timedOut; StdOut = @($stdout); StdErr = @($stderr) }
    } finally {
        foreach ($f in @($outFile, $errFile, $wrapper, $codeFile)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($p in $Path) {
    $item = [pscustomobject]@{
        Path = $p; Status = 'OK'; Action = ''; Detail = [System.Collections.Generic.List[string]]::new()
    }

    $resolved = $null
    try {
        $resolved = (Resolve-Path -LiteralPath $p).Path
        if (Test-Path -LiteralPath $resolved -PathType Container) { throw '传入的是目录，不是脚本文件' }
        $item.Path = $resolved
    } catch {
        $item.Status = 'IO_ERROR'; $item.Action = '先修调用与路径，不是脚本的错'
        $item.Detail.Add($_.Exception.Message)
        $results.Add($item); if ($rank[$item.Status] -gt $worst) { $worst = $rank[$item.Status] }
        continue
    }

    $lint = Invoke-Tool $lintTool @($resolved)
    if ($lint.Code -eq 2) {
        $item.Status = 'IO_ERROR'; $item.Action = '先修调用与路径'
        foreach ($l in $lint.Out) { $item.Detail.Add($l) }
        $results.Add($item); if ($rank[$item.Status] -gt $worst) { $worst = $rank[$item.Status] }
        continue
    }

    if ($lint.Code -eq 1) {
        if ($NoFix) {
            $item.Status = 'FEEDBACK'; $item.Action = '用 references/error-feedback-prompt.md 回灌（-NoFix 未尝试自愈）'
            foreach ($l in $lint.Out) { $item.Detail.Add($l) }
        } else {
            $fix = Invoke-Tool $fixTool @($resolved)
            $relint = Invoke-Tool $lintTool @($resolved)
            foreach ($l in $fix.Out) { $item.Detail.Add($l) }
            if ($relint.Code -eq 0) {
                $item.Status = 'FIXED'; $item.Action = '自动修复并复检通过，建议再加 -Verify 试跑一次'
            } elseif ($relint.Code -eq 3) {
                $item.Status = 'NEEDS_OPERATOR'
                $item.Action = '把 > 改成 -gt/-ge/-lt/-le（重定向不是比较），再重跑本工具'
                foreach ($l in $relint.Out) { $item.Detail.Add($l) }
            } else {
                $item.Status = 'FEEDBACK'
                $item.Action = '自动修复不彻底：把下面报错 + 脚本原文一起回灌重写'
                foreach ($l in $relint.Out) { $item.Detail.Add($l) }
            }
        }
    } elseif ($lint.Code -eq 3) {
        $item.Status = 'NEEDS_OPERATOR'
        $item.Action = '把 > 改成 -gt/-ge/-lt/-le（重定向不是比较），再重跑本工具'
        foreach ($l in $lint.Out) { $item.Detail.Add($l) }
    } else {
        $item.Status = 'OK'; $item.Action = '语法干净'
    }

    # 只有语法层面过了才试跑：语法还有错时试跑只会给出误导性的运行期报错
    if ($Verify -and ($item.Status -eq 'OK' -or $item.Status -eq 'FIXED')) {
        $run = Invoke-ScriptVerify $resolved $TimeoutSec
        if ($run.Code -ne 0) {
            $item.Status = 'RUNTIME_FAIL'
            if ($run.TimedOut) {
                $item.Action = "试跑超时（${TimeoutSec}s），疑似等待输入或死循环"
            } else {
                $item.Action = '语法通过但试跑失败：这是 lint 抓不到的"合法但错"，按报错回灌'
            }
            foreach ($l in @($run.StdErr) + @($run.StdOut)) {
                if ($l -and $item.Detail.Count -lt 20) { $item.Detail.Add([string]$l) }
            }
            $item.Detail.Add("试跑退出码: $($run.Code)")
        } else {
            $item.Action = ($item.Action + '；试跑通过')
        }
    }

    $results.Add($item)
    if ($rank[$item.Status] -gt $worst) { $worst = $rank[$item.Status] }
}

# -Inline 收尾：把（可能已被自愈的）语句读回来，打印给调用方，并删除临时文件
$inlineText = $null
if ($inlineMode -and (Test-Path -LiteralPath $inlineTmp)) {
    $inlineText = [IO.File]::ReadAllText($inlineTmp)
    Remove-Item -LiteralPath $inlineTmp -Force -ErrorAction SilentlyContinue
    # fix-ps-punct 会给临时文件留 .bak，内联模式下必须一并清掉，否则临时目录越积越多
    Remove-Item -LiteralPath ($inlineTmp + '.bak') -Force -ErrorAction SilentlyContinue
}

if ($AsJson) {
    if ($inlineMode) {
        $r0 = $results[0]
        Write-Output ([pscustomobject]@{
                inline  = $true
                status  = $r0.Status
                action  = $r0.Action
                fixed   = $inlineText
                detail  = @($r0.Detail)
                exitCode = $rankToExit[$worst]
            } | ConvertTo-Json -Depth 4)
    } else {
        $out = $results | ForEach-Object {
            [pscustomobject]@{
                path = $_.Path; status = $_.Status; action = $_.Action; detail = @($_.Detail)
            }
        }
        Write-Output ($out | ConvertTo-Json -Depth 4)
    }
} else {
    foreach ($r in $results) {
        Write-Host ('{0}: {1}' -f $r.Status, $(if ($inlineMode) { '<inline>' } else { $r.Path }))
        if ($r.Action) { Write-Host ('      建议: ' + $r.Action) }
        foreach ($d in $r.Detail) { Write-Host ('      ' + $d) }
    }
    if ($inlineMode -and $inlineText) {
        Write-Host ''
        Write-Host '修后语句:'
        Write-Host $inlineText.TrimEnd()
    }
    Write-Host ''
    Write-Host ('汇总: 处理 {0} 项，退出码 {1}（0 通过 / 1 回灌 / 2 调用错误 / 3 需人工改 -gt）' -f `
            $results.Count, $rankToExit[$worst])
}

exit $rankToExit[$worst]
