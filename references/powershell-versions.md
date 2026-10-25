# PowerShell 版本兼容：7 优先，5.1 可降级

工具默认要求 **PowerShell 7+**。目标机只有 Windows PowerShell 5.1 时，用
`-AllowLegacy`（三个工具都支持）或环境变量 `PSFIX_ALLOW_LEGACY=1` 降级运行。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\ps-guard.ps1 目标.ps1 -AllowLegacy -Verify
# 或
$env:PSFIX_ALLOW_LEGACY = '1'
```

不加开关时，5.1 会打印原因并 **exit 2**（"环境不对"，不是"脚本有错"）。

## 实测结论（Windows PowerShell 5.1.26100 / pwsh 7.6.5）

| 能力 | 5.1 降级 | 7 |
| --- | --- | --- |
| `ps-lint` 干净 → exit 0 | ✔ | ✔ |
| `ps-lint` 全角语法错 → exit 1 | ✔ | ✔ |
| `ps-lint` `>` 当比较 → exit 3 | ✔ | ✔ |
| `fix-ps-punct` 自愈 + 保编码 | ✔ | ✔ |
| `ps-guard` 闭环 / `-Inline` | ✔ | ✔ |
| `ps-guard -Verify` 抓运行期错 | ✔ | ✔ |
| `-AsJson` | ✔（非 ASCII 可能被转成 `\uXXXX`，解析端无影响） | ✔ |

## 5.1 下踩到并已修的三个坑（改代码时别退回去）

1. **脚本自身必须带 UTF-8 BOM**。5.1 按 ANSI/GBK 解码无 BOM 的 UTF-8，中文注释变乱码 →
   解析阶段就报 `Unexpected token`，连版本门禁都跑不到。实测 5 个脚本被整文件重写后集体中招；
   CI 有专门断言拦这一条。
2. **`Start-Process -ArgumentList` 不给含空格的元素加引号**。原来传
   `@('-NoProfile','-Command','& { ... }')`，5.1 下 `-Command` 被截断，试跑永远"通过"。
   现在改为把试跑包装写成临时 `.ps1`，用 `-File "路径"` 调用。
3. **`Start-Process -PassThru` 的 `ExitCode` 在 5.1 常为空**。读它会得到 `$null`，
   于是"成功"被判成失败（实测 `ok.ps1` 报 `RUNTIME_FAIL`）。现在子进程把退出码写进哨兵文件，
   父进程只读哨兵；超时按 124，没写哨兵按 1。

## 5.1 的能力边界（别指望）

- 没有 `$IsWindows` / `$IsMacOS`：脚本已按版本兜底（`-lt 7` 视为 Windows）。
- `ConvertTo-Json` 会转义非 ASCII：`-AsJson` 的字符串形态与 7 不同，字段结构一致。
- 启动开销更大（冷启动 ~0.5–0.9s），批量场景建议仍用 7。
- 依赖 7 语法/特性的脚本不在此列（本工具刻意避开三元、`??`、`-AsArray`）。
- 回归套件（`test-*.ps1`）只在 7 上跑；5.1 由 CI 用三条断言覆盖（lint 1/3、guard 0/3）。

## CI 覆盖

| 平台 | 覆盖 |
| --- | --- |
| windows-latest | BOM 断言 + 全量 72 例（pwsh 7）+ **5.1 降级用例**（`shell: powershell`） |
| ubuntu-latest | 全量 72 例（pwsh 7） |

## 相关

- 主流程与退出码：`SKILL.md`
- 报错分类与 JSON 字段：`references/error-reporting.md`
- 盲区与实测记录：`references/known-blindspots.md`
