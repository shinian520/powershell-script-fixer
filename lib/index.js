// lib/index.js
// DeepSeek Harness 插件入口（纯 JavaScript，无需构建）。
//
// 这个插件把仓库里的 PowerShell 工具链暴露成客户端命令，模型/用户不必记脚本路径：
//   psfix:lint   <file.ps1>   语法预检（含 > 当比较的检出）
//   psfix:fix    <file.ps1>   全角标点/不可见字符自愈
//   psfix:guard  <file.ps1>   一条命令闭环（预检 → 自愈 → 复检 → 试跑）
//   psfix:version             版本
//
// 设计约束：
//   - 不重复实现逻辑，一律调 scripts/*.ps1，保证 CLI / Skill / 插件三处行为一致
//   - 退出码原样返回（0 通过 / 1 回灌 / 2 调用错误 / 3 需改 -gt），便于上层编排
//   - 目标机没有 pwsh 7 时自动退回 Windows PowerShell 5.1 并追加 -AllowLegacy
'use strict';

const path = require('path');
const fs = require('fs');
const { spawnSync } = require('child_process');

const VERSION = '1.1.1';

/** 找 scripts 目录：打包后与 lib 同级，仓库里在上一级 */
function resolveScriptsDir() {
  const candidates = [
    path.join(__dirname, '..', 'scripts'),
    path.join(__dirname, '..', '..', 'scripts'),
  ];
  for (const dir of candidates) {
    if (fs.existsSync(path.join(dir, 'ps-guard.ps1'))) return dir;
  }
  throw new Error('找不到 scripts 目录（ps-guard.ps1）');
}

/** 选 PowerShell：PSFIX_PWSH 覆盖 > PATH 里的 pwsh > Windows PowerShell 5.1 */
function resolvePowerShell() {
  if (process.env.PSFIX_PWSH && fs.existsSync(process.env.PSFIX_PWSH)) {
    return { exe: process.env.PSFIX_PWSH, legacy: false };
  }
  const probe = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], {
    encoding: 'utf8',
    windowsHide: true,
  });
  if (!probe.error && probe.status === 0) {
    return { exe: 'pwsh', legacy: false };
  }
  if (process.platform === 'win32' && process.env.SystemRoot) {
    const legacyExe = path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    if (fs.existsSync(legacyExe)) return { exe: legacyExe, legacy: true };
  }
  throw new Error('找不到 PowerShell：请安装 PowerShell 7，或设置 PSFIX_PWSH 指向可执行文件');
}

/**
 * 调用一个工具脚本。
 * @param {string} toolName 例如 'ps-lint.ps1'
 * @param {string[]} args 传给脚本的参数
 * @returns {{code:number, stdout:string, stderr:string, shell:string}}
 */
function runTool(toolName, args = []) {
  const scriptsDir = resolveScriptsDir();
  const toolPath = path.join(scriptsDir, toolName);
  if (!fs.existsSync(toolPath)) {
    return { code: 2, stdout: '', stderr: `找不到工具脚本 ${toolName}`, shell: '' };
  }
  const ps = resolvePowerShell();
  const quote = (s) => `'${String(s).replace(/'/g, "''")}'`;
  // 开关不能加引号：加引号后 '-Verify' 会变成字符串实参，被 -Path（ValueFromRemainingArguments）吞掉，
  // 工具收到一个叫 "-Verify" 的路径（实测报 Cannot find path '-Verify'）。
  const argList = args
    .map((a) => (/^-[A-Za-z][\w-]*$/.test(String(a)) ? String(a) : quote(a)))
    .concat(ps.legacy ? ['-AllowLegacy'] : [])
    .join(' ');

  // 关键：先设 [Console]::OutputEncoding 再调用。Windows 上 PowerShell 向管道/重定向写 stdout 时
  // 用的是控制台代码页（本机 cp936），Node 按 UTF-8 解码会得到乱码（实测 "全角" 变 "ȫ��"）。
  // 用 -Command 传整段文本（spawnSync 不经过 shell，不涉及外层引号转义）。
  const cmd = [
    '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
    `& ${quote(toolPath)}${argList ? ' ' + argList : ''}`,
    'exit $LASTEXITCODE',
  ].join('; ');

  const r = spawnSync(ps.exe, ['-NoProfile', '-Command', cmd], {
    encoding: 'utf8',
    windowsHide: true,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (r.error) {
    return { code: 2, stdout: '', stderr: String(r.error.message || r.error), shell: ps.exe };
  }
  return {
    code: typeof r.status === 'number' ? r.status : 2,
    stdout: r.stdout || '',
    stderr: r.stderr || '',
    shell: ps.exe,
  };
}

/** 把工具输出整理成一行结论，便于命令面板展示 */
function summarize(toolName, r) {
  const text = (r.stdout || '').trim();
  const first = text.split(/\r?\n/).find((line) => line.trim().length > 0) || '';
  const verdict = { 0: 'OK', 1: 'FAIL', 2: 'ERROR', 3: 'WARN' }[r.code] || `EXIT ${r.code}`;
  return `[${verdict}] ${toolName} exit=${r.code}${first ? `\n${first}` : ''}${r.stderr ? `\n${r.stderr.trim()}` : ''}`;
}

function apply(ctx) {
  const log = ctx && ctx.logger;
  if (log && typeof log.info === 'function') {
    log.info(`powershell-script-fixer ${VERSION} loaded (scripts: ${resolveScriptsDir()})`);
  }
  const cmd = ctx && ctx.command;
  if (typeof cmd !== 'function') return;

  const need = (name, fn) => {
    try {
      cmd(name, fn);
    } catch (e) {
      if (log && typeof log.warn === 'function') log.warn(`注册 ${name} 失败: ${e && e.message}`);
    }
  };

  need('psfix:version', () => `powershell-script-fixer ${VERSION}`);
  need('psfix:lint', (file) => summarize('ps-lint.ps1', runTool('ps-lint.ps1', [file])));
  need('psfix:fix', (file) => summarize('fix-ps-punct.ps1', runTool('fix-ps-punct.ps1', [file])));
  need('psfix:guard', (file) => summarize('ps-guard.ps1', runTool('ps-guard.ps1', [file, '-Verify'])));
}

module.exports = {
  name: 'powershell-script-fixer',
  version: VERSION,
  apply,
  // 以下导出供测试与外部编排使用
  runTool,
  resolveScriptsDir,
  resolvePowerShell,
};
