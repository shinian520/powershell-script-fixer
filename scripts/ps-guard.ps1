<#
.SYNOPSIS
    一条命令闭环：预检 -> 自愈 -> 复检 -> Stop 模式试跑，只回一个退出码与一句 ACTION。
.DESCRIPTION
ps-guard.ps1 - 一条命令完成「预检 -> 自愈 -> 复检 -> 试跑」的 PowerShell 脚本守卫
用法: pwsh ps-guard.ps1 <file.ps1> [<file2.ps1> ...] [-NoFix] [-Verify] [-TimeoutSec 30] [-AsJson]
退出码: 0=通过（语法干净，试跑通过）
        1=需回灌重写（仍有语法错 / 试跑失败），报错已抓取，可直接贴回模型
        2=读取/调用错误（路径不存在、传入目录、缺工具）
        3=需人工处理（检出 `>` 当比较用的写法，须改 -gt/-ge/-lt/-le）
  多文件取最严重，优先级 2 > 1 > 3 > 0（与 ps-lint / fix-ps-punct 一致）。
默认行为：发现语法错就调 fix-ps-punct 自愈；-NoFix 关闭自愈；-Verify 额外做 Stop 模式试跑。
.EXAMPLE
    pwsh ps-guard.ps1 script.ps1 -Verify
#>
# Write-Host 用于 CLI 人类可读输出（配合 exit code 供管道/CI 消费），属刻意使用
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments = $true)][string[]]$Path,
    [switch]$NoFix,
    [switch]$Verify,
    [int]$TimeoutSec = 30,
    [switch]$AsJson
)

# PowerShell 7 门禁：用运行时判断，不用 #Requires —— 后者在 5.1 下以 exit 1 中止，
# 与"存在语法错误"的退出码撞车，CI 分不清"环境不对"和"脚本有错"。
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: 需要 PowerShell 7+，当前 $($PSVersionTable.PSVersion)。这是调用环境问题（exit 2），不是脚本语法错误。"
    exit 2
}

$ErrorActionPreference = 'Stop'

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
    $safe = $scriptPath -replace "'", "''"
    $cmd = "& { `$ErrorActionPreference = 'Stop'; & '$safe' }"
    $tag = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path ([IO.Path]::GetTempPath()) "$tag.out"
    $errFile = Join-Path ([IO.Path]::GetTempPath()) "$tag.err"
    $timedOut = $false
    try {
        # -NoNewWindow 只在 Windows 有意义；Linux/macOS 上传了会被忽略或报错，故按平台组装
        $spArgs = @{
            FilePath               = $pwshExe
            ArgumentList           = @('-NoProfile', '-Command', $cmd)
            PassThru               = $true
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
        }
        if ($IsWindows) { $spArgs['NoNewWindow'] = $true }
        $proc = Start-Process @spArgs
        if (-not $proc.WaitForExit($limitSec * 1000)) {
            $timedOut = $true
            try { $proc.Kill($true) } catch { $null = $_ }
        }
        $code = if ($timedOut) { 124 } else { $proc.ExitCode }
        $stdout = if (Test-Path -LiteralPath $outFile) { @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue) } else { @() }
        $stderr = if (Test-Path -LiteralPath $errFile) { @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) } else { @() }
        return [pscustomobject]@{ Code = $code; TimedOut = $timedOut; StdOut = @($stdout); StdErr = @($stderr) }
    } finally {
        foreach ($f in @($outFile, $errFile)) {
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

if ($AsJson) {
    $out = $results | ForEach-Object {
        [pscustomobject]@{
            path = $_.Path; status = $_.Status; action = $_.Action; detail = @($_.Detail)
        }
    }
    Write-Output ($out | ConvertTo-Json -Depth 4)
} else {
    foreach ($r in $results) {
        Write-Host ('{0}: {1}' -f $r.Status, $r.Path)
        if ($r.Action) { Write-Host ('      建议: ' + $r.Action) }
        foreach ($d in $r.Detail) { Write-Host ('      ' + $d) }
    }
    Write-Host ''
    Write-Host ('汇总: 共 {0} 个文件，退出码 {1}（0 通过 / 1 回灌 / 2 调用错误 / 3 需人工改 -gt）' -f `
            $results.Count, $rankToExit[$worst])
}

exit $rankToExit[$worst]
