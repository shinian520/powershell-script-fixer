<#
.SYNOPSIS
    PowerShell 语句/脚本语法预检：只解析不执行，报语法错（分类 + 码位 + 修法建议 + 上下文）与符号比较。
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

报错分层（每条错误给出）:
  分类        全角/非 ASCII 标点 | 括号/引号未闭合 | 哈希表语法 | 逗号后缺表达式 |
              字符串未闭合 | here-string 结束符 | 语法结构错 | 其他语法错
  可疑字符    U+XXXX 码位（便于按码位批量替换，不受终端字体影响）
  可自动修    fix-ps-punct 能否直接修好（全角/不可见字符类 = 是，结构性 = 否）
  建议动作    一句话说明该怎么改
  上下文      出错行前后各一行 + 列指示（长文件里定位比只看行号快）
  合并        同一类同一报错只列一次，其余位置折叠成「另见 LxCx」

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
    输出结构化 JSON（供 CI / agent 消费）。errors[] 含 category/hint/autoFixable/codePoint/context。
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

# -Inline 且值为 "-"：从标准输入读（按字节读再显式 UTF-8 解码，避免控制台编码把中文搞成乱码）
if ($Inline -eq '-' -and -not [Console]::IsInputRedirected) {
    Write-Host 'ERROR: -Inline - 需要从标准输入传入文本'
    exit 2
}
if ($Inline -eq '-' -and [Console]::IsInputRedirected) {
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

# 把一条 ParseError 归到"人能行动"的类别上：分类 / 建议 / 是否可自动修 / 可疑字符码位
function Get-ErrorInfo {
    param([System.Management.Automation.Language.ParseError]$Error)

    $msg = $Error.Message
    $info = [ordered]@{
        Category     = '其他语法错'
        Hint         = '按下面报错原文回灌重写（references/error-feedback-prompt.md）'
        AutoFixable  = $false
        Char         = $null
        CodePoint    = $null
    }

    # 1) 全角 / 非 ASCII 标点：Unexpected token '，' 这类
    if ($msg -match "Unexpected token '(.{1,2})'") {
        $tok = $Matches[1]
        $cp = [int][char]$tok[0]
        if ($cp -ge 0x80) {
            $info.Category = '全角/非 ASCII 标点'
            $info.AutoFixable = $true
            $info.Char = $tok
            $info.CodePoint = ('U+{0:X4}' -f $cp)
            $info.Hint = ("把 '{0}'（{1}）换成半角同形字符；fix-ps-punct 可自动修" -f $tok, $info.CodePoint)
            return [pscustomobject]$info
        }
    }

    # 2) 括号 / 引号未闭合：PS 报在最外层未闭合块的开头，不是缺符号的确切位置
    if ($msg -match "Missing closing '(.)'") {
        $sym = $Matches[1]
        $info.Category = '括号/引号未闭合'
        $info.Hint = ("缺 '{0}' 的闭合。报错指向最外层未闭合块的开头，不是缺失处；" +
            "补哪里取决于代码语义，工具不自动补 —— 建议人工配对或用回灌模板重写该块") -f $sym
        return [pscustomobject]$info
    }
    if ($msg -match "Missing '\)' after|Missing closing '\)'") {
        $info.Category = '括号/引号未闭合'
        $info.Hint = "缺 ')' 的闭合：检查函数调用/表达式里的括号配对"
        return [pscustomobject]$info
    }

    # 3) 哈希表：冒号 vs 等号（全角冒号改半角也仍然错，必须改成 =）
    if ($msg -match "Missing '=' operator after key in hash literal") {
        $info.Category = '哈希表语法'
        $info.Hint = '@{ Key = Value } 必须用等号；冒号只属于 JSON。注意：把全角 ： 改成 : 仍然是错的，要改成 ='
        return [pscustomobject]$info
    }

    # 4) 逗号后缺表达式（行尾多余逗号 / 行尾全角逗号被替换后也会撞这条）
    if ($msg -match "Missing expression after ','|Missing expression after ',' in|Missing expression after") {
        $info.Category = '逗号后缺表达式'
        $info.Hint = '逗号后面没有内容了：数组/参数表换行时行尾不要留逗号；若是行尾全角逗号，直接删掉'
        return [pscustomobject]$info
    }

    # 5) 字符串 / here-string 未闭合
    if ($msg -match "string is missing the terminator") {
        $info.Category = '字符串未闭合'
        $info.Hint = '引号未闭合：其后内容会被整体当成字符串，工具不处理；补引号或改用 here-string'
        return [pscustomobject]$info
    }
    if ($msg -match "White space is not allowed before the string terminator") {
        $info.Category = 'here-string 结束符'
        $info.Hint = "here-string 的结束符必须顶格（PS 7 也不允许缩进）"
        return [pscustomobject]$info
    }

    # 6) 其余 Unexpected token（ASCII）：多为缺运算符/分隔符，或把 == // 当 C 语法
    if ($msg -match "Unexpected token '(.+?)'") {
        $info.Category = '语法结构错'
        $info.Hint = "此处不允许该 token：常见原因是少了运算符/分隔符，或用了 == / != / // 注释 / C 风格调用"
        return [pscustomobject]$info
    }

    return [pscustomobject]$info
}

# 出错行前后各一行 + 列指示。出错行保持旧格式 `      > 源码`（既有断言依赖），
# 前后行带行号，便于在长文件里看清块结构。
function Get-ContextLines {
    param([string[]]$Lines, [int]$Line, [int]$Column, [int]$Before = 1, [int]$After = 1)

    $ctx = [System.Collections.Generic.List[string]]::new()
    $from = [Math]::Max(1, $Line - $Before)
    $to = [Math]::Min($Lines.Count, $Line + $After)
    for ($i = $from; $i -le $to; $i++) {
        $text = ([string]$Lines[$i - 1]).TrimEnd()
        if ($i -eq $Line) {
            $ctx.Add('      > ' + $text)
            if ($Column -ge 1) { $ctx.Add('        ' + (' ' * [Math]::Max(0, $Column - 1)) + '^') }
        } else {
            $ctx.Add(('{0,7} | {1}' -f $i, $text))
        }
    }
    return , $ctx
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
            $results.Add([pscustomobject]@{ Path = $p; Status = 'ERROR'; Count = 0; Errors = @(); Warnings = @(); Summary = $null })
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
                    if ($s.Line -ge 1 -and $s.Line -le $lines.Count) {
                        Write-Host ('      ' + ([string]$lines[$s.Line - 1]).TrimEnd())
                    }
                }
                Write-Host '  说明: 条件/赋值里的 > 会被解析为重定向，分支输出静默丢失并生成名为 0 的怪文件'
            }
            $results.Add([pscustomobject]@{
                    Path = $label; Status = 'WARN'; Count = $suspects.Count
                    Errors = @(); Warnings = @($suspects)
                    Summary = [pscustomobject]@{ ByCategory = @{ '符号比较（> 当重定向）' = $suspects.Count }; AutoFixable = 0 }
                })
            if ($rank['WARN'] -gt $worst) { $worst = $rank['WARN'] }
            continue
        }
        if (-not $Quiet -and -not $AsJson) { Write-Host "OK: $label" }
        $results.Add([pscustomobject]@{
                Path = $label; Status = 'OK'; Count = 0; Errors = @(); Warnings = @()
                Summary = [pscustomobject]@{ ByCategory = @{}; AutoFixable = 0 }
            })
        continue
    }

    # 逐条归档：分类 / 建议 / 可否自动修 / 上下文
    $detailed = [System.Collections.Generic.List[object]]::new()
    $byCat = @{}
    $autoFixable = 0
    foreach ($e in $errors) {
        $info = Get-ErrorInfo -Error $e
        $ln = $e.Extent.StartLineNumber
        $col = $e.Extent.StartColumnNumber
        $ctx = Get-ContextLines -Lines $lines -Line $ln -Column $col

        # 结构性报错常常是全角字符造成的"假象"（如 if ($n ＞ 0) 会被报成缺括号）。
        # 仅对"非全角类"的分类补这条提示，避免与上面的同形字符建议重复。
        $lineText = if ($ln -ge 1 -and $ln -le $lines.Count) { [string]$lines[$ln - 1] } else { '' }
        $fw = [regex]::Matches($lineText, '[\u3000-\u303F\uFF01-\uFF60]')
        $hint = $info.Hint
        $lineHasFullWidth = $fw.Count -gt 0
        if ($lineHasFullWidth -and $info.Category -ne '全角/非 ASCII 标点') {
            $codes = (@($fw | Select-Object -First 5 | ForEach-Object { 'U+{0:X4}' -f [int]$_.Value[0] }) -join ' ')
            $hint = $hint + ('；该行含全角字符（{0}）：若位于代码区，先跑 fix-ps-punct -All，这条结构性报错可能只是它造成的假象' -f $codes)
        }

        $detailed.Add([pscustomobject]@{
                line            = $ln
                column          = $col
                id              = $e.ErrorId
                message         = $e.Message
                category        = $info.Category
                hint            = $hint
                autoFixable     = [bool]$info.AutoFixable
                char            = $info.Char
                codePoint       = $info.CodePoint
                lineHasFullWidth = $lineHasFullWidth
                context         = @($ctx)
            })
        if ($byCat.ContainsKey($info.Category)) { $byCat[$info.Category] += 1 } else { $byCat[$info.Category] = 1 }
        if ($info.AutoFixable) { $autoFixable += 1 }
    }

    if (-not $Quiet -and -not $AsJson) {
        Write-Host "FAIL: $($errors.Count) 处语法错误 - $label"
        # 每条错误都列一行 `LxCx:`（既有断言依赖条数 == 头部计数）；
        # 但同一行只展开一次上下文 —— 一个全角字符常级联出 2~3 条报错，重复贴码没价值。
        $expandedLine = @{}
        foreach ($d in $detailed) {
            Write-Host ('  L{0}C{1}: {2}' -f $d.line, $d.column, $d.message)
            if ($expandedLine.ContainsKey($d.line)) {
                Write-Host '      （与上面同一行的级联报错：多半由上面那个全角字符引起，改掉后一并消失）'
                continue
            }
            $expandedLine[$d.line] = $true
            Write-Host ('      分类: {0}{1}' -f $d.category, $(if ($d.autoFixable) { '  → fix-ps-punct 可自动修' } else { '' }))
            if ($d.char) { Write-Host ("      可疑字符: '{0}' ({1})" -f $d.char, $d.codePoint) }
            Write-Host ('      建议: ' + $d.hint)
            foreach ($c in $d.context) { Write-Host ('      ' + $c) }
        }
        if ($byCat.Count -gt 0) {
            $summaryText = ($byCat.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object { "$($_.Key) ×$($_.Value)" }) -join '、'
            Write-Host ('  汇总: {0}{1}' -f $summaryText, $(if ($autoFixable -gt 0) { "；其中 $autoFixable 处可自动修（跑 fix-ps-punct）" } else { '；均为结构性错误，需人工或回灌' }))
        }
    }

    $results.Add([pscustomobject]@{
            Path = $label; Status = 'FAIL'; Count = $errors.Count
            Errors = @($detailed); Warnings = @()
            Summary = [pscustomobject]@{ ByCategory = $byCat; AutoFixable = $autoFixable }
        })
    if ($rank['FAIL'] -gt $worst) { $worst = $rank['FAIL'] }
}

if ($AsJson) {
    Write-Output ($results | ConvertTo-Json -Depth 6)
}
exit $rankToExit[$worst]
