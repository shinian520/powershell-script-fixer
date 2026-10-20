---
name: powershell-script-fixer
version: 1.0.0
category: ops
author: YG
description: PowerShell 脚本语法预检与全角标点/不可见字符自愈工具链，专治 AI 生成脚本的 ParseError、把 > 误当比较的静默丢输出与编码破坏；58 例回归（49+9），支持 -AsJson、一键闭环与发布自检。
whenToUse: 当需要检查、修复或验收 AI 生成的 .ps1/.psm1 脚本时调用；典型触发为「ps1 报错」「Unexpected token」「全角标点」「脚本跑不出结果但 exit 0」「脚本中文乱码」「先 lint 再执行」。
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

把「AI 生成的 PowerShell 脚本」从"看起来对"变成"能跑且没静默失败"的闭环工具链。
首选入口 `ps-guard.ps1`（一条命令走完 预检→自愈→复检→试跑），底层是 `ps-lint.ps1`（只解析不执行的语法预检 + AST 符号比较检出）
与 `fix-ps-punct.ps1`（tokenizer 保护区判定的全角标点/不可见字符自愈）；回归套件 `test-ps-tools.ps1`（49 例）与 `test-guard.ps1`（9 例）；
`install.ps1` 负责装进 `.dsh/skills`。

工具路径一律相对技能根目录解析：`<SKILL_DIR>\scripts\ps-lint.ps1`。
下文所有命令按 Windows + PowerShell 7（`pwsh`）书写；跨平台时把 `<SKILL_DIR>` 换成技能安装目录即可（脚本本身是纯 PS 7，无 Windows API 依赖）。

## 适用场景

- AI（DeepSeek/GPT/Claude）刚生成的 `.ps1` 脚本报 `Unexpected token '，'`、`'：'`、`'｛'`、`'＞'` 之类语法错误。
- 脚本 `ps-lint` 判 OK、进程也 `exit 0`，但输出丢了、目录里多出名为 `0` 的怪文件 —— 典型的 `>` 当比较用。
- 脚本里有零宽空格、全角空格、文件中段 BOM，肉眼看不出来、运行必炸。
- 中文脚本被改坏编码（UTF-8 去 BOM 后在 Windows PowerShell 5.1 下按 GBK 解码成乱码）。
- 需要在 CI / 批量流程里给一堆脚本做"可否执行"的门禁判断（退出码分层，可程序消费 `-AsJson`）。
- 修复后要证明"只改了标点、没动业务逻辑"（配合 diff 校验）。

## 执行工作流与检查清单

按顺序执行，不要跳步；每步以退出码为准，不以"看起来没问题"为准。

### 0. 一条命令版（默认首选）

```powershell
pwsh <SKILL_DIR>\scripts\ps-guard.ps1 目标.ps1 -Verify
```

它内部按顺序做：`ps-lint` → 有语法错就 `fix-ps-punct` 自愈 → 复检 → 用 Stop 模式另起进程试跑，
最后只回一个退出码和一句 ACTION：`0 通过 / 1 回灌重写 / 2 调用错误 / 3 需人工把 > 改成 -gt`。
`-NoFix` 关闭自愈（只诊断不改文件），`-TimeoutSec` 设试跑超时（默认 30s，防 Read-Host 卡死），`-AsJson` 给程序消费。
只有在需要**逐条看每一处替换分类**（`faithful/invisible/semanticGuess/suspect`）时，才降到下面 1–4 步手工走一遍。

### 1. 语法预检

```powershell
pwsh <SKILL_DIR>\scripts\ps-lint.ps1 目标.ps1
pwsh <SKILL_DIR>\scripts\ps-lint.ps1 a.ps1 b.ps1 -Quiet     # 只要退出码
pwsh <SKILL_DIR>\scripts\ps-lint.ps1 目标.ps1 -AsJson       # 给 CI / 程序消费
```

退出码分流：

| 码 | 含义 | 下一步 |
| --- | --- | --- |
| 0 | 无 ParseError | 走第 3 步「可疑字符体检」，别直接执行 |
| 1 | 存在语法错误 | 走第 2 步修复 |
| 2 | 读不到文件（路径错/传目录/无权限） | 先修调用与路径，不是脚本的错 |
| 3 | 无语法错误但检出符号比较（`>` 被当重定向） | 把 `>` 改成 `-gt/-ge/-lt/-le`，不改业务逻辑 |

### 2. 全角标点 / 不可见字符自愈

```powershell
pwsh <SKILL_DIR>\scripts\fix-ps-punct.ps1 目标.ps1           # 仅当文件当前有语法错时才动手
pwsh <SKILL_DIR>\scripts\fix-ps-punct.ps1 目标.ps1 -All      # 语法已合法也修（＄x = 1、＂found＂、$a = 1，2）
pwsh <SKILL_DIR>\scripts\fix-ps-punct.ps1 目标.ps1 -NoBackup
pwsh <SKILL_DIR>\scripts\fix-ps-punct.ps1 目标.ps1 -AsJson
```

- `0 FIXED` → 回到第 1 步复检 → 第 4 步试跑 → 执行。
- `1 PARTIAL` → 用 `references/error-feedback-prompt.md` 的模板回灌重出（**必须连脚本原文一起给**）。
- `3 WARN` → 逐条看 `SUSPECT` / `UNRECORDED` 的 `U+XXXX` 码位与行列，确认意图后再 `-All` 或人工改。
- `2 ERROR` → 读写失败 / 备份目标已存在，先解决文件系统问题。

**注意 `＞`/`＜` 的二次坑（实测闭环）**：`if ($n ＞ 0)` 被同形映射成 `if ($n > 0)` 后语法虽然合法，
但落进了"`>` 当重定向"的坑，复检时 `ps-lint` 会报 `3 WARN`（`[> 0] 请改用 -gt`）。
这不是修坏了，是必须再手工把 `>` 改成 `-gt` —— 全角比较符的修复要连带做运算符替换，才算真正闭环。

保护区由 PowerShell 真 tokenizer 的 token `Kind` 决定（`Comment` / `StringLiteral` / `StringExpandable` /
`HereStringLiteral` / `HereStringExpandable`），字符串、注释、here-string 里的全角标点是给人看的内容，工具不动它。
这是刻意设计：不要为了"看起来统一"去改文案。

### 3. 语法合法也要做的可疑字符体检

对 `ps-lint` 返回 0 的文件再跑一次 `fix-ps-punct`（不加 `-All`）。它会把"语法合法但并进裸词"的全角字符报成 `3 WARN`：
`＄x = 1`、`$a = 1，2`、`Write-Host ＂found＂` 这类写法 `ps-lint` 判 OK，但运行时必然炸。确认后用 `-All` 就地修。

### 4. 执行前 Stop 模式试跑

```powershell
pwsh -NoProfile -Command "$ErrorActionPreference='Stop'; & '目标.ps1'"
```

不加 `Stop` 时，`$a = 1，2`、`==`、`// 注释` 这类缺陷只报非终止错误，进程照样 `exit 0`，试跑等于没做。
把"合法但错"逼成非 0 退出码，是 lint 覆盖不到的最后一层。

### 5. 回归自检（改工具本身、或换了环境后必做）

```powershell
pwsh <SKILL_DIR>\scripts\test-ps-tools.ps1              # 49 例全跑，约 50s，exit 0 = 通过
pwsh <SKILL_DIR>\scripts\test-ps-tools.ps1 -Case fix    # 只跑名字含 fix 的用例
```

套件含两条自检：`-Case` 无匹配必须非 0、被测工具缺失必须非 0 —— 防"绿但一个测试都没跑"。

### 检查清单（交付前逐条打勾）

- [ ] `ps-lint` 退出码为 0 或 3（3 已按提示改完并复检为 0）
- [ ] `ps-lint` 返回 0 之后仍跑过 `fix-ps-punct` 体检，且不是未处理的 3
- [ ] 所有 `>` `<` 比较都已换成 `-gt/-ge/-lt/-le`；写文件用 `Out-File` / `Set-Content`
- [ ] Stop 模式试跑通过（非 0 即视为失败）
- [ ] 修复前后 `diff` 只有标点/空格级差异，业务逻辑零改动
- [ ] 原始编码保持（中文脚本不要去掉 UTF-8 BOM）
- [ ] 仓库形态下（可选）：`pwsh scripts\install-hooks.ps1` 装好 pre-commit 门禁，改动 SKILL.md 后跑 `pwsh scripts\validate-skill.ps1`

## 输出格式规范与边界条件

**输出格式**

- 报告类输出一律给：文件路径 + 状态码 + 行列（`L{行}C{列}`）+ 触发原因 + 建议命令，别只说"修好了"。
- 需要机器消费时统一用 `-AsJson`（`ps-lint` 含 `Warnings` 字段；`fix-ps-punct` 含 `faithful/invisible/semanticGuess/suspect/unrecorded` 分类计数）。
- 多文件时退出码取最严重，**优先级是 2 > 1 > 3 > 0，不是数值大小**（这是历史 bug，勿按数值比较复述）。

**能力边界（实测，务必如实告知用户）**

1. `ps-lint` 返回 0 只代表"没有 ParseError"，不代表能运行、更不代表逻辑正确。
2. ASCII 层面的"合法但错"不在射程内：`if ($a == $b)`、`// 注释`、`Get-ChildItem($p)` 少空格、JS 模板串 `` $s = `hello ${n}` ``，只能靠硬规则 + Stop 试跑兜住。
3. 弯引号 `“ ”` 是 PS 7 的合法定界符，工具不报不改；全角 `＂`（U+FF02）不是定界符，会报 WARN。
4. 双引号字符串内部的 `$(...)` 子表达式整段按字符串保护（保守，宁可不改）。
5. `＃ ～ ￥` 只报不改（`＃`→`#` 会把行尾变成注释、静默删码）。
6. 紧邻中文文本的全角标点按字面量保留，只报 SUSPECT，防止改坏中文文案。
7. 结构性错误仍要回灌或人工：`@{ k: v }` 冒号、未闭合字符串、here-string 结束符缩进、行尾全角逗号。
8. `PARTIAL` 的行列来自"假设已改好"的文本（磁盘上仍是原件），回灌时必须连同原文一起给。
9. **只在 PowerShell 7+ 上成立**：脚本内做了运行时版本门禁，用 Windows PowerShell 5.1 运行会打印
   `ERROR: 需要 PowerShell 7+，当前 5.1.x。这是调用环境问题（exit 2），不是脚本语法错误。` 并 **exit 2**。
   （公开发布起不再用 `#Requires -Version 7`：那条语句会让 5.1 以 exit 1 中止，与"有语法错误"撞码，
   CI 分不清"环境不对"和"脚本写错"。）前提是脚本文件必须带 UTF-8 BOM，否则 5.1 会按 ANSI 解码中文注释、
   在解析阶段就失败，连门禁都跑不到。
10. **调用形态影响退出码**：只信任 `pwsh -File <脚本>`；包成 `pwsh -Command "& <脚本>; 后续"` 时脚本内的 `exit` 可能被吞。
    **不要 dot-source**（`. script.ps1`）这些工具：它们用 `exit` 结束，dot-source 会把你的会话一起关掉。
11. **Windows 下载标记**：市场 ZIP 解出的 `.ps1` 带 `Zone.Identifier`，`RemoteSigned` 策略下会被拒绝执行；
    `scripts\install.ps1` 已自动 `Unblock-File`，手工部署需自己解标记。

完整盲区与踩坑记录见 `references/known-blindspots.md`；报错回灌模板与报错对照表见 `references/error-feedback-prompt.md`。

**不做的事**
- 不自动"顺手统一"把字符串/注释里的中文标点改成半角。
- 不在 `fix-ps-punct` 复检不通过的情况下写回文件（不产生半损坏文件）。
- 不覆盖同名 `.bak`：已存在则改存 `<file>.bak-yyyyMMdd-HHmmss-fff`。
- 不把 GBK(cp936) 输入改写成 UTF-8（会破坏原文件语义）。
