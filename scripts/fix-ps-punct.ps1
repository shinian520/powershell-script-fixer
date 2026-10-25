<#
.SYNOPSIS
    全角标点/不可见字符自愈：保护区由 PowerShell 真 tokenizer 判定，复检不通过不写回。
.DESCRIPTION
fix-ps-punct.ps1 - DeepSeek 输出 PowerShell 脚本的全角标点/不可见字符自愈器
策略：
  1) 默认只在"文件当前有语法错误"时动手；语法干净的只在检出可疑字符时报告（WARN），不改动。
     需要连干净文件一起处理时加 -All。
  2) 保护区由 PowerShell 自己的 tokenizer 给出：Kind 属于 Comment / StringLiteral / StringExpandable /
     HereStringLiteral / HereStringExpandable 的 verbatim 区间一律不动。不再手写状态机，
     因此不会与真 tokenizer 失步，也不会改坏字符串、注释、here-string 里的数据。
  3) 双引号字符串内部的 $(...) 子表达式整段按字符串保护（保守：宁可不改，也不改坏字面量）。
  4) 改完重新做语法校验，不通过则不写回，不留半损坏文件。
  5) 写回沿用原文件编码（按 BOM 判定：UTF-8±BOM / UTF-16LE / UTF-16BE，无 BOM 视为 UTF-8）；
     去 BOM 会让中文脚本在 Windows PowerShell 5.1 下按 GBK 解码成乱码。
  6) 备份为 <file>.bak；已存在则改存 <file>.bak-时间戳，绝不覆盖同名备份。
  7) 全角标点两侧紧邻中文/假名/韩文/全角字形时判为"给人看的字面量"，跳过不改，只报 SUSPECT。
用法: pwsh fix-ps-punct.ps1 <file.ps1> [<file2.ps1> ...] [-NoBackup] [-All] [-AsJson]
退出码: 0=无需改动或已修好  1=PARTIAL 仍有错未写回  2=读取/参数错误  3=WARN 检出可疑但未改动
  多文件取最严重，优先级 2 > 1 > 3 > 0。
.EXAMPLE
    pwsh fix-ps-punct.ps1 script.ps1 -All
#>
# Write-Host 用于 CLI 人类可读输出（配合 exit code 供管道/CI 消费），属刻意使用
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments = $true)][string[]]$Path,
    [switch]$NoBackup,
    [switch]$All,
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
}

$ErrorActionPreference = 'Stop'

# 这些 Kind 的 token 区间原样保留
$protectedKinds = @('Comment', 'StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable')

# 直接对应类：全角 -> ASCII 同形
$faithful = @{}
$pairIn = @(0xFF0C, 0xFF1A, 0xFF1B, 0xFF08, 0xFF09, 0xFF3B, 0xFF3D, 0xFF5B, 0xFF5D, 0xFF1C, 0xFF1E, 0xFF1D, 0xFF5C,
    0xFF02, 0xFF07, 0x201C, 0x201D, 0x2018, 0x2019,
    # 本次新增（旧表漏掉的常用项）；＃ 故意不进表，见下方 $reportOnly
    0xFF04, 0xFF20, 0xFF05, 0xFF06, 0xFF0A, 0xFF0B, 0xFF0D, 0xFF0F, 0xFF3C, 0xFF01, 0xFF1F, 0xFF0E)
$pairOut = @(',', ':', ';', '(', ')', '[', ']', '{', '}', '<', '>', '=', '|',
    '"', "'", '"', '"', "'", "'",
    '$', '@', '%', '&', '*', '+', '-', '/', '\', '!', '?', '.')
for ($k = 0; $k -lt $pairIn.Count; $k++) { $faithful[[char]$pairIn[$k]] = $pairOut[$k] }
# 全角数字与大写字母（Ａ-Ｚ ０-９）
for ($k = 0; $k -le 9; $k++) { $faithful[[char](0xFF10 + $k)] = [string][char](0x30 + $k) }
for ($k = 0; $k -lt 26; $k++) { $faithful[[char](0xFF21 + $k)] = [string][char](0x41 + $k) }
for ($k = 0; $k -lt 26; $k++) { $faithful[[char](0xFF41 + $k)] = [string][char](0x61 + $k) }

# 语义猜测类：中文句号当语句分隔符、顿号当列表逗号（不是同形映射，单独计数以便复核）
$semantic = @{ [char]0x3002 = ';'; [char]0x3001 = ',' }

# 不可见字符与空白类：全角/不换行空格转成半角空格，零宽类删除
$invisible = @{}
foreach ($c in @(0x3000, 0x00A0, 0x2007, 0x202F)) { $invisible[[char]$c] = ' ' }
foreach ($c in @(0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E)) { $invisible[[char]$c] = '' }

# 只报不改类：改成 ASCII 会静默删掉代码或语义不明（＃ 会把行尾变成注释，～ 在 PS 里不是取反中缀）
$reportOnly = @([char]0xFF03, [char]0xFF5E, [char]0xFFE1)

function Test-ProtectedKind([string]$kind) { return $protectedKinds -contains $kind }

function Test-CjkNeighbor([string]$text, [int]$i) {
    # 判断偏移 i 处字符的左右邻字符是否属于"中文文本跑"（CJK 汉字/假名/韩文/CJK 标点/全角形）
    # 注意：@($i - 1, $i + 1) 会被 PowerShell 解析成 $i - @(1, $i) + 1（数组减法），必须加显式括号
    foreach ($j in @(($i - 1), ($i + 1))) {
        if ($j -lt 0 -or $j -ge $text.Length) { continue }
        $c = [int][char]$text[$j]
        if (($c -ge 0x3000 -and $c -le 0x303F) -or ($c -ge 0x3040 -and $c -le 0x30FF) -or
            ($c -ge 0x3400 -and $c -le 0x4DBF) -or ($c -ge 0x4E00 -and $c -le 0x9FFF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7AF) -or ($c -ge 0xFF01 -and $c -le 0xFF60) -or
            ($c -ge 0x2018 -and $c -le 0x201D)) { return $true }
    }
    return $false
}

function Test-SuspectPunct([char]$ch) {
    $c = [int]$ch
    if (($c -ge 0x3000 -and $c -le 0x3003) -or ($c -ge 0xFF01 -and $c -le 0xFF20) -or
        ($c -ge 0xFF3B -and $c -le 0xFF40) -or ($c -ge 0xFF5B -and $c -le 0xFF65) -or
        ($c -ge 0x2018 -and $c -le 0x201D) -or ($c -ge 0x200B -and $c -le 0x200D) -or
        $c -in @(0x2060, 0xFEFF, 0x3000, 0x00A0, 0x2007, 0x202F, 0x2026, 0xFFE1)) { return $true }
    return $false
}

function Get-Parsed([string]$text) {
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    return [pscustomobject]@{ Tokens = $tokens; Errors = @($errors) }
}

function Get-ProtectedMask([string]$text, $tokens) {
    $mask = [bool[]]::new($text.Length)
    foreach ($t in $tokens) {
        if (-not (Test-ProtectedKind ([string]$t.Kind))) { continue }
        $s = $t.Extent.StartOffset; $e = [Math]::Min($t.Extent.EndOffset, $text.Length)
        for ($i = [Math]::Max(0, $s); $i -lt $e; $i++) { $mask[$i] = $true }
    }
    return $mask
}

function Get-LineCol([string]$text, [int]$offset) {
    $before = $text.Substring(0, [Math]::Min($offset, $text.Length))
    $line = 1 + ([regex]::Matches($before, "`n")).Count
    $lastNL = $before.LastIndexOf("`n")
    $col = if ($lastNL -lt 0) { $offset + 1 } else { $offset - $lastNL }
    return [pscustomobject]@{ Line = $line; Col = $col }
}

function Get-CharName([char]$ch) {
    # 输出 U+XXXX，避免终端代码页把全角/不可见字符显示成乱码或空白
    'U+{0:X4}' -f [int]$ch
}

function Add-ErrorLine {
    param($Item, $Errors, [string]$Text)
    $origLines = @($Text -split "`n")
    foreach ($e in $Errors) {
        $ln = $e.Extent.StartLineNumber
        $body = if ($ln -ge 1 -and $ln -le $origLines.Count) { ($origLines[$ln - 1] -replace "`r", '') } else { '' }
        $Item.Errors.Add(('L{0}C{1}: {2} | 原文行: {3}' -f $ln, $e.Extent.StartColumnNumber, $e.Message, $body.Trim()))
    }
    # 未闭合字符串会让后续内容整体落在保护区里，这是"替换 0 处"的常见原因，值得单独说明
    foreach ($e in $Errors) {
        if ($e.Message -match 'terminator') {
            $Item.Errors.Add('  注：字符串未闭合，其后内容无法判定为代码区，本工具不处理')
            break
        }
    }
}

$results = [System.Collections.Generic.List[object]]::new()
# 严重度优先级序数（越大越严重）与退出码是两张表：优先级 ERROR(3) > PARTIAL(2) > WARN(1) > 0，
# 退出码却是 2/1/3/0 —— 直接拿退出码比大小会让 WARN 压住 PARTIAL/ERROR，多文件取最严重即失效。
$rank = @{ 'OK' = 0; 'FIXED' = 0; 'WARN' = 1; 'PARTIAL' = 2; 'ERROR' = 3 }
$rankToExit = @{ 0 = 0; 1 = 3; 2 = 1; 3 = 2 }
$worst = 0

foreach ($p in $Path) {
    $item = [pscustomobject]@{
        Path = $p; Status = 'OK'; Exit = 0; Replaced = 0; Faithful = 0; Invisible = 0; SemanticGuess = 0
        Suspect = 0; Unrecorded = 0; Notes = [System.Collections.Generic.List[string]]::new()
        Errors = [System.Collections.Generic.List[string]]::new()
    }
    $resolved = $null
    try {
        $resolved = (Resolve-Path -LiteralPath $p).Path
        if (Test-Path -LiteralPath $resolved -PathType Container) { throw "不是文件: $resolved" }
        $bytes = [IO.File]::ReadAllBytes($resolved)
    } catch {
        $item.Status = 'ERROR'; $item.Notes.Add("读取失败: $($_.Exception.Message)")
        $results.Add($item); if ($rank[$item.Status] -gt $worst) { $worst = $rank[$item.Status] }
        continue
    }

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [Text.UTF8Encoding]::new($true); $skip = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.Encoding]::Unicode; $skip = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.Encoding]::BigEndianUnicode; $skip = 2
    } else {
        $encoding = [Text.UTF8Encoding]::new($false); $skip = 0
    }
    $text = $encoding.GetString($bytes, $skip, $bytes.Length - $skip)
    $item.Path = $resolved

    $parse = Get-Parsed $text
    $hadErrors = $parse.Errors.Count -gt 0

    if (-not $hadErrors -and -not $All) {
        # 门槛：语法已通过则不动文件；但可疑字符仍然报告，别把"合法但错"当成绿灯
        $mask = Get-ProtectedMask $text $parse.Tokens
        $found = 0
        for ($i = 0; $i -lt $text.Length; $i++) {
            if ($mask[$i]) { continue }
            $c = $text[$i]
            if ([int]$c -lt 0x80) { continue }
            if ($faithful.ContainsKey($c) -or $semantic.ContainsKey($c) -or $invisible.ContainsKey($c) -or
                $reportOnly -contains $c -or (Test-SuspectPunct $c)) {
                $lc = Get-LineCol $text $i
                $found += 1
                if ($found -le 12) { $item.Notes.Add(("L{0}C{1}: {2}（当前语法合法，未改动）" -f $lc.Line, $lc.Col, (Get-CharName $c))) }
            }
        }
        if ($found -gt 0) {
            $item.Status = 'WARN'; $item.Suspect = $found
            if ($found -gt 12) { $item.Notes.Add(('  ...另 {0} 处未列出' -f ($found - 12))) }
        } else {
            $item.Status = 'OK'; $item.Notes.Add('语法本就通过，未修改。')
        }
        $results.Add($item); if ($rank[$item.Status] -gt $worst) { $worst = $rank[$item.Status] }
        continue
    }

    # 逐字符转换：只碰保护区之外、且不属于"中文文本跑"的字符
    $mask = Get-ProtectedMask $text $parse.Tokens
    $sb = [Text.StringBuilder]::new($text.Length)
    $nFaithful = 0; $nInvisible = 0; $nSemantic = 0; $nSuspect = 0; $nUnrecorded = 0
    for ($i = 0; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($mask[$i]) { [void]$sb.Append($c); continue }
        $tier = $null; $repl = $null
        if ($faithful.ContainsKey($c)) { $tier = 'F'; $repl = $faithful[$c] }
        elseif ($semantic.ContainsKey($c)) { $tier = 'S'; $repl = $semantic[$c] }
        elseif ($invisible.ContainsKey($c)) { $tier = 'I'; $repl = $invisible[$c] }
        elseif ($reportOnly -contains $c) { $tier = 'R' }
        elseif (Test-SuspectPunct $c) { $tier = 'U' }

        if ($null -eq $tier) { [void]$sb.Append($c); continue }

        if ($tier -in @('F', 'S', 'I')) {
            if (Test-CjkNeighbor $text $i) {
                # 两侧是中文文本 -> 视为给人看的字面量，不改，只报
                $nSuspect += 1
                $lc = Get-LineCol $text $i
                if ($nSuspect -le 12) { $item.Notes.Add(("SUSPECT L{0}C{1}: {2} 紧邻非 ASCII 文本，按字面量保留" -f $lc.Line, $lc.Col, (Get-CharName $c))) }
                [void]$sb.Append($c); continue
            }
            [void]$sb.Append($repl)
            # 用 += 而不是 ++：++ 作为语句会把值写进输出流，污染 -AsJson 的结果
            if ($tier -eq 'F') { $nFaithful += 1 } elseif ($tier -eq 'S') { $nSemantic += 1 } else { $nInvisible += 1 }
            continue
        }
        if ($tier -eq 'R') {
            $nSuspect += 1
            $lc = Get-LineCol $text $i
            if ($nSuspect -le 12) { $item.Notes.Add(("SUSPECT L{0}C{1}: {2} 属只报不改类（改成 ASCII 会改变语义）" -f $lc.Line, $lc.Col, (Get-CharName $c))) }
            [void]$sb.Append($c); continue
        }
        $nUnrecorded += 1
        $lc = Get-LineCol $text $i
        if ($nUnrecorded -le 12) { $item.Notes.Add(("UNRECORDED L{0}C{1}: {2} 不在映射表内，无法自愈" -f $lc.Line, $lc.Col, (Get-CharName $c))) }
        [void]$sb.Append($c)
    }

    $item.Faithful = $nFaithful; $item.Invisible = $nInvisible; $item.SemanticGuess = $nSemantic
    $item.Replaced = $nFaithful + $nInvisible + $nSemantic
    $item.Suspect = $nSuspect; $item.Unrecorded = $nUnrecorded

    if ($item.Replaced -eq 0) {
        # 一处都没替换：绝不写回、绝不建备份，避免把原件原地重写并留下一份无意义的 .bak
        if ($hadErrors) {
            $item.Status = 'PARTIAL'
            Add-ErrorLine -Item $item -Errors $parse.Errors -Text $text
        } else {
            $item.Status = 'WARN'
            $item.Suspect = $nSuspect + $nUnrecorded
        }
        $results.Add($item)
        if ($rank[$item.Status] -gt $worst) { $worst = $rank[$item.Status] }
        continue
    }

    $fixedText = $sb.ToString()
    $recheck = Get-Parsed $fixedText
    if ($recheck.Errors.Count -eq 0) {
        $backup = $null
        if (-not $NoBackup) {
            $backup = "$resolved.bak"
            if (Test-Path -LiteralPath $backup) {
                $backup = '{0}.bak-{1}' -f $resolved, (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
                if (Test-Path -LiteralPath $backup) {
                    $item.Status = 'ERROR'; $item.Notes.Add("备份目标已存在，未写回: $backup")
                    $results.Add($item); if ($rank['ERROR'] -gt $worst) { $worst = $rank['ERROR'] }
                    continue
                }
            }
        }
        try {
            if ($backup) { [IO.File]::Copy($resolved, $backup, $false) }
            [IO.File]::WriteAllText($resolved, $fixedText, $encoding)
        } catch {
            $item.Status = 'ERROR'; $item.Notes.Add("写回失败: $($_.Exception.Message)")
            $results.Add($item); if ($rank['ERROR'] -gt $worst) { $worst = $rank['ERROR'] }
            continue
        }
        $item.Status = 'FIXED'
        $item.Notes.Add(("已写回，沿用原编码 {0}" -f $encoding.EncodingName))
        if ($backup) { $item.Notes.Add("原文件备份为 $backup") }
    } else {
        $item.Status = 'PARTIAL'
        Add-ErrorLine -Item $item -Errors $recheck.Errors -Text $fixedText
    }
    $results.Add($item)
    if ($rank[$item.Status] -gt $worst) { $worst = $rank[$item.Status] }
}

if ($AsJson) {
    $out = $results | ForEach-Object {
        [pscustomobject]@{
            path = $_.Path; status = $_.Status; replaced = $_.Replaced; faithful = $_.Faithful
            invisible = $_.Invisible; semanticGuess = $_.SemanticGuess; suspect = $_.Suspect
            unrecorded = $_.Unrecorded; notes = @($_.Notes); errors = @($_.Errors)
        }
    }
    Write-Output ($out | ConvertTo-Json -Depth 4)
} else {
    foreach ($r in $results) {
        switch ($r.Status) {
            'OK' { Write-Host ("OK: 语法本就通过，未修改。{0}" -f $r.Path) }
            'FIXED' { Write-Host ("FIXED: 替换 {0} 处（同形 {1} / 不可见 {2} / 语义猜测 {3}），语法校验通过 - {4}" -f `
                        $r.Replaced, $r.Faithful, $r.Invisible, $r.SemanticGuess, $r.Path) }
            'PARTIAL' { Write-Host ("PARTIAL: 替换 {0} 处但仍有 {1} 处错误，未写回 - {2}" -f `
                            $r.Replaced, $r.Errors.Count, $r.Path) }
            'WARN' { Write-Host ("WARN: 检出 {0} 处可疑全角/不可见字符，当前语法合法故未改动 - {1}" -f $r.Suspect, $r.Path) }
            'ERROR' { Write-Host ("ERROR: {0} - {1}" -f ($r.Notes -join '; '), $r.Path) }
        }
        foreach ($n in $r.Notes) { if ($r.Status -ne 'OK' -and $r.Status -ne 'ERROR') { Write-Host ('      ' + $n) } }
        foreach ($e in $r.Errors) { Write-Host ('      ' + $e) }
    }
}
exit $rankToExit[$worst]
