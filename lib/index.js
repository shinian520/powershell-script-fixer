// lib/index.js
// DeepSeek Harness 插件入口（纯 JavaScript，无需构建）。
//
// 这个文件是"插件壳"：市场从 GitHub 仓库导入时会按插件规范校验
// package.json / main / dsh.bundle.patch 三件套，缺一即被拒。
// 本包的实际能力不在运行时插件里，而在：
//   - SKILL.md           技能说明（模型自主唤醒后按其工作流执行）
//   - scripts/*.ps1      ps-lint / fix-ps-punct / ps-guard 等工具链
// 因此 apply 只做登记与自述，不注册拦截器、不改客户端行为。
'use strict';

const VERSION = '1.0.0';

module.exports = {
  name: 'powershell-script-fixer',
  version: VERSION,
  apply(ctx) {
    const log = ctx && ctx.logger;
    if (log && typeof log.info === 'function') {
      log.info(`powershell-script-fixer ${VERSION} loaded (skill: SKILL.md, tools: scripts/*.ps1)`);
    }
    // 轻量自述命令：不触碰文件系统，不执行外部进程
    if (ctx && typeof ctx.command === 'function') {
      ctx.command('psfix:version', () => `powershell-script-fixer ${VERSION}`);
    }
  }
};
