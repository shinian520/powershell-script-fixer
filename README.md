# PowerShell 脚本质检修复（powershell-script-fixer）

> **PowerShell script lint & full-width punctuation auto-fixer** — a DeepSeek Harness Skill.
> Catches `ParseError`s, the silent `>`-as-redirection trap, invisible chars; auto-fixes full-width punctuation
> with a real-tokenizer protection zone; 49 + 9 regression cases; byte-exact encoding preservation.

DeepSeek Harness 原生技能（Skill）包。专治 **AI 生成的 PowerShell 脚本**三类问题：

1. **语法错**：全角逗号/冒号/括号/引号、缺逗号、多冒号 → `Unexpected token '，'`。
2. **静默失败**：`if ($x > 0)` 把 `>` 当重定向 —— 分支输出被丢弃、磁盘多出名为 `0` 的怪文件，而进程 `exit 0`。
3. **不可见污染**：零宽空格、全角空格、文件中段 BOM、编码被改坏导致中文乱码。

零编译、零依赖（仅需 PowerShell 7+），Markdown + 三个 `.ps1`。

## 目录结构

```
powershell-script-fixer/
├── SKILL.md                              # 技能主文件（YAML Frontmatter + 工作流规程）
├── README.md                             # 本文件
├── LICENSE                               # MIT
├── scripts/
│   ├── ps-guard.ps1                      # 一条命令闭环：预检→自愈→复检→试跑（首选入口）
│   ├── ps-lint.ps1                       # 语法预检 + AST 符号比较检出（只解析不执行）
│   ├── fix-ps-punct.ps1                  # 全角标点/不可见字符自愈（tokenizer 保护区）
│   ├── install.ps1                       # 装进 .dsh/skills（幂等，需 -Force 才覆盖）
│   ├── validate-skill.ps1                # 发布前自检：Frontmatter + 正文结构是否合规
│   ├── pre-commit.ps1                    # 提交前门禁：暂存脚本必须过 ps-lint
│   ├── install-hooks.ps1                 # 把上面的门禁装进当前 git 仓库（可 -Uninstall）
│   ├── test-ps-tools.ps1                 # 49 例 lint/fix 边界回归
│   └── test-guard.ps1                    # 9 例 ps-guard 行为回归
├── references/
│   ├── known-blindspots.md               # 盲区、踩坑、编码规则、退出码、回归覆盖、版本沿革
│   └── error-feedback-prompt.md          # 报错回灌模板 + 报错对照表 + 提示词硬规则
├── .github/workflows/ci.yml              # CI：规范自检 + 58 例回归 + 产包上传
├── .gitattributes                        # `* -text`：禁止换行归一化（保字节级编码依据）
└── .gitignore                            # dist/、*.bak、测试临时区
```

## 安装

```powershell
# 一键（包内 install.ps1，复制到 %USERPROFILE%\.dsh\skills 并自检）
pwsh scripts\install.ps1                     # 已存在则需 -Force
pwsh scripts\install.ps1 -Destination D:\some\skills -Force
```

- **客户端**：解压到 `.dsh/skills/`（技能市场安装会自动挂载，支持热重载，无需重启客户端）。
- **手动放置**：把 `powershell-script-fixer` 整个目录复制到 `%USERPROFILE%\.dsh\skills\`。
- **直接用脚本**（不装技能也行）：`scripts/` 下各 `.ps1` 可独立运行，工具默认按 `$PSScriptRoot` 找同目录同伴。

## 快速上手

```powershell
$S = "$env:USERPROFILE\.dsh\skills\powershell-script-fixer\scripts"

pwsh $S\ps-guard.ps1 script.ps1 -Verify     # 首选：一条命令拿到 0/1/2/3 与 ACTION
pwsh $S\ps-guard.ps1 script.ps1 -NoFix      # 只诊断，不改文件

pwsh $S\ps-lint.ps1 script.ps1              # 0 无语法错 / 1 有语法错 / 2 读不到 / 3 符号比较
pwsh $S\ps-lint.ps1 script.ps1 -AsJson      # CI 消费（含 Warnings 字段）
pwsh $S\fix-ps-punct.ps1 script.ps1         # 仅在文件已报语法错时动手
pwsh $S\fix-ps-punct.ps1 script.ps1 -All    # 语法合法也修（＄x = 1、＂found＂、$a = 1，2）
pwsh $S\test-ps-tools.ps1                   # 49 例回归，约 50s，exit 0 = 通过
pwsh $S\test-guard.ps1                      # 9 例 guard 回归，约 15s
```

## 推荐闭环

```
生成
 → ps-lint
      exit 2 → 先修路径/权限（不是脚本的错）
      exit 1 → fix-ps-punct
                 0 FIXED   → ps-lint 复检 → Stop 试跑 → 执行
                 1 PARTIAL → error-feedback-prompt.md 回灌重出（连原文一起给）
                 3 WARN    → 逐条看 SUSPECT/UNRECORDED，确认后 -All 或人工
      exit 3 → 把 `>` 改成 -gt/-ge/-lt/-le，重跑（别动业务逻辑）
      exit 0 → 仍要跑一次 fix-ps-punct 做可疑字符体检，再 Stop 试跑
```

Stop 试跑：`pwsh -NoProfile -Command "$ErrorActionPreference='Stop'; & 'script.ps1'"`
（不加 `Stop` 时非终止错误不会改变退出码，试跑等于没做。）

## 退出码

| 码 | ps-lint.ps1 | fix-ps-punct.ps1 |
| --- | --- | --- |
| 0 | 无语法错误 | 已修好，或确认无可疑字符 |
| 1 | 存在语法错误 | PARTIAL：替换后仍有错，未写回 |
| 2 | 读不到文件（路径不存在 / 传入目录 / 无权限） | 同左，或写回失败 |
| 3 | WARN：无语法错误但检出符号比较 | WARN：语法合法但检出可疑全角/不可见字符 |

多文件取最严重，**优先序 2 > 1 > 3 > 0**（不是数值大小）。`0` 只代表没有 ParseError，不代表能运行。

## 安全设计

- 保护区由 PowerShell 真 tokenizer 的 token `Kind` 判定：字符串、注释、here-string 内的全角标点一律不动。
- 修复后复检不通过就不写回，不产生半损坏文件。
- 写回沿用原文件编码（UTF-8±BOM / UTF-16LE / UTF-16BE）；GBK 输入不改写。
- 0 处替换不写回、不建备份；`.bak` 已存在则改存带时间戳副本，绝不覆盖。

## 已知边界

`ps-lint` 返回 0 ≠ 能跑：`if ($a == $b)`、`// 注释`、`Get-ChildItem($p)`、JS 模板串，以及紧邻中文文案的全角标点都不在射程内，需靠 Stop 试跑与人工审读兜住。完整清单见 `references/known-blindspots.md`。

## 发布形态：纯 Skill（插件壳可选）

市场按**所选目录**判定形态，看的是那个目录里有什么文件：

| 目录 | 含什么 | 会被判成 |
| --- | --- | --- |
| 仓库根（默认） | `SKILL.md` + `scripts/` + `references/`，**没有** `package.json` | **Skill** ✔ 推荐 |
| `plugin-shell/` | `package.json` + `lib/index.js` + `patches/bundle.yaml` | 插件（仅在插件通道需要时用它当子目录） |

所以根目录刻意不放 `package.json` —— 一旦放上去，市场就把条目建成插件，并在 Skill 通道报
`所选目录需要包含真实插件 package.json`。要发 Skill 就**别在根目录放包清单**。

```
SKILL.md                     # 技能入口（市场解析 Frontmatter）
scripts/                     # 工具链
references/                  # 盲区与回灌模板
plugin-shell/                # 可选：薄插件壳，不参与 Skill 发布
```

可选插件壳里 `package.json` 的 `version` 必须与根 `SKILL.md` 一致（`validate-skill.ps1` 与 CI 都会校验，不一致直接判不合规）。

## 兼容性

- **PowerShell 7+**（脚本内运行时门禁）。用 5.1 调用会打印 `需要 PowerShell 7+` 并 **exit 2** —— 这是环境问题，不是脚本语法错误，别按 1 处理。
- 脚本文件必须保留 **UTF-8 BOM**：5.1 对无 BOM 的 UTF-8 会按 ANSI 解码中文注释 → 解析阶段就炸。批量改写脚本时别把 BOM 弄丢。
- 只信 `pwsh -File` 的退出码；不要 dot-source 这些脚本（内部用 `exit`，会把调用者会话一起关掉）。
- 每个脚本都有 `.SYNOPSIS/.DESCRIPTION/.EXAMPLE`，`Get-Help .\scripts\ps-guard.ps1 -Full` 可读。

## 规范合规

- `SKILL.md` 顶部为标准 YAML Frontmatter：`name`（kebab-case）、`version`（SemVer）、`category: ops`（8 大类枚举之一）、`description`、`whenToUse`、`tags`、`disableModelInvocation: false`、`userInvocable: true`。
- 正文含「适用场景 / 执行工作流与检查清单 / 输出格式规范与边界条件」三段。
- 压缩包根目录即 `SKILL.md`，无多层嵌套。

## Git 工作流（推荐）

```powershell
cd powershell-script-fixer
git init -b main
git add -A
git commit -m "feat: powershell-script-fixer v1.0.0"

# 1) 提交前门禁（拦住带语法错/符号比较的脚本）
pwsh scripts\install-hooks.ps1          # 装；-Uninstall 卸

# 2) 发布前自检（避免市场解析拦截）
pwsh scripts\validate-skill.ps1          # 14 项检查，exit 0 才上传

# 3) 版本与发布
git tag v1.0.0
git push origin main --tags
pwsh -NoProfile -c "Compress-Archive -Path ./SKILL.md,./README.md,./LICENSE,./scripts,./references -DestinationPath ./dist/powershell-script-fixer-v1.0.0.zip -Force"  # 不要用 ./*：会把 .git 与正在写入的 dist 一起打包
gh release create v1.0.0 ./dist/powershell-script-fixer-v1.0.0.zip
```

- **市场发布**：技能市场支持从 GitHub 仓库直接导入（公开仓库），版本走 tag，比每次手传 zip 可回溯；`dist/*.zip` 只作为 Release 附件。
- **CI**：`.github/workflows/ci.yml` 跑规范自检 + 58 例回归 + 产包上传；Linux job 暂为 `continue-on-error`（跨平台未实测）。
- **`.gitattributes` 的 `* -text` 是必需的**：本包回归以「字节级编码保持」为依据，git 的 autocrlf 转换会产生 `LF will be replaced by CRLF` 噪音并让仓库内容偏离实测字节序列。
- **回灌后验证"没动业务逻辑"**：`git diff -- <file>`（只应出现标点/空格级差异），这是 `references/error-feedback-prompt.md` 循环策略第 6 步的执行方式。

## 许可

MIT，见 `LICENSE`。
