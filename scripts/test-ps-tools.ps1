<#
.SYNOPSIS
    ps-lint / fix-ps-punct 的 49 例边界回归。
.DESCRIPTION
test-ps-tools.ps1 - ps-lint / fix-ps-punct 边界测试套件
用法: pwsh test-ps-tools.ps1 [-Case <关键字>] [-Keep] [-WorkDir <目录>] [-Lint <ps-lint.ps1>] [-Fix <fix-ps-punct.ps1>]
  -Case 只跑名字含该关键字的用例（如 'fix' 或 'zwsp'）
  -Keep 保留工作目录（默认跑完清理）
  被测工具默认取本脚本同目录的 ps-lint.ps1 / fix-ps-punct.ps1（不再硬编码绝对路径，
  避免"改了交付副本、套件还在测另一份实装副本"的假绿）
退出码: 0=全部通过  1=存在失败  2=未开跑即中止（工具文件缺失 / -Case 无匹配）
.EXAMPLE
    pwsh test-ps-tools.ps1 -Case lint
#>
param(
    [string]$Case,
    [switch]$Keep,
    [string]$WorkDir = (Join-Path $env:TEMP 'ps-tools-test'),
    [string]$Lint = (Join-Path $PSScriptRoot 'ps-lint.ps1'),
    [string]$Fix = (Join-Path $PSScriptRoot 'fix-ps-punct.ps1')
)

# PowerShell 7 门禁：用运行时判断，不用 #Requires —— 后者在 5.1 下以 exit 1 中止，
# 与"存在语法错误"的退出码撞车，CI 分不清"环境不对"和"脚本有错"。
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: 需要 PowerShell 7+，当前 $($PSVersionTable.PSVersion)。这是调用环境问题（exit 2），不是脚本语法错误。"
    exit 2
}
$ErrorActionPreference = 'Stop'

# 被测工具必须存在：负向用例（"原文件不应被改""路径不存在应非 0"）在工具缺席时会天然成立，
# 曾实测出 lint-07 / fix-14 在工具路径不存在时仍报 PASS，故先断言再开跑。
foreach ($t in @($Lint, $Fix)) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host "ABORT: 找不到被测工具 $t" -ForegroundColor Red
        exit 2
    }
}

# 子进程用当前宿主可执行文件，不依赖 PATH 里能不能找到 pwsh
$script:HostExe = (Get-Process -Id $PID).Path
$Work = $WorkDir
if (Test-Path $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
New-Item -ItemType Directory -Path $Work | Out-Null

$script:passCount = 0; $script:failCount = 0
$script:failList = [System.Collections.Generic.List[string]]::new()

# 特殊字符（避免测试脚本自身携带不可见字符）
$FF0C = [string][char]0xFF0C   # 全角逗号
$FF1A = [string][char]0xFF1A   # 全角冒号
$FF02 = [string][char]0xFF02   # 全角引号 ＂
$201C = [string][char]0x201C   # 中文左弯双引
$201D = [string][char]0x201D   # 中文右弯双引
$FF1E = [string][char]0xFF1E   # 全角大于 ＞
$FF5B = [string][char]0xFF5B   # 全角花括号 ｛
$FF5D = [string][char]0xFF5D   # 全角花括号 ｝
$gt   = [string][char]0x003E   # 半角大于 >（PowerShell 里是重定向符，不是比较符）
$ZWSP = [string][char]0x200B   # 零宽空格
$FF04 = [string][char]0xFF04   # 全角美元 ＄（变量符）
$3002 = [string][char]0x3002   # 中文句号 。
$CJK  = [string][char]0x8BF4 + [string][char]0x660E + [string][char]0xFF0C + [string][char]0x8BE6 + [string][char]0x89C1  # 说明，详见

function New-Case([string]$name, [scriptblock]$body) {
    if ($Case -and $name -notlike "*$Case*") { return }
    try {
        & $body
        $script:passCount++
        Write-Host "PASS  $name" -ForegroundColor Green
    } catch {
        $script:failCount++
        $script:failList.Add($name)
        Write-Host "FAIL  $name :: $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Invoke-Tool([string]$tool, [string[]]$argList) {
    $out = & $script:HostExe -NoProfile -File $tool @argList 2>&1 | Out-String
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out.Trim() }
}
function Set-File([string]$rel, [string]$content, [Text.Encoding]$enc = $null) {
    $f = Join-Path $Work $rel
    if ($enc) { [IO.File]::WriteAllText($f, $content, $enc) } else { [IO.File]::WriteAllText($f, $content, [Text.UTF8Encoding]::new($false)) }
    $f
}
function Read-File([string]$path) { [IO.File]::ReadAllText($path) }
function Assert-True([bool]$cond, [string]$label) { if (-not $cond) { throw "断言失败: $label" } }
function Assert-Contains([string]$text, [string]$sub, [string]$label) {
    # 用字面 Contains 而非 -like（-like 通配符模式会把反引号当转义符）
    if (-not $text.Contains($sub)) { throw "断言失败: $label（缺少 [$sub]）" }
}

# ============ A. ps-lint 边界 ============
New-Case 'lint-01 空文件' {
    $f = Set-File 'lint_empty.ps1' ''
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -eq 0) "空文件应 exit 0, 实际 $($r.Exit): $($r.Out)"
}
New-Case 'lint-02 纯注释' {
    $f = Set-File 'lint_comment.ps1' "# 注释一`n# 注释二`n"
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -eq 0) "纯注释应通过: $($r.Out)"
}
New-Case 'lint-03 复杂合法脚本' {
    $content = @'
function Test-Fn([int]$n) {
    if ($n -gt 10) { return $n * 2 }
    switch ($n) { 1 { 'one' } default { 'other' } }
}
$here = @"
line1
$($env:COMPUTERNAME)
"@
try { Test-Fn 5 } catch { Write-Error $_ }
'@
    $f = Set-File 'lint_complex.ps1' $content
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -eq 0) "复杂脚本应通过: $($r.Out)"
}
New-Case 'lint-04 含错误脚本' {
    $f = Set-File 'lint_bad.ps1' "`$a = (1)$FF0C`nWrite-Host $FF02`x$FF02"
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -eq 1) "含错应 exit 1, 实际 $($r.Exit)"
    Assert-Contains $r.Out '处语法错误' '应报告错误数'
}
New-Case 'lint-05 UTF-16LE 带BOM' {
    $f = Set-File 'lint_utf16.ps1' "`$x = 1`n" ([Text.Encoding]::Unicode)
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -eq 0) "UTF-16 应通过: $($r.Out)"
}
New-Case 'lint-06 大文件性能' {
    $lines = for ($i = 0; $i -lt 2000; $i++) { "`$v$i = $i" }
    $f = Set-File 'lint_big.ps1' ($lines -join "`n")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Tool $Lint @($f)
    $sw.Stop()
    Assert-True ($r.Exit -eq 0) "2000 行应通过: $($r.Out)"
    Assert-True ($sw.Elapsed.TotalSeconds -lt 10) "耗时 $([Math]::Round($sw.Elapsed.TotalSeconds,1))s 超 10s"
}
New-Case 'lint-07 路径不存在' {
    $f = Join-Path $Work 'nope.ps1'
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -ne 0) "不存在路径应非 0 退出（不崩溃）: exit=$($r.Exit)"
}

# ============ B. fix-ps-punct 边界 ============
New-Case 'fix-01 合法文件不改' {
    $f = Set-File 'fix_clean.ps1' "`$x = 1`n"
    $h0 = (Get-FileHash $f).Hash
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "合法文件 exit 0: $($r.Out)"
    Assert-Contains $r.Out '未修改' '应提示未修改'
    $h1 = (Get-FileHash $f).Hash
    Assert-True ($h0 -eq $h1) '内容不应变化'
}
New-Case 'fix-02 代码区全角修复' {
    $f = Set-File 'fix_punct.ps1' "`$names = @(`n  `"a.log`"$FF0C`n  `"b.log`"`n)`nif (`$names.Count $FF1E 0)$FF5B`n  Write-Host ok`n$FF5D"
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "应 FIXED: $($r.Out)"
    Assert-Contains $r.Out 'FIXED' '应输出 FIXED'
    $c = Read-File $f
    Assert-Contains $c '"a.log",' '全角逗号应修复'
    Assert-Contains $c '> 0){' '全角比较/大括号应修复'
    Assert-True (Test-Path "$f.bak") '应生成 .bak'
}
New-Case 'fix-03 字符串内全角保留' {
    # 全角逗号放表达式中间（行尾逗号修复后会被 PS 当数组延续 → PARTIAL，属结构性错误）
    $content = "`$p = `"D$FF1A\Temp`"`n`$x = 1 $FF1E 0"
    $f = Set-File 'fix_str.ps1' $content
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "exit 0: $($r.Out)"
    Assert-Contains $r.Out 'FIXED' '应 FIXED'
    $c = Read-File $f
    Assert-Contains $c "D$FF1A\Temp" '字符串内全角冒号应保留'
    Assert-Contains $c '1 > 0' '代码区逗号应修复'
}
New-Case 'fix-04 注释内全角保留' {
    $f = Set-File 'fix_comment.ps1' "# 注释$FF1A全角`n`$x = 1 $FF1E 0"
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "exit 0: $($r.Out)"
    $c = Read-File $f
    Assert-Contains $c "# 注释$FF1A全角" '注释内全角应保留'
    Assert-Contains $c '1 > 0' '代码区逗号应修复'
}
New-Case 'fix-05 here-string 内保留' {
    $content = "`$sql = @'`nSELECT 'a'$FF0C'b'`n'@`n`$x = 1 $FF1E 0"
    $f = Set-File 'fix_here.ps1' $content
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "exit 0: $($r.Out)"
    $c = Read-File $f
    Assert-Contains $c "'a'$FF0C'b'" 'here-string 内全角应保留'
    Assert-Contains $c '1 > 0' '代码区逗号应修复'
}
New-Case 'fix-06 全角引号包字符串（合法但可疑）' {
    # PS 把 ＂found＂ 当裸词参数，语法合法 -> 不改文件，但必须报 WARN（旧版这里静默返回"未修改"）
    $content = "Write-Host $FF02`found$FF02"
    $f = Set-File 'fix_fwquote.ps1' $content
    $h0 = (Get-FileHash $f).Hash
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 3) "可疑但合法应为 WARN exit=3, 实际 $($r.Exit): $($r.Out)"
    Assert-Contains $r.Out 'WARN' '应输出 WARN'
    $h1 = (Get-FileHash $f).Hash
    Assert-True ($h0 -eq $h1) '文件内容不应变化'
}
New-Case 'fix-07 中文弯引号包字符串（PS 自身认作定界符）' {
    # 实测：U+201C/U+201D 被 tokenizer 当合法字符串界（Kind=StringExpandable），运行输出正常，
    # 整段属于保护区 -> 既不修改也不报 WARN（对比 fix-06 的 U+FF02，那个不是定界符）
    $content = "Write-Host $201C`你好$201D"
    $f = Set-File 'fix_cnquote.ps1' $content
    $h0 = (Get-FileHash $f).Hash
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "弯引号字符串应 exit 0, 实际 $($r.Exit): $($r.Out)"
    Assert-Contains $r.Out '未修改' '不应改动'
    $h1 = (Get-FileHash $f).Hash
    Assert-True ($h0 -eq $h1) '内容不应变化'
}
New-Case 'fix-08 单引号转义保留' {
    $content = "`$s = 'it''s'`n`$x = 1 $FF1E 0"
    $f = Set-File 'fix_sq.ps1' $content
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "exit 0: $($r.Out)"
    $c = Read-File $f
    Assert-Contains $c "'it''s'" "单引号 '' 转义应保留"
    Assert-Contains $c '1 > 0' '逗号应修复'
}
New-Case 'fix-09 双引号反引号转义保留' {
    # 目标: $s = "a`"b" + Write-Host 1，2（双引号串内反引号转义）——单引号字面+拼接避开转义嵌套
    $content = '$s = "a`"b"' + "`n" + '$x = 1 ' + $FF1E + ' 0'
    $f = Set-File 'fix_dq.ps1' $content
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "exit 0: $($r.Out)"
    $c = Read-File $f
    Assert-Contains $c 'a`"b' '反引号转义应保留'
    Assert-Contains $c '1 > 0' '逗号应修复'
}
New-Case 'fix-10 哈希表半角冒号 PARTIAL' {
    $content = "`$c = @{ name: demo }"
    $f = Set-File 'fix_hash.ps1' $content
    $h0 = (Get-FileHash $f).Hash
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 1) "应 PARTIAL exit 1: $($r.Out)"
    Assert-Contains $r.Out 'PARTIAL' '应提示 PARTIAL'
    $h1 = (Get-FileHash $f).Hash
    Assert-True ($h0 -eq $h1) '失败时不写回'
    Assert-True (-not (Test-Path "$f.bak")) '失败时不生成 .bak'
}
New-Case 'fix-11 零宽空格变量名' {
    $f = Set-File 'fix_zwsp.ps1' "`$fla${ZWSP}g = `$true"
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "exit 0: $($r.Out)"
    Assert-Contains $r.Out 'FIXED' '应 FIXED'
    Assert-Contains (Read-File $f) '$flag = $true' 'ZWSP 应清除'
}
New-Case 'fix-12 字符串内零宽保留' {
    $content = "`$s = `"a${ZWSP}b`""
    $f = Set-File 'fix_zwsp_str.ps1' $content
    $h0 = (Get-FileHash $f).Hash
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "exit 0: $($r.Out)"
    Assert-Contains $r.Out '未修改' '语法通过应不修改'
    $h1 = (Get-FileHash $f).Hash
    Assert-True ($h0 -eq $h1) '字符串内 ZWSP 不应被动'
}
New-Case 'fix-13 重复运行幂等' {
    $f = Set-File 'fix_idem.ps1' "`$names = @(`n  `"a.log`",`n  `"b.log`"`n)`nif (`$names.Count > 0){`n  Write-Host ok`n}"
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "exit 0: $($r.Out)"
    Assert-Contains $r.Out '未修改' '已干净文件应不修改'
}
New-Case 'fix-14 只读文件' {
    $f = Set-File 'fix_ro.ps1' "`$x = 1$FF0C"
    Set-ItemProperty $f -Name IsReadOnly -Value $true
    try {
        $r = Invoke-Tool $Fix @($f)
        $c = Read-File $f
        Assert-Contains $c $FF0C '只读失败时原文件不应被修改'
    } finally {
        Set-ItemProperty $f -Name IsReadOnly -Value $false
    }
}
New-Case 'fix-15 嵌套子表达式' {
    $content = "`$s = `"a`$( `"b`" )c`"`n`$x = 1 $FF1E 0"
    $f = Set-File 'fix_nested.ps1' $content
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "exit 0: $($r.Out)"
    Assert-Contains (Read-File $f) '1 > 0' '嵌套场景修复应生效'
}
New-Case 'fix-16 UTF-16 输入' {
    $f = Set-File 'fix_utf16.ps1' "`$x = 1 $FF1E 0" ([Text.Encoding]::Unicode)
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "UTF-16 输入应 FIXED: $($r.Out)"
    Assert-Contains (Read-File $f) '1 > 0' '修复应生效'
}

# ============ C. 回归缺口用例（字节级断言 + 套件自身完整性） ============
New-Case 'lint-08 单行文件含错（Get-Content 标量陷阱）' {
    # 单行（无尾换行）时 Get-Content 返回 String 而非数组，$lines[$ln-1] 得到 Char
    $f = Set-File 'lint_1line.ps1' "`$x = 1 $FF1E 0"
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -eq 1) "单行含错应 exit 1: $($r.Out)"
    Assert-True (-not $r.Out.Contains('TrimEnd')) "ps-lint 不应抛内部异常: $($r.Out)"
    Assert-Contains $r.Out '> $x = 1 ' '单行文件也应打印出错行源码'
}
New-Case 'lint-09 单行多错条目完整' {
    # 该构造实测产生 3 处 ParseError（L1C8 x2 + L1C11）
    $f = Set-File 'lint_1line_multi.ps1' "if (`$x $FF1E 0)$FF5B"
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -eq 1) "应 exit 1: $($r.Out)"
    $total = [int]([regex]::Match($r.Out, 'FAIL: (\d+)').Groups[1].Value)
    $listed = @($r.Out -split "`n" | Where-Object { $_ -match '^\s+L\d+C\d+:' }).Count
    Assert-True ($total -eq 3) "该构造应报 3 处错误，实际 $total : $($r.Out)"
    Assert-True ($listed -eq $total) "列出条目 $listed 条 != 头部计数 $total（中途异常断流）: $($r.Out)"
}
New-Case 'fix-17 UTF-16 写回保留原编码（字节级）' {
    $f = Set-File 'fix_utf16_keep.ps1' "`$x = 1 $FF1E 0" ([Text.Encoding]::Unicode)
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "应 FIXED: $($r.Out)"
    $b = [IO.File]::ReadAllBytes($f)
    $head = ($b[0..1] | ForEach-Object { $_.ToString('X2') }) -join ' '
    Assert-True ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) "写回应仍是 UTF-16LE+BOM，实际头部 $head（被整体重写成 UTF-8 会破坏原编码约定）"
    Assert-Contains (Read-File $f) '1 > 0' '修复内容应生效'
}
New-Case 'fix-18 UTF-8 BOM 与中文保留（Windows PowerShell 5.1 可读性）' {
    $CJK = [string][char]0x4E2D + [string][char]0x6587   # 中文
    $f = Set-File 'fix_utf8bom.ps1' "Write-Host '$CJK'`n`$x = 1 $FF1E 0" ([Text.UTF8Encoding]::new($true))
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "应 FIXED: $($r.Out)"
    $b = [IO.File]::ReadAllBytes($f)
    $head = ($b[0..2] | ForEach-Object { $_.ToString('X2') }) -join ' '
    # 无 BOM 的 UTF-8 中文脚本在 Windows PowerShell 5.1 下按 GBK 解码 -> 输出乱码，而 ps-lint 仍报 OK
    Assert-True ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) "写回应保留 UTF-8 BOM，实际头部 $head（5.1 会按 GBK 读，中文变乱码）"
    Assert-Contains (Read-File $f) $CJK '中文字符串内容不应损坏'
}
New-Case 'fix-19 GBK(cp936) 输入字节不得改变' {
    $gbk = [Text.Encoding]::GetEncoding(936)
    $CJK = [string][char]0x6D4B + [string][char]0x8BD5   # 测试
    $f = Set-File 'fix_gbk.ps1' "# $CJK`nWrite-Host '$CJK'`n`$x = 1 $FF1E 0" $gbk
    $b0 = [IO.File]::ReadAllBytes($f)
    $r = Invoke-Tool $Fix @($f)
    $b1 = [IO.File]::ReadAllBytes($f)
    Assert-True (($b0 -join ',') -eq ($b1 -join ',')) "GBK 文件字节必须逐字节不变（exit=$($r.Exit)）: $($r.Out)"
    if ($r.Exit -eq 0) {
        Assert-True ($gbk.GetString($b1).Contains($CJK)) 'FIXED 后 GBK 中文仍应完好'
    }
}
New-Case 'fix-20 已存在的 .bak 不得被覆盖' {
    $f = Set-File 'fix_bak.ps1' "`$x = 1 $FF1E 0"
    $marker = 'USER-MANUAL-BACKUP'
    Set-Content -LiteralPath "$f.bak" -Value $marker -Encoding ascii
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "应 FIXED: $($r.Out)"
    Assert-Contains (Read-File "$f.bak") $marker '用户已有的 .bak 必须原样保留'
    Assert-Contains (Read-File $f) '1 > 0' '修复应生效'
    Assert-True (@([IO.Directory]::GetFiles($Work, 'fix_bak.ps1.bak*')).Count -ge 2) '应另存一份带时间戳的备份'
    Assert-True ($r.Out.Contains('.bak-')) "输出应给出实际备份名: $($r.Out)"
}
New-Case 'suite-01 -Case 无匹配必须非 0（防空跑变绿）' {    $r = Invoke-Tool $PSCommandPath @('-Case', 'zzz-not-a-case', '-WorkDir', (Join-Path $env:TEMP 'ps-tools-test-selfcheck1'), '-Lint', $Lint, '-Fix', $Fix)
    Assert-True ($r.Exit -ne 0) "-Case 打错字时 exit=$($r.Exit)，0 通过 0 失败不能算通过: $($r.Out)"
}
New-Case 'suite-02 工具缺失时整套件必须非 0（防负向断言空过）' {
    $fake = Join-Path $Work 'absent-tool.ps1'
    $r = Invoke-Tool $PSCommandPath @('-Lint', $fake, '-Fix', $fake, '-Case', 'lint-01', '-WorkDir', (Join-Path $env:TEMP 'ps-tools-test-selfcheck2'), '-Keep')
    Assert-True ($r.Exit -ne 0) "被测工具不存在时 exit=$($r.Exit)（曾出现工具缺席仍报 PASS）: $($r.Out)"
}

# ============ D. 新退出码 / -Quiet / -AsJson / 多文件 / WARN 检出 ============
New-Case 'lint-10 退出码分层（0/1/2）' {
    $ok = Set-File 'lint_ok10.ps1' "`$x = 1`n"
    $bad = Set-File 'lint_bad10.ps1' ("`$x = 1 $FF1E 0" + "`n" + 'Write-Host 2')
    $r1 = Invoke-Tool $Lint @($ok)
    Assert-True ($r1.Exit -eq 0) "干净应 0: $($r1.Exit)"
    $r2 = Invoke-Tool $Lint @($bad)
    Assert-True ($r2.Exit -eq 1) "语法错应 1: $($r2.Exit)"
    $r3 = Invoke-Tool $Lint @(Join-Path $Work 'definitely-missing.ps1')
    Assert-True ($r3.Exit -eq 2) "路径不存在应 2, 实际 $($r3.Exit)"
    $r4 = Invoke-Tool $Lint @($Work)
    Assert-True ($r4.Exit -eq 2) "传目录应 2, 实际 $($r4.Exit): $($r4.Out)"
    Assert-True (-not $r4.Out.Contains('处语法错误')) '目录不该被当成语法错误上报'
}
New-Case 'lint-11 -Quiet 只给退出码' {
    $ok = Set-File 'lint_q1.ps1' "`$x = 1`n"
    $bad = Set-File 'lint_q2.ps1' ("`$x = 1 $FF1E 0" + "`n" + 'Write-Host 2')
    $r1 = Invoke-Tool $Lint @($ok, '-Quiet')
    Assert-True ($r1.Exit -eq 0) "quiet 干净应 0: $($r1.Exit)"
    Assert-True ($r1.Out.Length -eq 0) "quiet 不应有输出: [$($r1.Out)]"
    $r2 = Invoke-Tool $Lint @($bad, '-Quiet')
    Assert-True ($r2.Exit -eq 1) "quiet 有错应 1: $($r2.Exit)"
    Assert-True ($r2.Out.Length -eq 0) "quiet 不应打印错误明细: [$($r2.Out)]"
}
New-Case 'lint-12 -AsJson 结构可用' {
    $bad = Set-File 'lint_json.ps1' ("`$x = 1 $FF1E 0" + "`n" + 'Write-Host 2')
    $r = Invoke-Tool $Lint @($bad, '-AsJson')
    Assert-True ($r.Exit -eq 1) "应 exit 1: $($r.Exit) $($r.Out)"
    $o = $null
    try { $o = @($r.Out | ConvertFrom-Json) } catch { throw "输出不是合法 JSON: [$($r.Out)]" }
    Assert-True ($o.Count -eq 1) "应 1 条记录: $($r.Out)"
    Assert-True ($o[0].status -eq 'FAIL') "status 应为 FAIL: $($r.Out)"
    Assert-True ($o[0].count -ge 1) "count 应 >=1: $($r.Out)"
    Assert-True ($null -ne $o[0].errors[0].line) ("errors 应带行号: " + $r.Out)
}
New-Case 'lint-13 多文件一次调用' {
    $ok = Set-File 'lint_m1.ps1' "`$x = 1`n"
    $bad = Set-File 'lint_m2.ps1' ("`$x = 1 $FF1E 0" + "`n" + 'Write-Host 2')
    $r = Invoke-Tool $Lint @($ok, $bad)
    Assert-True ($r.Exit -eq 1) "含错文件应让整体 exit 1: $($r.Exit)"
    Assert-Contains $r.Out 'OK: ' '干净文件应单独报 OK'
    Assert-Contains $r.Out '处语法错误' '出错文件应报错误数'
}
New-Case 'lint-14 符号比较被检出（> 会被当重定向）' {
    # 注意：数组字面量里 'a' + $x + 'b' 会被拆成多个元素（逗号优先级高于 +），必须先算好再放进去
    $cond = 'if ($n ' + $gt + ' 0){'
    $f = Set-File 'lint_cmp.ps1' (@('$n = 5', $cond, '  Write-Host "x"', '}') -join "`n")
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -eq 3) "符号比较应 exit 3, 实际 $($r.Exit): $($r.Out)"
    Assert-Contains $r.Out 'WARN' '应报 WARN'
    Assert-Contains $r.Out '可疑符号比较' '应说明是符号比较'
    Assert-Contains $r.Out '-gt' '应给出改用 -gt 的建议'
}
New-Case 'lint-15 合法重定向不误报' {
    $f = Set-File 'lint_redir.ps1' ('Write-Host "x" ' + $gt + ' out.txt')
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -eq 0) "合法重定向应 0, 实际 $($r.Exit): $($r.Out)"
}
New-Case 'lint-16 -gt 正确写法不误报' {
    $f = Set-File 'lint_gt.ps1' "if (`$n -gt 0){ Write-Host ok }`n"
    $r = Invoke-Tool $Lint @($f)
    Assert-True ($r.Exit -eq 0) "-gt 应 0, 实际 $($r.Exit): $($r.Out)"
}
New-Case 'lint-17 多文件取最严重（WARN 不得压住语法错）' {
    # WARN 的退出码数值是 3、语法错是 1，但优先级是 1 更高：曾因直接比退出码大小而出错
    $cond = 'if ($n ' + $gt + ' 0){ }'
    $warn = Set-File 'lint_w17.ps1' (@('$n = 5', $cond) -join "`n")
    $fail = Set-File 'lint_f17.ps1' 'if ($true { }'
    $r1 = Invoke-Tool $Lint @($warn, $fail, '-Quiet')
    Assert-True ($r1.Exit -eq 1) "WARN+语法错应 1, 实际 $($r1.Exit)"
    $r2 = Invoke-Tool $Lint @($fail, $warn, '-Quiet')
    Assert-True ($r2.Exit -eq 1) "语法错+WARN 应 1, 实际 $($r2.Exit)"
    $r3 = Invoke-Tool $Lint @((Join-Path $Work 'missing17.ps1'), $warn, '-Quiet')
    Assert-True ($r3.Exit -eq 2) "不存在+WARN 应 2, 实际 $($r3.Exit)"
    $r4 = Invoke-Tool $Lint @($warn, '-Quiet')
    Assert-True ($r4.Exit -eq 3) "仅 WARN 应 3, 实际 $($r4.Exit)"
}
New-Case 'lint-18 -AsJson 的 WARN 记录含 Warnings 字段' {
    $cond = 'if ($n ' + $gt + ' 0){ }'
    $f = Set-File 'lint_j18.ps1' (@('$n = 5', $cond) -join "`n")
    $r = Invoke-Tool $Lint @($f, '-AsJson')
    Assert-True ($r.Exit -eq 3) "应 exit 3: $($r.Exit) $($r.Out)"
    $o = $null
    try { $o = @($r.Out | ConvertFrom-Json) } catch { throw "输出不是合法 JSON: [$($r.Out)]" }
    Assert-True ($o[0].status -eq 'WARN') "status 应为 WARN: $($r.Out)"
    Assert-True ($o[0].warnings.Count -ge 1) "warnings 应有记录: $($r.Out)"
    Assert-True ($null -ne $o[0].warnings[0].line) "warnings 应带行号: $($r.Out)"
}
New-Case 'fix-21 连续两次修复原件不被第二次覆盖' {
    $f = Set-File 'fix_twice.ps1' "`$x = 1 $FF1E 0"
    $r1 = Invoke-Tool $Fix @($f)
    Assert-True ($r1.Exit -eq 0) "run1 应 FIXED: $($r1.Out)"
    $bak1 = (Get-FileHash "$f.bak").Hash
    Set-Content -LiteralPath $f -Value "`$y = 3 $FF1E 4" -Encoding utf8NoBOM -NoNewline
    $r2 = Invoke-Tool $Fix @($f)
    Assert-True ($r2.Exit -eq 0) "run2 应 FIXED: $($r2.Out)"
    Assert-True ((Get-FileHash "$f.bak").Hash -eq $bak1) '第一版原件 .bak 不应被第二次修复覆盖'
    Assert-True (@([IO.Directory]::GetFiles($Work, 'fix_twice.ps1.bak*')).Count -ge 2) '第二次应另存时间戳备份'
    Assert-Contains $r2.Out '.bak-' 'run2 输出应给出实际备份名'
}
New-Case 'fix-22 WARN 全角标点并入 token（旧版静默放过）' {
    $f = Set-File 'fix_warn_merge.ps1' ("`$a = 1" + $FF0C + '2')
    $h0 = (Get-FileHash $f).Hash
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 3) "应 WARN exit=3, 实际 $($r.Exit): $($r.Out)"
    Assert-Contains $r.Out 'U+FF0C' '应给出码位'
    Assert-True ((Get-FileHash $f).Hash -eq $h0) 'WARN 不应改动文件'
    Assert-True (-not (Test-Path "$f.bak")) 'WARN 不应留下备份'
}
New-Case 'fix-23 -All 修复合法文件里的全角变量符' {
    $f = Set-File 'fix_all_dollar.ps1' ($FF04 + 'x = 1')
    $r = Invoke-Tool $Fix @($f, '-All')
    Assert-True ($r.Exit -eq 0) "应 FIXED: $($r.Out)"
    Assert-Contains (Read-File $f) '$x = 1' '＄x 应修为 $x'
}
New-Case 'fix-24 语义猜测类（中文句号）单独计数' {
    $f = Set-File 'fix_semantic.ps1' ("`$x = 1$3002" + "`n" + "`$y = 2")
    $r = Invoke-Tool $Fix @($f, '-All')
    Assert-True ($r.Exit -eq 0) "应 FIXED: $($r.Out)"
    Assert-Contains $r.Out '语义猜测 1' '应单独计入语义猜测类'
    Assert-Contains (Read-File $f) '$x = 1;' '中文句号应改成分号'
}
New-Case 'fix-25 双引号子表达式内全角属字符串数据，不处理也不报' {
    # ，位于可展开字符串内部的 $(...) 里 -> 整段按字符串保护；一处都没改时不得写回、不得留 .bak
    $f = Set-File 'fix_nested_dq.ps1' ("`$s = `"A`$( Get-Date -Format 'yyyy" + $FF0C + "MM' )B`"")
    $h0 = (Get-FileHash $f).Hash
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "应 exit 0（字符串内数据不算可疑）, 实际 $($r.Exit): $($r.Out)"
    Assert-True ((Get-FileHash $f).Hash -eq $h0) '子表达式内全角字符不应被改'
    Assert-True (-not (Test-Path "$f.bak")) '0 处替换不应写回、不应留 .bak'
}
New-Case 'fix-26 -AsJson 输出可解析' {
    $f = Set-File 'fix_json.ps1' "`$x = 1 $FF1E 0"
    $r = Invoke-Tool $Fix @($f, '-AsJson')
    Assert-True ($r.Exit -eq 0) "应 exit 0: $($r.Exit) $($r.Out)"
    $o = $null
    try { $o = @($r.Out | ConvertFrom-Json) } catch { throw "输出不是合法 JSON: [$($r.Out)]" }
    Assert-True ($o[0].status -eq 'FIXED') "status 应 FIXED: $($r.Out)"
    Assert-True ($o[0].faithful -eq 1) "faithful 应为 1: $($r.Out)"
    Assert-True ($o[0].replaced -eq 1) "replaced 应为 1: $($r.Out)"
    Assert-True ($null -ne $o[0].notes) "notes 字段应存在: $($r.Out)"
}
New-Case 'fix-27 中文文本跑保留、同文件真错误修好' {
    $f = Set-File 'fix_cjk_run.ps1' ("Write-Host $CJK" + "`n" + "`$y = 1 $FF1E 0")
    $r = Invoke-Tool $Fix @($f)
    Assert-True ($r.Exit -eq 0) "应 FIXED: $($r.Out)"
    $after = Read-File $f
    Assert-Contains $after $CJK '说明，详见 应原样保留'
    Assert-Contains $after '$y = 1 > 0' '真错误应被修好'
    Assert-Contains $r.Out 'SUSPECT' '应报告跳过了哪些位置'
}

New-Case 'fix-28 只报不改类（＃ 不得被转成注释吞掉代码）' {
    $SHARP = [string][char]0xFF03
    $f = Set-File 'fix_reportonly.ps1' ("`$x = 1 $FF1E 0" + "`n" + ('Write-Host ' + $SHARP + 'tail'))
    $r = Invoke-Tool $Fix @($f, '-All')
    Assert-True ($r.Exit -eq 0) "应 FIXED: $($r.Exit) $($r.Out)"
    $after = Read-File $f
    Assert-Contains $after ($SHARP + 'tail') '＃ 后的内容不应被改成注释而静默删码'
    Assert-Contains $r.Out 'SUSPECT' '应报告只报不改的字符'
    Assert-Contains $after '$x = 1 > 0' '同形类仍应正常修复'
}

New-Case 'fix-29 多文件取最严重（PARTIAL 不得被 WARN 压住）' {
    # WARN 的退出码数值是 3、PARTIAL 是 1，但优先级相反：曾因直接比退出码大小而出错
    $warnContent = $FF04 + 'x = 1'
    $warn = Set-File 'fix_w29.ps1' $warnContent
    $partial = Set-File 'fix_p29.ps1' '$c = @{ name: demo }'
    $r1 = Invoke-Tool $Fix @($warn, $partial)
    Assert-True ($r1.Exit -eq 1) "WARN+PARTIAL 应 1, 实际 $($r1.Exit): $($r1.Out)"
    $r2 = Invoke-Tool $Fix @($partial, $warn)
    Assert-True ($r2.Exit -eq 1) "PARTIAL+WARN 应 1, 实际 $($r2.Exit): $($r2.Out)"
    $r3 = Invoke-Tool $Fix @((Join-Path $Work 'missing29.ps1'), $warn)
    Assert-True ($r3.Exit -eq 2) "不存在+WARN 应 2, 实际 $($r3.Exit)"
    $r4 = Invoke-Tool $Fix @($warn)
    Assert-True ($r4.Exit -eq 3) "仅 WARN 应 3, 实际 $($r4.Exit): $($r4.Out)"
}

# ============ 汇总 ============
if (-not $Keep) { Remove-Item -LiteralPath $Work -Recurse -Force }
Write-Host ''
Write-Host '================================'
Write-Host "通过: $($script:passCount)  失败: $($script:failCount)"
if ($script:failList.Count) { Write-Host ("失败用例: " + ($script:failList -join '; ')) }
if ($script:failCount -gt 0) { exit 1 }
if ($Case -and ($script:passCount + $script:failCount) -eq 0) {
    Write-Host "ABORT: -Case '$Case' 未匹配任何用例" -ForegroundColor Red
    exit 2
}
exit 0
