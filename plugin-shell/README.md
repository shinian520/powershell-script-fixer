# plugin-shell —— 可选插件壳（默认不参与 Skill 发布）

仓库根目录是**纯 Skill**：`SKILL.md` + `scripts/` + `references/`，直接按 Skill 导入/上传即可。

这个子目录只是给「不得不按插件发布」时准备的薄壳：

```
plugin-shell/
├── package.json        # name / version（与根 SKILL.md 必须一致）
├── lib/index.js        # 纯 JS 入口，apply 仅登记 psfix:version
└── patches/bundle.yaml # 空列表 []：不侵入客户端核心
```

用法（仅在插件通道需要时）：

- 市场「从仓库导入 → 插件」，插件子目录填 `plugin-shell`
- 本地：`cd plugin-shell && npm pack`（无依赖、无构建）

> 为什么默认不放在根目录：市场按「所选目录」判定形态。根目录一旦有 `package.json`，
> 就会被当插件校验并可能建条目为插件；纯 Skill 发布要求根目录只有 `SKILL.md` 这套结构。
> 版本号必须与根 `SKILL.md` 的 `version` 一致，`scripts/validate-skill.ps1` 会校验这一点。
