<#
.SYNOPSIS
    PowerShell 语句/脚本语法预检：只解析不执行，报语法错与可疑符号比较（> 当重定向）。
.DESCRIPTION
ps-lint.ps1 - PowerShell 语法预检（只解析不执行）

用法:
  pwsh ps-lint.ps1 <file.ps1> [<file2.ps1> ...] [-Quiet] [-AsJson]
  pwsh ps-lint.ps1 -Inline "if ($x > 0) { 'a' }" [-AsJson]      # AI 直接执行的语句也能量
  Get-Content x.ps1 -Raw | pwsh ps-lint.ps1 -Inline -            # 从标准输入读

退出码: 0=无语法错误  1=存在语法错误  2=读取/参数错误（路径不存在、传入目录、无权限、未给输入）
        3=无语法错误但检出可疑符号比较（`>` 被当重定向）
  把"语法错""没读到文件""可疑但合法"分成三个码，CI 才能区分。
  多目标取最严重：2 > 1 > 3 > 0。
注意: 通过只表示没有 ParseError，不代表能运行、更不代表逻辑正确——全角标点并入裸词
  （$a = 1，2）、== 、// 注释、C 风格调用都是 ParseError 检不出、运行期才炸的例子。
  其中 `>` 做比较（if ($x > 0)）最隐蔽：它被解析成重定向运算符，分支输出静默丢失，
  还会在磁盘上生成名为 0 的怪文件，而进程退出码仍是 0。本工具用 AST 检出并报 3。
.PARAMETER Path
    一个或多个 .ps1/.psm1 路径。与 -Inline 二选一。
.PARAMETER Inline
    直接给一段语句/脚本文本（AI 执行 pwsh 语句的典型形态）。文本不会被执行。
.PARAMETER Quiet
    不输出人类可读文本，只看退出码。
.PARAMETER AsJson
    输出结构化 JSON（供 CI / agent 消费）。
.EXAMPLE
    pwsh ps-lint.ps1 a.ps1 b.ps1 -AsJson
.EXAMPLE
    pwsh ps-lint.ps1 -Inline 'if ($n > 0) { Write-Host ok }'
#>
# Write-Host 用于 CLI 人类可读输出（配合 exit code 供管道/CI 消费），属刻意使用
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Path,
    [string]$Inline,
    [switch]$Quiet,
    [switch]$AsJson
)

# PowerShell 7 门禁：用运行时判断，不用 #Requires —— 后者在 5.1 下以 exit 1 中止，
# 与"存在语法错误"的退出码撞车，CI 分不清"环境不对"和"脚本有错"。
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: 需要 PowerShell 7+，当前 $($PSVersionTable.PSVersion)。这是调用环境问题（exit 2），不是脚本语法错误。"
    exit 2
}

$ErrorActionPreference = 'Stop'

# -Inline 且值为 "-"：从标准输入读整段文本（管道场景）
if ($Inline -eq '-' -and -not [Console]::IsInputRedirected) {
    Write-Host 'ERROR: -Inline - 需要从标准输入传入文本'
    exit 2
}
if ($Inline -eq '-' -and [Console]::IsInputRedirected) {
    # 按字节读再显式 UTF-8 解码：直接读 Console.In 会走控制台输入编码（常为 GBK），中文会乱码
    $ms = [IO.MemoryStream]::new()
    [Console]::OpenStandardInput().CopyTo($ms)
    $bytes = $ms.ToArray()
    try { $Inline = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { $Inline = [Console]::InputEncoding.GetString($bytes) }
}
$useInline = $PSBoundParameters.ContainsKey('Inline') -and $Inline -ne ''
if (-not $useInline -and -not $Path) {
    Write-Host 'ERROR: 需要给出文件路径，或用 -Inline 传入语句文本'
    exit 2
}

$results = [System.Collections.Generic.List[object]]::new()
# 严重度优先级序数（越大越严重）与退出码是两码事：优先级 2(ERROR) > 1(FAIL) > 3(WARN) > 0，
# 而退出码数值 3 > 2 > 1 > 0 —— 直接拿退出码比大小会让 WARN 压住语法错，故分开两张表。
$rank = @{ 'OK' = 0; 'WARN' = 1; 'FAIL' = 2; 'ERROR' = 3 }
$rankToExit = @{ 0 = 0; 1 = 3; 2 = 1; 3 = 2 }
$worst = 0

# `>` 在 PowerShell 里是重定向运算符，不是比较：if ($n > 0) 会被解析成"对文件 0 做重定向"，
# 后果是分支体输出静默丢失、磁盘上多出名为 0 的怪文件，而语法完全合法（ParseError=0）。
# 判据（实测 pwsh 7.6.5，零误报）：FileRedirectionAst 的父节点不是 CommandAst。
#   if ($n > 0) / $r = 5 > 0 / while ($i > 3)     -> 父=CommandExpressionAst  => 可疑
#   Write-Host "x" > f.txt / Get-Date > f.txt     -> 父=CommandAst            => 合法重定向
function Get-SuspiciousComparison {
    param([System.Management.Automation.Language.Ast]$ScriptAst)
    $found = [System.Collections.Generic.List[object]]::new()
    $redirs = $ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FileRedirectionAst] }, $true)
    foreach ($r in $redirs) {
        if ($r.Parent -isnot [System.Management.Automation.Language.CommandAst]) {
            $found.Add([pscustomobject]@{
                    Line   = $r.Extent.StartLineNumber
                    Column = $r.Extent.StartColumnNumber
                    Text   = ($r.Extent.Text -replace '\s+', ' ')
                })
        }
    }
    return $found
}

# 统一把"一个目标"归约成 (Label, Ast, Errors, Lines)，文件与内联语句共用后面的报告逻辑
$targets = if ($useInline) { @('<inline>') } else { @($Path) }

foreach ($p in $targets) {
    $label = $p
    $ast = $null
    $errors = @()

    if ($useInline) {
        $lines = @($Inline -split "`n")
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Inline, [ref]$tokens, [ref]$errs)
        $errors = @($errs)
    } else {
        $resolved = $null
        try {
            $resolved = (Resolve-Path -LiteralPath $p).Path
            if (Test-Path -LiteralPath $resolved -PathType Container) { throw '传入的是目录，不是脚本文件' }
        } catch {
            if (-not $Quiet -and -not $AsJson) { Write-Host "ERROR: 无法读取 $p - $($_.Exception.Message)" }
            $results.Add([pscustomobject]@{ Path = $p; Status = 'ERROR'; Count = 0; Errors = @(); Warnings = @() })
            if ($rank['ERROR'] -gt $worst) { $worst = $rank['ERROR'] }
            continue
        }
        $label = $resolved
        $lines = @(Get-Content -LiteralPath $resolved)
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errs)
        $errors = @($errs)
    }

    if ($errors.Count -eq 0) {
        $suspects = @(Get-SuspiciousComparison -ScriptAst $ast)
        if ($suspects.Count -gt 0) {
            if (-not $Quiet -and -not $AsJson) {
                Write-Host "WARN: $($suspects.Count) 处可疑符号比较（'>' 被当重定向，不是比较）- $label"
                foreach ($s in $suspects) {
                    Write-Host ('  L{0}C{1}: [{2}] 请改用 -gt/-ge/-lt/-le' -f $s.Line, $s.Column, $s.Text)
                    if ($s.Line -ge 1 -and $s.Line -le $lines.Count) { Write-Host ('      > ' + ([string]$lines[$s.Line - 1]).TrimEnd()) }
                }
                Write-Host '  说明: 条件/赋值里的 > 会被解析为重定向，分支输出静默丢失并生成名为 0 的怪文件'
            }
            $results.Add([pscustomobject]@{
                    Path = $label; Status = 'WARN'; Count = $suspects.Count
                    Errors = @(); Warnings = @($suspects)
                })
            if ($rank['WARN'] -gt $worst) { $worst = $rank['WARN'] }
            continue
        }
        if (-not $Quiet -and -not $AsJson) { Write-Host "OK: $label" }
        $results.Add([pscustomobject]@{ Path = $label; Status = 'OK'; Count = 0; Errors = @(); Warnings = @() })
        continue
    }

    if (-not $Quiet -and -not $AsJson) {
        Write-Host "FAIL: $($errors.Count) 处语法错误 - $label"
        foreach ($e in $errors) {
            Write-Host ('  L{0}C{1}: {2}' -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
            $ln = $e.Extent.StartLineNumber
            if ($ln -ge 1 -and $ln -le $lines.Count) { Write-Host ('      > ' + ([string]$lines[$ln - 1]).TrimEnd()) }
        }
    }
    $results.Add([pscustomobject]@{
            Path = $label; Status = 'FAIL'; Count = $errors.Count
            Errors = @($errors | ForEach-Object {
                [pscustomobject]@{
                    line = $_.Extent.StartLineNumber; column = $_.Extent.StartColumnNumber
                    id = $_.ErrorId; message = $_.Message
                }
            })
            Warnings = @()
        })
    if ($rank['FAIL'] -gt $worst) { $worst = $rank['FAIL'] }
}

if ($AsJson) {
    Write-Output ($results | ConvertTo-Json -Depth 4)
}
exit $rankToExit[$worst]
