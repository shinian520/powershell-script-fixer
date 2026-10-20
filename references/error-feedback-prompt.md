# 错误回灌模板与报错对照表

AI 生成的脚本语法报错时，把 `ps-lint` 输出原样回喂，让它逐条对照自检重出，比凭空重写准确得多。

前提：**`ps-lint` 通过只代表"没有 ParseError"，不代表能运行，更不代表逻辑正确**。
全角污染里有相当一部分根本不产生 ParseError（见下方对照表末几行）。
最隐蔽的一条：**用 `>` 做比较**（`if ($x > 0)`）——`ps-lint` 判 OK、进程 `exit 0`，
但 PowerShell 会把 `>` 当重定向运算符：分支输出被静默丢弃，并在磁盘上生成名为 `0` 的怪文件
（实测 `if (5 > 0){ Write-Host "x" }` 之后目录出现内容为 `5` 的文件 `0`）。一律改用 `-gt`。

## 回灌模板（直接复制，替换占位部分）

```text
【任务】修复下面脚本的全部语法错误，逐条对照报错清单修改，不得遗漏、不得改变业务逻辑。

【报错清单】（ps-lint / fix-ps-punct 输出原样粘贴，例如：）
FAIL: 3 处语法错误 - xxx.ps1
  L3C10: Unexpected token '，' in expression or statement.
      > $names = @("a.log"，
  L7C18: Unexpected token '＞' in expression or statement.
      > if ($names.Count ＞ 0)｛

【脚本全文】
（必须贴磁盘上的原文：PARTIAL 的行列来自"假设已改好"的文本，只给报错会让模型去改不存在的代码）

【硬规则】
1. 只允许修改标点、空格、配对、换行等格式与语法问题；业务逻辑一行都不许动。
2. 全角改半角只适用于代码区：字符串、注释、here-string 里的全角标点是给人看的内容，保持原样
   （工具也是这么做的，保护区由 PowerShell 真 tokenizer 判定）。
3. 变量符 $ 必须是半角；哈希表用 @{ Key = Value } 等号，冒号只属于 JSON。
4. Cmdlet 参数用空格：Get-ChildItem -Path $p；禁止 Get-ChildItem($p)。
5. 比较一律用 -eq -ne -gt -ge -lt -le；禁止用 > < >= <= 做比较——PowerShell 会把 >
   当重定向运算符，导致 if 分支里的输出被静默丢弃、并在磁盘上生成名为 0 之类的怪文件，
   而 ps-lint 仍判 OK。禁止 == != 和 && ||；注释只用 # 或 <# #>，禁止 //。
6. 自查按"位置"而不是"总数"：逐行确认引号成对同类、花括号嵌套闭合。
   反例：Write-Host "{" 合法但花括号计数不等；}{ 计数相等却非法。
7. 修复完成后把完整脚本放在一个代码块里输出，并逐条说明修改位置（行号 + 原因）。
```

## 配套命令（改完验证，闭环）

```powershell
pwsh <SKILL_DIR>\scripts\ps-lint.ps1 文件.ps1                 # 0 无语法错 / 1 有语法错 / 2 读不到 / 3 符号比较
pwsh <SKILL_DIR>\scripts\ps-lint.ps1 文件.ps1 -AsJson         # 需要程序化处理时
pwsh <SKILL_DIR>\scripts\fix-ps-punct.ps1 文件.ps1            # 0 已修好或无可疑 / 1 PARTIAL / 2 读不到 / 3 WARN
pwsh <SKILL_DIR>\scripts\fix-ps-punct.ps1 文件.ps1 -All       # 语法已合法也要修
pwsh <SKILL_DIR>\scripts\fix-ps-punct.ps1 文件.ps1 -AsJson    # 结构化结果（含每处替换的分类计数）
pwsh -NoProfile -Command "$ErrorActionPreference='Stop'; & '文件.ps1'"   # 执行前试跑
```

不加 `Stop` 时，`$a = 1，2` 这类缺陷只在运行期报非终止错误，进程照样 `exit 0`，试跑白做。

## 循环策略

1. 生成 → `ps-lint`；
   - **exit 3** = 检出符号比较（`if ($x > 0)` 这类）：把 `>` 改成 `-gt` 后重跑；
   - **exit 2** 是先修调用/路径问题，不是脚本的错。
2. **exit 1** → 先跑 `fix-ps-punct`：
   - `0 FIXED` → `ps-lint` 复检 → Stop 模式试跑 → 执行；
   - `1 PARTIAL` → 用上面模板回灌重出（报错 + 原文一起给）；
   - `3 WARN` → 逐条看 `SUSPECT` / `UNRECORDED`，确认意图后再 `-All` 或人工改。
3. **exit 0 也别直接执行**：再跑一次 `fix-ps-punct` 做"可疑字符体检"，报 `3 WARN` 就说明有全角字符并进了裸词，然后 Stop 试跑。
4. 同一条报错连续回灌 2 轮仍未通过 → 停止回灌，把报错 + 脚本作为新任务让模型重写该文件。
5. 结构性错误（哈希表冒号、未闭合字符串、here-string 结束符缩进、C 风格调用、行尾全角逗号）回灌效果有限，优先重写或人工改。
6. **回灌后必须 diff 校验"没动业务逻辑"**：模型常在改标点时顺手改变量名、分支条件或输出文案。
   仓库里用 `git diff -- 文件`；不在仓库里用
   `Compare-Object (Get-Content 改前.ps1) (Get-Content 改后.ps1)`，只允许出现标点/空格级差异。
7. **执行前先扫"符号比较"**：凡用 `>` `<` `>=` `<=` 做数值/字符串比较的，一律改成 `-gt -lt -ge -le`。

## 常见报错与处理对照（按实测分类）

| 报错特征 | 处理 |
| --- | --- |
| 代码区 `Unexpected token '，'` `'：'` `'；'` `'（'` `'）'` `'｛'` `'｝'` `'＞'` `'＜'` `'＝'` | `fix-ps-punct` 直接自愈（同形类） |
| 变量名/关键字中间夹零宽空格（`$fla​g`）、全角空格、文中 BOM | `fix-ps-punct` 直接自愈（不可见类） |
| `ps-lint` 判 OK 但 `fix-ps-punct` 报 WARN（`＄x = 1`、`$a = 1，2`、`Write-Host ＂found＂`） | 加 `-All` 就地修，或按给出的 U+XXXX 码位与行列人工确认 |
| 紧邻中文的标点（`Write-Host 说明，详见`） | 工具按字面量保留只报 SUSPECT，**别要求模型"一律改半角"**，那会改坏文案 |
| `＃ ～ ￥` 出现在代码区 | 工具只报不改（`＃`→`#` 会把行尾变成注释、静默删码），需人工判断 |
| `Missing '=' operator after key in hash literal` | 结构性：强调硬规则第 3 条或重写该段 |
| `The string is missing the terminator` | 结构性：工具明确说明"其后内容无法判定为代码区"，不自动处理 |
| `White space is not allowed before the string terminator` | here-string 结束符必须顶格（PS 7 也不允许缩进），人工/回灌 |
| 运行期 `The term '==' / '//' / '1，2' / 'Get-ChildItem（$p）' is not recognized`，而 `ps-lint` 之前报 OK | 属"合法但错"，只有 Stop 试跑能翻成非 0；见循环策略第 3、6 步 |
| `if ($x > 0)` `$a > $b` 这类**符号比较**（`ps-lint` 判 OK、进程 exit 0） | **必须重写为 `-gt`/`-lt`/`-ge`/`-le`**。`>` 被当重定向：分支输出静默丢失，并在磁盘生成名为 `0` 的怪文件。lint 与 Stop 试跑均抓不到，只能靠硬规则第 5 条与人工审读（旧版工具；本技能包的 `ps-lint` 已能报 exit 3 拦下） |

## 可直接贴进系统提示的硬规则

```text
【PowerShell 输出硬规则】
1. 只用半角标点 , : ; ( ) { } [ ] " '；禁止全角 ，：；（）＂＂｛｝＞＜＄。
2. 哈希表 @{ Key = Value } 用等号；冒号只属于 JSON。
3. Cmdlet 参数用空格：Get-ChildItem -Path $p -Recurse；禁止 Get-ChildItem($p, $r)。
4. @() 数组换行时行尾禁止逗号；变量符 $ 必须是半角（禁止 ＄name）。
5. 比较用 -eq -ne -lt -gt；禁止 == != 与 && ||；注释只用 # 或 <# #>，禁止 //。
6. 自查按"位置"而不是"总数"：逐行确认引号成对同类、花括号嵌套闭合。
   反例：Write-Host "{" 合法但花括号计数不等；}{ 计数相等却非法。
7. 字符串、注释、here-string 里的全角标点是人要看的内容，不要"顺手改成半角"。
```
