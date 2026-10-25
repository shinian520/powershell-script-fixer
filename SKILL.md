---
name: powershell-script-fixer
version: 1.1.1
category: ops
author: YG
description: PowerShell 脚本语法预检与全角标点/不可见字符自愈工具链，专治 AI 生成脚本的 ParseError、把 > 误当比较的静默丢输出与编码破坏；72 例回归，支持 -AsJson、-Inline 语句与一键闭环。
whenToUse: 当需要检查、修复或验收 AI 生成的 .ps1/.psm1 脚本或直接执行的 pwsh 语句时调用；典型触发为「ps1 报错」「Unexpected token」「全角标点」「脚本跑不出结果但 exit 0」「先 lint 再执行」。
tags:
  - powershell
  - pwsh
  - lint
  - syntax
  - encoding
  - auto-fix
  - script-toolchain
disableModelInvocation: false
userInvocable: true
---

# PowerShell 脚本质检修复专家

**范围**：只修 AI 生成/执行 PowerShell 的运行期问题——落盘的 `.ps1` 与直接执行的语句（`-Inline`）。
不判断业务逻辑对错（那需要规格），不做插件/模块等发布形态。

工具（路径相对技能根，需 PowerShell 7+）：`ps-guard`（首选，一条命令闭环）、`ps-lint`（语法预检 +
AST 检出 `>` 当重定向）、`fix-ps-punct`（tokenizer 保护区的全角/不可见字符自愈）、`install`（装入 `.dsh/skills`）。

## 适用场景

- AI 生成的 `.ps1` 报 `Unexpected token '，'` / `'：'` / `'｛'` 一类语法错误。
- 脚本 `exit 0` 但输出凭空消失、目录里多出名为 `0` 的怪文件（`>` 被当比较）。
- 零宽空格、全角空格、文件中段 BOM 等肉眼看不出、运行必炸的污染。
- AI 不落盘、直接跑语句（`pwsh -Command "..."`）。
- 批量 / CI 需要"这条脚本能否执行"的确定判据（退出码分层 + `-AsJson`）。

## 执行工作流与检查清单

### 0. 首选：一条命令

```powershell
pwsh <SKILL_DIR>\scripts\ps-guard.ps1 目标.ps1 -Verify              # 文件
pwsh <SKILL_DIR>\scripts\ps-guard.ps1 -Inline '<语句>' -Verify       # 语句片段
$stmt | pwsh <SKILL_DIR>\scripts\ps-guard.ps1 -Inline -             # 管道（按字节 UTF-8 解码）
```

内部顺序：`ps-lint` → 有语法错就 `fix-ps-punct` → 复检 → Stop 模式试跑。
只回一个退出码和一句 ACTION：**0 通过 / 1 回灌重写 / 2 调用错误 / 3 需改 -gt**。
`-NoFix` 只诊断不改文件；`-TimeoutSec` 试跑超时（默认 30s，防 `Read-Host` 卡死）；`-AsJson` 供程序消费
（语句模式返回单对象，含 `fixed` 修后语句）。

**只有 5.1 的目标机**：三个工具都支持 `-AllowLegacy`（或设 `PSFIX_ALLOW_LEGACY=1`）降级运行，实测 lint/fix/guard 全可用；
不加开关时 5.1 会 `exit 2` 并说明原因。5.1 的三个坑（BOM、参数引号、ExitCode 取不到）已修，详见
`references/powershell-versions.md`。

### 1. 分步执行（需要逐条细节时才降级到这里）

```powershell
pwsh <SKILL_DIR>\scripts\ps-lint.ps1 目标.ps1 [-Quiet] [-AsJson]
pwsh <SKILL_DIR>\scripts\fix-ps-punct.ps1 目标.ps1 [-All] [-NoBackup] [-AsJson]
```

| 码 | 含义 | 下一步 |
| --- | --- | --- |
| 0 | 无 ParseError | 仍要跑一次 `fix-ps-punct` 做可疑字符体检 |
| 1 | 存在语法错误 | 跑 `fix-ps-punct`；仍错则回灌重写 |
| 2 | 读不到文件（路径/目录/权限） | 先修调用，不是脚本的错 |
| 3 | 检出 `>` 当比较（重定向） | 改成 `-gt/-ge/-lt/-le`，别动业务逻辑 |

多目标取最严重，**优先序 2 > 1 > 3 > 0（不是数值大小）**。
每条错误的分类、码位、`autoFixable`、上下文与 JSON 字段见 `references/error-reporting.md`。

### 2. 修不动就回灌

`fix-ps-punct` 只做字符级映射（保护区由 PowerShell 真 tokenizer 判定，字符串/注释/here-string 一律不动），
结构性错误（少括号、哈希表冒号、未闭合字符串）一概只定位不修。
遇到 `1 PARTIAL` 或结构性错误 → 用 `references/error-feedback-prompt.md` 的模板，**报错 + 脚本原文一起**给模型重写。

### 3. 执行前 Stop 模式试跑

```powershell
pwsh -NoProfile -Command "$ErrorActionPreference='Stop'; & '目标.ps1'"
```

不加 `Stop` 时，`$a = 1，2`、`==`、`// 注释` 这类缺陷只报非终止错误、进程照样 `exit 0`，试跑等于没做。

### 4. 回归自检（改工具或换环境后）

```powershell
pwsh <SKILL_DIR>\scripts\test-ps-tools.ps1     # 49 例（lint/fix 边界）
pwsh <SKILL_DIR>\scripts\test-guard.ps1        # 9 例（一条命令闭环）
pwsh <SKILL_DIR>\scripts\test-inline.ps1       # 8 例（-Inline / stdin）
pwsh <SKILL_DIR>\scripts\test-hints.ps1        # 6 例（报错分类/码位/上下文）
```

### 检查清单（交付前逐条打勾）

- [ ] `ps-lint` 为 0 或 3（3 已按提示改完并复检为 0）
- [ ] 返回 0 之后也跑过 `fix-ps-punct` 体检
- [ ] 所有 `>` `<` 比较已换成 `-gt/-ge/-lt/-le`；写文件用 `Out-File` / `Set-Content`
- [ ] Stop 试跑通过；语句形态也过了 `ps-guard -Inline`
- [ ] 修复前后只有标点/空格级差异，业务逻辑零改动
- [ ] 原编码保持（中文脚本不要去掉 UTF-8 BOM）

## 输出格式规范与边界条件

**输出格式**：路径 + 状态 + 行列 + 原因 + 建议命令；机器消费一律 `-AsJson`。
`ps-lint` 每条错误带 `category / hint / autoFixable / codePoint / lineHasFullWidth / context`，
外加 `summary.byCategory` 与 `summary.autoFixable`——agent 只读 `autoFixable` 即可决定"自己修"还是"回灌重写"。
完整字段与分类枚举见 `references/error-reporting.md`。

**边界（返回 0 ≠ 能跑）**：`==`、`//` 注释、`Cmdlet($p)` C 风格调用、JS 模板串、紧邻中文文案的全角标点
都不在射程内；结构性错误只定位不修；`>` 比较属"语法合法但静默丢输出"，必须人工改；
逻辑对错需断言判定。完整盲区与实测记录见 `references/known-blindspots.md`。

**不做**：不"顺手"把字符串/注释里的中文标点改半角；复检不通过不写回；不覆盖同名 `.bak`；不改写 GBK 输入；
不自动补括号（补哪由语义决定，实测会把后续函数静默嵌套进未闭合块）。
