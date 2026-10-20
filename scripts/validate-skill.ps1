<#
.SYNOPSIS
    发布前自检：校验 SKILL.md 的 YAML Frontmatter 与正文必备小节。
.DESCRIPTION
validate-skill.ps1 - 发布前自检：SKILL.md 的 Frontmatter 与正文是否满足
                     DeepSeek Harness Skill 市场（https://deepseek.stream/guide）的解析规范
用法: pwsh validate-skill.ps1 [-SkillMd <SKILL.md 路径>] [-AsJson]
默认校验本脚本上一级目录的 SKILL.md。
退出码: 0=合规  1=不合规（逐条列出原因）  2=文件缺失/读取失败
.EXAMPLE
    pwsh validate-skill.ps1 -AsJson
#>
# Write-Host 用于 CLI 人类可读输出，属刻意使用
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [string]$SkillMd,
    [switch]$AsJson
)

# PowerShell 7 门禁：用运行时判断，不用 #Requires —— 后者在 5.1 下以 exit 1 中止，
# 与"存在语法错误"的退出码撞车，CI 分不清"环境不对"和"脚本有错"。
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: 需要 PowerShell 7+，当前 $($PSVersionTable.PSVersion)。这是调用环境问题（exit 2），不是脚本语法错误。"
    exit 2
}

$ErrorActionPreference = 'Stop'

if (-not $SkillMd) { $SkillMd = Join-Path (Split-Path -Parent $PSScriptRoot) 'SKILL.md' }

$problems = [System.Collections.Generic.List[string]]::new()
$passes = [System.Collections.Generic.List[string]]::new()
$info = [ordered]@{}

if (-not (Test-Path -LiteralPath $SkillMd)) {
    if ($AsJson) { Write-Output (@{ ok = $false; problems = @("找不到 $SkillMd") } | ConvertTo-Json) }
    else { Write-Host "ERROR: 找不到 $SkillMd" }
    exit 2
}

$lines = @(Get-Content -LiteralPath $SkillMd)
if ($lines.Count -lt 3) {
    if ($AsJson) { Write-Output (@{ ok = $false; problems = @('文件过短') } | ConvertTo-Json) }
    else { Write-Host 'ERROR: 文件过短' }
    exit 2
}

# 1) Frontmatter 必须从第一行 --- 开始，并有闭合 ---
if ($lines[0].Trim() -ne '---') {
    $problems.Add("第 1 行必须是 ---（当前: '$($lines[0])'）")
    $end = -1
} else {
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { $problems.Add('Frontmatter 未闭合（缺少第二行 ---）') }
}

$bodyStart = if ($end -gt 0) { $end + 1 } else { 0 }
$body = if ($bodyStart -lt $lines.Count) { @($lines[$bodyStart..($lines.Count - 1)]) } else { @() }

if ($end -gt 0) {
    $fmLines = @($lines[1..($end - 1)])
    # 只取顶层 key（顶格、形如 key: value），避免把 tags 的列表项当字段
    $fields = @{}
    foreach ($l in $fmLines) {
        if ($l -match '^([A-Za-z][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            $fields[$Matches[1]] = $Matches[2].Trim()
        }
    }
    $info['fields'] = @($fields.Keys | Sort-Object)

    foreach ($req in @('name', 'version', 'category', 'description', 'whenToUse')) {
        if (-not $fields.ContainsKey($req) -or [string]::IsNullOrWhiteSpace($fields[$req])) {
            $problems.Add("缺少必填字段: $req")
        } else {
            $passes.Add("字段 $req 存在")
        }
    }

    if ($fields.ContainsKey('name')) {
        if ($fields['name'] -cmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { $passes.Add('name 为合法 kebab-case') }
        else { $problems.Add("name 必须是 kebab-case（仅小写字母/数字/中划线）: '$($fields['name'])'") }
    }

    if ($fields.ContainsKey('version')) {
        if ($fields['version'] -match '^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$') { $passes.Add('version 为合法 SemVer') }
        else { $problems.Add("version 必须是 SemVer（如 1.0.0）: '$($fields['version'])'") }
    }

    $enum = @('academic', 'security', 'reverse', 'workflow', 'dev', 'ops', 'prompt', 'tools')
    if ($fields.ContainsKey('category')) {
        if ($enum -contains $fields['category'].ToLowerInvariant()) { $passes.Add("category '$($fields['category'])' 在 8 类枚举内") }
        else { $problems.Add("category 必须是 $($enum -join ' / ') 之一: '$($fields['category'])'") }
    }

    foreach ($flag in @('disableModelInvocation', 'userInvocable')) {
        if ($fields.ContainsKey($flag)) {
            if ($fields[$flag] -match '^(true|false)$') { $passes.Add("$flag 为布尔字面量") }
            else { $problems.Add("$flag 必须是 true/false: '$($fields[$flag])'") }
        }
    }
    if (-not $fields.ContainsKey('disableModelInvocation')) { $passes.Add('disableModelInvocation 未写，按规范默认 false') }
    if (-not $fields.ContainsKey('userInvocable')) { $passes.Add('userInvocable 未写，按规范默认 true') }
}

# 2) 正文必备结构
$bodyText = $body -join "`n"
$required = @(
    @{ Pattern = '(?m)^#\s+\S'; Label = '# 技能名称' },
    @{ Pattern = '(?m)^##\s+适用场景'; Label = '## 适用场景' },
    @{ Pattern = '(?m)^##\s+执行工作流与检查清单'; Label = '## 执行工作流与检查清单' },
    @{ Pattern = '(?m)^##\s+输出格式规范与边界条件'; Label = '## 输出格式规范与边界条件' }
)
foreach ($r in $required) {
    if ($bodyText -match $r.Pattern) { $passes.Add("正文含 $($r.Label)") }
    else { $problems.Add("正文缺少小节 $($r.Label)") }
}

# 2.5) 插件壳是可选的、且不该出现在仓库根目录：
#      市场按「所选目录」判定形态，根目录有 package.json 就会被当插件校验。
#      因此这里校验 plugin-shell/package.json（若存在），并确认根目录没有 package.json。
$skillVersion = if ($fields -and $fields.ContainsKey('version')) { $fields['version'] } else { $null }
$skillRoot = Split-Path -Parent $SkillMd
$rootPkg = Join-Path $skillRoot 'package.json'
$pkgJson = Join-Path $skillRoot 'plugin-shell\package.json'

if (Test-Path -LiteralPath $rootPkg) {
    $problems.Add('根目录存在 package.json：市场会把它当插件，Skill 形态应只有 SKILL.md。请移到 plugin-shell/ 子目录')
} else {
    $passes.Add('根目录无 package.json（纯 Skill 形态）')
}

if (Test-Path -LiteralPath $pkgJson) {
    $pj = $null
    try { $pj = Get-Content -LiteralPath $pkgJson -Raw | ConvertFrom-Json } catch { $problems.Add("plugin-shell/package.json 不是合法 JSON: $($_.Exception.Message)") }
    if ($pj) {
        if ($pj.name -cmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { $passes.Add("plugin-shell name 合法: $($pj.name)") }
        else { $problems.Add("plugin-shell name 必须全小写字母/数字/中划线: '$($pj.name)'") }

        if ($pj.version -match '^\d+\.\d+\.\d+$') { $passes.Add("plugin-shell version 为精确 SemVer: $($pj.version)") }
        else { $problems.Add("plugin-shell version 必须是精确 SemVer: '$($pj.version)'") }

        if ($skillVersion) {
            if ($pj.version -ne $skillVersion) {
                $problems.Add("版本不一致：SKILL.md=$skillVersion / plugin-shell=$($pj.version)")
            } else {
                $passes.Add("SKILL.md 与 plugin-shell 版本一致: $skillVersion")
            }
        }

        $shellRoot = Join-Path $skillRoot 'plugin-shell'
        $mainRel = [string]$pj.main
        if ($mainRel -and (Test-Path -LiteralPath (Join-Path $shellRoot $mainRel))) { $passes.Add("plugin-shell main 指向真实入口: $mainRel") }
        else { $problems.Add("plugin-shell main 指向不存在的文件: '$mainRel'") }

        $patchRel = [string]$pj.dsh.bundle.patch
        if ($patchRel -and (Test-Path -LiteralPath (Join-Path $shellRoot $patchRel))) { $passes.Add("plugin-shell dsh.bundle.patch 存在: $patchRel") }
        else { $problems.Add("plugin-shell 缺少 dsh.bundle.patch 或文件不存在: '$patchRel'") }
    }
} else {
    $passes.Add('未提供 plugin-shell（纯 Skill 发布，无需插件壳）')
}

$ok = $problems.Count -eq 0
if ($AsJson) {
    Write-Output ([pscustomobject]@{
            ok = $ok; path = (Resolve-Path -LiteralPath $SkillMd).Path
            passes = @($passes); problems = @($problems); info = $info
        } | ConvertTo-Json -Depth 5)
} else {
    Write-Host "校验对象: $((Resolve-Path -LiteralPath $SkillMd).Path)"
    foreach ($p in $passes) { Write-Host "  OK   $p" }
    foreach ($p in $problems) { Write-Host "  BAD  $p" }
    Write-Host ''
    if ($ok) { Write-Host "结论: 合规（$($passes.Count) 项通过）" }
    else { Write-Host "结论: 不合规（$($problems.Count) 项问题）" }
}
if ($ok) { exit 0 }
exit 1
