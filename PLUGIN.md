# 插件形态（可选）

同一套工具链的**插件**发行形态。与 Skill 形态的区别：

| | Skill（仓库根目录） | 插件（本目录） |
| --- | --- | --- |
| 触发 | 模型自主唤醒，按 SKILL.md 执行 | 客户端命令 `psfix:*`、菜单点击 |
| 何时选 | 希望模型自己判断并修脚本 | 希望显式调用、或不经模型直接跑 |
| 市场导入 | 目录留空（根） | 子目录填 `plugin` |

## 命令

| 命令 | 作用 | 等价 CLI |
| --- | --- | --- |
| `psfix:version` | 版本 | — |
| `psfix:lint <file>` | 语法预检（含 `>` 当比较检出） | `ps-lint.ps1 <file>` |
| `psfix:fix <file>` | 全角/不可见字符自愈 | `fix-ps-punct.ps1 <file>` |
| `psfix:guard <file>` | 闭环：预检→自愈→复检→试跑 | `ps-guard.ps1 <file> -Verify` |

退出码原样透传：`0 通过 / 1 回灌重写 / 2 调用错误 / 3 需改 -gt`。

## 运行时解析顺序

1. `PSFIX_PWSH` 环境变量指定的可执行文件
2. PATH 里的 `pwsh`（PowerShell 7）
3. Windows 上的 `powershell.exe`（5.1）—— 自动追加 `-AllowLegacy`，实测可用

找不到任何一个时 `runTool` 返回 `code: 2` 并给出原因，不会伪装成功。

## 打包

```powershell
pwsh plugin\build.ps1        # 产出 dist\plugin\powershell-script-fixer\ 与 zip
```

产物结构（符合指南的插件规范）：

```
powershell-script-fixer/
├── package.json          # name + 精确 SemVer + main + dsh.bundle.patch
├── patches/bundle.yaml   # 空列表 []
├── lib/index.js          # 纯 JS，无构建
├── scripts/              # 11 个 .ps1（随包分发，插件运行依赖它们）
├── references/           # 4 份文档
├── SKILL.md              # 同时保留技能说明
├── README.md
└── LICENSE
```
