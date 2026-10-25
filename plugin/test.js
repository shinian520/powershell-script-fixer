// plugin/test.js —— 插件形态的功能回归（Node 直接跑，不依赖客户端）
// 覆盖：元数据、命令注册、runTool 四类退出码、自愈写回、运行期失败检出。
// 用法: node plugin/test.js [--packaged <插件目录>]
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const assert = require('assert');

const packagedIdx = process.argv.indexOf('--packaged');
const packagedDir = packagedIdx > 0 && process.argv[packagedIdx + 1]
  ? path.resolve(process.argv[packagedIdx + 1])   // 相对 cwd 解析，避免被当成 plugin/ 下的相对路径
  : null;
const libPath = packagedDir
  ? path.join(packagedDir, 'lib', 'index.js')
  : path.join(__dirname, 'lib', 'index.js');

const plugin = require(libPath);

let pass = 0;
let fail = 0;
function check(name, fn) {
  try {
    fn();
    pass += 1;
    console.log(`PASS  ${name}`);
  } catch (e) {
    fail += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e && e.message}`);
  }
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'psfix-plugin-'));
const nl = '\n';
const write = (name, text, bom) => {
  const p = path.join(work, name);
  const body = bom === false ? text : '\ufeff' + text;
  fs.writeFileSync(p, body, 'utf8');
  return p;
};

const clean = write('clean.ps1', `$x = 1${nl}Write-Host $x${nl}`);
const bad = write('bad.ps1', `$names = @("a.log"\uFF0C${nl}  "b.log"${nl})${nl}`);
const cmp = write('cmp.ps1', `$n = 5${nl}if ($n > 0) { 1 }${nl}`);
const boom = write('boom.ps1', `throw "boom"${nl}`);

check('plugin-01 元数据 name/version', () => {
  assert.strictEqual(plugin.name, 'powershell-script-fixer');
  assert.match(plugin.version, /^\d+\.\d+\.\d+$/);
});

check('plugin-02 resolveScriptsDir 能找到 ps-guard.ps1', () => {
  const dir = plugin.resolveScriptsDir();
  assert.ok(fs.existsSync(path.join(dir, 'ps-guard.ps1')), dir);
});

check('plugin-03 apply 注册 4 个命令', () => {
  const seen = [];
  plugin.apply({ logger: { info() {}, warn() {} }, command: (n) => seen.push(n) });
  assert.deepStrictEqual(seen.sort(), ['psfix:fix', 'psfix:guard', 'psfix:lint', 'psfix:version']);
});

check('plugin-04 psfix:lint 干净文件 → exit 0', () => {
  const r = plugin.runTool('ps-lint.ps1', [clean]);
  assert.strictEqual(r.code, 0, r.stdout + r.stderr);
});

check('plugin-05 psfix:lint 全角 → exit 1 且输出含分类', () => {
  const r = plugin.runTool('ps-lint.ps1', [bad]);
  assert.strictEqual(r.code, 1, r.stdout + r.stderr);
  assert.ok(r.stdout.includes('全角'), r.stdout);
});

check('plugin-06 psfix:lint 符号比较 → exit 3', () => {
  const r = plugin.runTool('ps-lint.ps1', [cmp]);
  assert.strictEqual(r.code, 3, r.stdout + r.stderr);
});

check('plugin-07 psfix:fix 自愈写回', () => {
  const r = plugin.runTool('fix-ps-punct.ps1', [bad]);
  assert.strictEqual(r.code, 0, r.stdout + r.stderr);
  assert.ok(!fs.readFileSync(bad, 'utf8').includes('\uFF0C'), '全角逗号应已修掉');
});

check('plugin-08 psfix:guard -Verify 捕获运行期失败 → exit 1', () => {
  const r = plugin.runTool('ps-guard.ps1', [boom, '-Verify']);
  assert.strictEqual(r.code, 1, r.stdout + r.stderr);
  assert.ok(r.stdout.includes('RUNTIME_FAIL'), r.stdout);
});

check('plugin-09 找不到的工具返回 code 2（不伪装成功）', () => {
  const r = plugin.runTool('no-such-tool.ps1', [clean]);
  assert.strictEqual(r.code, 2);
});

console.log('--------------------------------');
console.log(`通过: ${pass}  失败: ${fail}`);
try { fs.rmSync(work, { recursive: true, force: true }); } catch (e) { /* ignore */ }
process.exit(fail > 0 ? 1 : 0);
