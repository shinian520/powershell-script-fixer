# 已知盲区、踩坑记录与回归覆盖

> 全部结论为实测（PowerShell 7.6.5 / 2026-09-29 复验），不是推测。修改工具前先读本节，避免把已修过的坑重新引入。

## 一、已知盲区与能力边界

1. **"语法合法但并入裸词"的可疑全角**：`ps-lint` 判 OK，但 `fix-ps-punct` 会报 WARN（exit 3）并给出码位+行列，
   `-All` 可就地修好。实测：`＄x = 1` → `$x = 1`；`$a = 1，2` → `$a = 1,2`；`Write-Host ＂found＂` → `Write-Host "found"`。
   不加 `-All` 时文件不改 —— 因为"把裸词里的全角字符改掉"属于语义决策，工具不替用户做。
2. **ASCII 层面的"合法但错"不在射程内**，`ps-lint`/`fix` 都不报：`if ($a == $b)`（运行期报
   `The term '=' is not recognized`，进程仍 exit 0）、`// 注释`、`Get-ChildItem($p)` 少空格、
   JS 模板串 `` $s = `hello ${n}` ``。只能靠提示词硬规则 + 执行前 Stop 模式试跑兜住。
3. **弯引号 `“ ”` 是合法定界符**：PS 7 tokenizer 把 `Write-Host “你好”` 解析成 `Kind=StringExpandable`
   并正确输出 `你好`，所以它在保护区内，不报也不改；而全角 `＂`(U+FF02) 不是定界符，会报 WARN。
4. **双引号字符串内部的 `$(...)` 子表达式整段按字符串保护**：里面的全角字符既不修也不报（保守）。
   旧版手写状态机在这里会与真 tokenizer 失步，改坏字符串数据或报出文件里不存在的 token。
5. **只报不改类**：`＃`（转成 `#` 会把行尾变成注释、静默删掉代码）、`～`、`￥` 只列 SUSPECT，不改。
6. **紧邻非 ASCII 文本的全角标点按字面量保留**：`Write-Host 说明，详见` 里的 `，` 不改只报 SUSPECT，
   防止把给人看的中文文案改坏；同一文件里的真语法错误照常修复。
7. **结构性错误仍要回灌或人工**：哈希表 `@{ k: v }` 冒号、未闭合字符串（工具会明确说明"其后内容无法判定为
   代码区"）、行尾全角逗号 `$x = 1，`（`-All` 转成 `,` 后变成 `Missing expression after ','`）。
8. **PARTIAL 的行列来自"假设已改好"的文本**（磁盘上仍是原件），现每行附带 `| 原文行: …` 便于比对；
   回灌给模型时必须连同原文一起给，否则它会去改不存在的代码。
9. **中文句号/顿号属"语义猜测类"**（`。`→`;`、`、`→`,`），只在 `-All` 下执行并在结果里单独计数，便于复核。
10. **符号比较是"合法却静默丢输出"的坑，现已工具化检出**：`if ($x > 0)`、`$a > $b` 这类写法，
    PowerShell 把 `>` 当重定向运算符 —— 分支体输出被静默丢弃，并在磁盘上生成名为 `0` 的怪文件
    （实测 `if (5 > 0){ Write-Host "x" }` 执行后目录出现内容为 `5` 的文件 `0`），而进程 exit 0。
    **`ps-lint` 用 AST 检出它并报 exit 3**，判据是 `FileRedirectionAst` 的父节点不是 `CommandAst`：
    合法的 `Write-Host "x" > f.txt` 不误报（实测零误报）。脚本一律用 `-gt -ge -lt -le` 做比较；
    真要重定向请用 `Out-File` / `Set-Content`。注意 `<` 会产生 ParseError（exit 1 已能拦），`>` 才是静默的那类。
11. **全角比较符修复后必然落到第 10 条上（实测闭环）**：`if ($n ＞ 0)` 经同形映射成 `if ($n > 0)`
    语法合法，但复检 `ps-lint` 报 `3 WARN`（`[> 0] 请改用 -gt`）。所以全角 `＞ ＜` 的修复必须连带把
    运算符换成 `-gt/-ge/-lt/-le`，两道都过才算修好；只跑 `fix-ps-punct` 就宣布完成是错的。
12. **子进程起不来 → 假通过（v1.2.1 已修，务必别改回去）**：`ps-guard` 原先用 `& pwsh` 调子工具，
    在 PATH 不含 pwsh 的受限账户/精简容器里会抛 `CommandNotFoundException`、**而 `$LASTEXITCODE` 残留旧值 0**，
    于是被判成"语法干净、通过"。实测（清空 PATH 后）修复前输出 `OK: 语法干净`、退出码 0。
    现在改为从 `[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName` 取当前引擎自身路径，
    并对 `$LASTEXITCODE` 为 `$null` 的情况单独判为调用错误（exit 2）。同类坑：任何"用退出码做门禁"的脚本都必须区分
    「子进程返回 1」与「子进程根本没跑」。
13. **调用形态影响退出码**：只信任 `pwsh -File <脚本>` 的退出码。把它包成 `pwsh -Command "& <脚本>; 后续语句"` 时，
    脚本内的 `exit N` 可能只结束脚本作用域而不终止宿主，真实码会被吞（实测 `-Command "& s; 'still-alive'"` 仍打印 still-alive）。
    CI / 训练框架一律用 `-File`。
14. **Windows 下载标记与执行策略**：市场 ZIP 解出来的 `.ps1` 带 `Zone.Identifier`，LocalMachine 策略为 `RemoteSigned`
    时会被判"未签名远程脚本"而拒绝执行，表现是"技能装好了却跑不动"。`install.ps1` 已自动 `Unblock-File` 并对
    `Restricted/AllSigned` 告警；手工部署时需自己 `Get-ChildItem -Recurse | Unblock-File`，或用
    `pwsh -ExecutionPolicy Bypass -File ...` 临时放行。

## 二、写测试夹具时必看的踩坑

- **数组字面量里 `'a' + $x + 'b'` 会被拆成多个元素** —— `@(1, 2+3)` 得到的是 `1|2|3` 而非 `1|5`，
  因为逗号优先级高于 `+`，`+` 被当一元正号。必须先算成变量再放进数组：`$c = 'a' + $x + 'b'; @('A', $c, 'B')`。
- **`@($i - 1, $i + 1)`** 会被解析成对数组做减法并抛 `op_Subtraction`，必须写成 `@(($i - 1), ($i + 1))`。
- **内置别名优先级高于同名 function**（如 `fc` = `Format-Custom`），辅助函数别取别名名。
- **语句级 `++` 会把值写进输出流**、污染 `-AsJson`，计数统一用 `+= 1`。
- 用 `Write-Host` 是为了 CLI 人类可读输出（配合 exit code 供管道/CI 消费），属刻意使用，已加
  `SuppressMessageAttribute('PSAvoidUsingWriteHost')`，不要"修复"成 `Write-Output` 而污染数据流。

## 三、编码与写回规则（破坏这里会静默毁中文脚本）

- 写回沿用原文件编码（按 BOM 判定：UTF-8±BOM / UTF-16LE / UTF-16BE，无 BOM 视为 UTF-8）。
  去 BOM 会让中文脚本在 Windows PowerShell 5.1 下按 GBK 解码成乱码，而 `ps-lint` 仍报 OK。
- GBK(cp936) 输入不得被改写（不猜、不转码）。
- 0 处替换时不写回、不建备份，避免把原件原地重写并留一份无意义 `.bak`。
- 备份已存在时改存 `<file>.bak-yyyyMMdd-HHmmss-fff`，绝不 `-Force` 覆盖。
- 修复后重新做语法校验，不通过则不写回。

## 四、退出码

| 码 | ps-lint.ps1 | fix-ps-punct.ps1 |
| --- | --- | --- |
| 0 | 无语法错误 | 已修好，或确认无可疑字符 |
| 1 | 存在语法错误 | PARTIAL：替换后仍有错，未写回 |
| 2 | 读不到文件（路径不存在 / 传入目录 / 无权限） | 同左，或写回失败 |
| 3 | WARN：无语法错误但检出符号比较（`>` 被当重定向） | WARN：语法合法但检出可疑全角/不可见字符，文件未改动 |

多文件取最严重。**注意优先序是 2 > 1 > 3 > 0，不是数值大小**（退出码 3 比 1 大，但优先级更低）——
两工具内部都用"优先级序数 + 末尾映射退出码"两张表实现，勿改回直接比退出码。
**0 只代表"没有 ParseError"，不代表能运行、更不代表逻辑正确。**

## 五、回归覆盖（49 例）

`pwsh scripts\test-ps-tools.ps1` → 49/49 通过（exit 0，约 50s）。覆盖：

空文件、纯注释、复杂脚本、UTF-16、2000 行性能、字符串/注释/here-string 保护、引号转义、哈希表冒号、零宽空格、
只读文件、嵌套子表达式、幂等性；退出码分层（lint 0/1/2/3 与 fix 0/1/2/3）、`-Quiet`/`-AsJson`/多文件、
单行文件含错、单行多错条目完整、UTF-16 与 UTF-8 BOM 的**字节级**保编码、GBK(cp936) 输入不得被改写、
`.bak` 不被覆盖、连续两次修复原件不丢、全角字符并入裸词的 WARN 检出、`-All` 修 `＄x`、中文句号的语义猜测计数、
`＃` 只报不改、中文文本跑保留；**符号比较的检出与误报防护**（`if ($n > 0)` 报 3、
`Write-Host "x" > f.txt` 与 `-gt` 均不误报、`-AsJson` 带 Warnings）；**多文件取最严重的优先级**
（WARN 不得压住语法错/PARTIAL，正反顺序都验）；以及套件自检两条（`-Case` 无匹配必须非 0、被测工具缺失必须非 0）。

## 六、版本沿革

- **2026-09-29（第三轮，符号比较工具化）**：`ps-lint` 新增 AST 级符号比较检出（新增退出码 3 = WARN，
  `-AsJson` 增 `Warnings` 字段）；修掉两工具共有的"多文件取最严重被实现成比退出码大小"的优先级 bug；
  套件 43 → 49 例。
- **2026-09-29（第二轮，tokenizer 化）**：`fix-ps-punct` 保护区改用 PS 真 tokenizer 的 `Kind` verbatim 区间，
  删掉手写五态字符状态机；新增 `-All` / `-AsJson` / 多文件 / WARN 检出 / SUSPECT-UNRECORDED 分类；
  映射表 21 → 109 项（同形 93 + 语义猜测 2 + 不可见 14），`＃ ～ ￥` 只报不改。
  `ps-lint` 新增 `-Quiet` / `-AsJson` / 多文件与 0/1/2 分层（旧版把"路径不存在""传入目录""内部崩溃"混成 1）。
  套件 23 → 43 例。
- **2026-09-29（第一轮，缺陷修复）**：`ps-lint` 单行文件崩溃（`Get-Content` 返回标量导致 `$lines[$n]` 是 Char，
  `.TrimEnd()` 抛异常并吞掉后续错误条目）；写回不再统一成 UTF-8 无 BOM；备份不再覆盖同名 `.bak`。
15. **必须带 UTF-8 BOM（v1.3.0 推翻旧结论）**：早期两脚本刻意不加 BOM（只为消掉 PSScriptAnalyzer 的
    `PSUseBOMForUnicodeEncodedFile` 建议），代价是 Windows PowerShell 5.1 把无 BOM 的 UTF-8 当 ANSI/GBK 解码，
    中文注释变乱码 → **解析阶段就报 `Unexpected token`**，退出码 1，与"真语法错"完全无法区分（实测 9/9 脚本中招）。
    现在全部脚本改为 UTF-8 **带** BOM：5.1 能正确解析，于是运行时版本门禁可以干净地 `exit 2`；
    PSScriptAnalyzer 那条建议顺带消失。
    **维护注意**：用文本编辑器/脚本批量改写这些 `.ps1` 时务必保留 BOM —— 实测某些工具（包括 AI 编辑器的
    整文件重写）会静默把 BOM 去掉，5.1 行为立刻退化回乱码。
16. **不要 dot-source 这些工具**：脚本内部用 `exit` 收尾，`. script.ps1` 会把调用者会话一起终止。
    一律 `& script.ps1` 或 `pwsh -File script.ps1`。
- 环境要求：PowerShell 7+（运行时门禁 `exit 2`，见上）。
