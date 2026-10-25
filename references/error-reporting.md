# 报错分层：分类 / 码位 / 可自动修 / 上下文

`ps-lint` 不只贴 PowerShell 原文，而是把每条 `ParseError` 翻译成「能不能动手、怎么动手」。

## 人读输出示例

```text
FAIL: 2 处语法错误 - gen.ps1
  L1C19: Unexpected token '，' in expression or statement.
      分类: 全角/非 ASCII 标点  → fix-ps-punct 可自动修
      可疑字符: '，' (U+FF0C)
      建议: 把 '，'（U+FF0C）换成半角同形字符；fix-ps-punct 可自动修
      1 | $m = 1
      > $names = @("a.log"，
        ^
      3 |   "b.log"
  L3C7: Missing '=' operator after key in hash literal.
      分类: 哈希表语法
      建议: @{ Key = Value } 必须用等号；冒号只属于 JSON。注意：把全角 ： 改成 : 仍然是错的，要改成 =
  汇总: 全角/非 ASCII 标点 ×1、哈希表语法 ×1；其中 1 处可自动修（跑 fix-ps-punct）
```

同一行的级联报错（一个全角字符常级联 2~3 条）每条仍各占一行 `LxCx:`，但只展开一次详情，
其余标为「与上面同一行的级联报错，改掉后一并消失」。

## 分类枚举（8 类，固定取值）

| 分类 | 触发 | 可自动修 |
| --- | --- | --- |
| 全角/非 ASCII 标点 | `Unexpected token '，'` 等非 ASCII token | ✅ `fix-ps-punct` |
| 括号/引号未闭合 | `Missing closing '}'/')'` | ❌ 补哪由语义决定 |
| 哈希表语法 | `Missing '=' operator after key` | ❌ 要改成 `=`（改半角 `:` 仍错） |
| 逗号后缺表达式 | `Missing expression after ','` | ❌ 行尾逗号/空元素 |
| 字符串未闭合 | `string is missing the terminator` | ❌ 后续内容会被吞进字符串 |
| here-string 结束符 | 结束符前有空格 | ❌ 必须顶格 |
| 语法结构错 | 其余 `Unexpected token` | ❌ 缺运算符/分隔符，或用了 `==` `//` |
| 其他语法错 | 兜底 | ❌ 按原文回灌 |

**全角造成的假结构性错**：`if ($n ＞ 0)` 会被 PowerShell 报成 `Missing closing ')'`。出错行含
`U+3000-303F` / `U+FF01-FF60` 时，工具会追加提示「若位于代码区，先跑 `fix-ps-punct -All`」——
这时先修字符，再判断是否真有结构问题，别急着重写整块。

## JSON 字段

`ps-lint -AsJson` 每个目标一条记录：

```json
{
  "path": "...", "status": "FAIL", "count": 2,
  "errors": [{
    "line": 1, "column": 19, "id": "UnexpectedToken",
    "message": "Unexpected token '，' in expression or statement.",
    "category": "全角/非 ASCII 标点",
    "hint": "把 '，'（U+FF0C）换成半角同形字符；fix-ps-punct 可自动修",
    "autoFixable": true,
    "char": "，", "codePoint": "U+FF0C",
    "lineHasFullWidth": true,
    "context": ["      1 | $m = 1", "      > $names = @(\"a.log\"，", "        ^", "      3 |   \"b.log\""]
  }],
  "warnings": [],
  "summary": { "byCategory": { "全角/非 ASCII 标点": 1, "哈希表语法": 1 }, "autoFixable": 1 }
}
```

## agent 侧怎么用

```
summary.autoFixable > 0  → 先跑 fix-ps-punct，再复检（别直接回灌重写）
errors[].category 为结构性 → 用 references/error-feedback-prompt.md 回灌，报错 + 原文一起给
errors[].lineHasFullWidth → 优先怀疑全角字符，别当成结构错误
warnings[]（`>` 当比较）    → 改成 -gt/-ge/-lt/-le，属静默丢输出，必须人工改
```

## 相关

- 退出码与优先序：见 `SKILL.md` 的表格（2 > 1 > 3 > 0）
- 盲区与实测记录：`references/known-blindspots.md`
- 回灌模板：`references/error-feedback-prompt.md`
