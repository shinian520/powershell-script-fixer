#Requires -Version 7
<#
.SYNOPSIS
    把本仓库打包成符合 DeepSeek Harness 插件规范的目录与 ZIP。
.DESCRIPTION
    产物 <仓库>\dist\plugin\powershell-script-fixer\ 内含：
      package.json（name + 精确 SemVer + main + dsh.bundle.patch）
      patches/bundle.yaml（空列表）
      lib/index.js（纯 JS）
      scripts\ / references\ / SKILL.md / README.md / LICENSE
    校验：node --check 入口、package.json 字段、bundle.patch 与 main 真实存在、ZIP 根有 package.json。
.EXAMPLE
    pwsh plugin\build.ps1
    pwsh plugin\build.ps1 -Zip
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [string]$OutDir,
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'dist\plugin' }

$target = Join-Path $OutDir 'powershell-script-fixer'
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Force -Path $target | Out-Null

# 插件元数据与入口
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'package.json') -Destination $target
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $target 'plugin-README.md')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'lib') -Destination $target -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'patches') -Destination $target -Recurse

# 运行依赖：工具脚本必须随包分发（插件靠它们干活）
Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts') -Destination $target -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'references') -Destination $target -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'SKILL.md') -Destination $target
foreach ($f in @('README.md', 'LICENSE')) {
    $src = Join-Path $repoRoot $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $target }
}

# ---- 校验（按指南的拦截项逐条）----
$pkg = Get-Content -LiteralPath (Join-Path $target 'package.json') -Raw | ConvertFrom-Json
if ($pkg.name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { throw "package.json name 非法: $($pkg.name)" }
if ($pkg.version -notmatch '^\d+\.\d+\.\d+$') { throw "package.json version 必须是精确 SemVer: $($pkg.version)" }
if (-not $pkg.dsh.bundle.patch) { throw 'package.json 缺少 dsh.bundle.patch' }
if (-not (Test-Path -LiteralPath (Join-Path $target $pkg.dsh.bundle.patch))) { throw "bundle.patch 不存在: $($pkg.dsh.bundle.patch)" }
if (-not (Test-Path -LiteralPath (Join-Path $target $pkg.main))) { throw "main 不存在: $($pkg.main)" }
& node --check (Join-Path $target $pkg.main)
if ($LASTEXITCODE -ne 0) { throw 'lib/index.js 语法检查未通过' }

$scriptCount = (Get-ChildItem -LiteralPath (Join-Path $target 'scripts') -Filter *.ps1).Count
Write-Host ("插件目录: {0}" -f $target)
Write-Host ("  版本 {0} / 入口 {1} / 脚本 {2} 个" -f $pkg.version, $pkg.main, $scriptCount)
$mirror = [regex]::Match((Get-Content -LiteralPath (Join-Path $target 'SKILL.md') -Raw), '(?m)^version:\s*(.+)$').Groups[1].Value.Trim()
if ($mirror -and $mirror -ne $pkg.version) { Write-Host "WARN: SKILL.md 版本 $mirror 与 package.json $($pkg.version) 不一致" }

if ($Zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $OutDir ("powershell-script-fixer-plugin-v{0}.zip" -f $pkg.version)
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($target, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    $z = [IO.Compression.ZipFile]::OpenRead($zipPath)
    $names = @($z.Entries.FullName)
    $z.Dispose()
    if ($names -notcontains 'package.json') { throw 'ZIP 根目录缺少 package.json（市场会拒绝）' }
    Write-Host ("ZIP: {0}  {1:N0} 字节 / {2} 条目" -f $zipPath, (Get-Item $zipPath).Length, $names.Count)
}
