#!/usr/bin/env node
/**
 * patch-sidecar.mjs —— 把上游 dsh-bili-whale（MIT）改造成「冥零工作台内置 sidecar」。
 *
 * 为什么需要补丁（而不是只设环境变量）：
 *   上游把封面/字幕/原片/九宫格写到 $DSH_HOME/shots 下。工作台的路径契约要求
 *   全部落在 <工作区>\out\<bv>\、<工作区>\tmp、<工作区>\logs。目录逻辑写在
 *   tools/lib/paths.mjs 与 commands/{debrief,bili-watch}.mjs 里，只能改代码。
 *
 * 补丁内容（幂等，可重复跑）：
 *   P1 paths.mjs：新增 biliRoot()/outRoot()/mediaDir()/tmpRoot()/logsRoot()，
 *      优先级 config.paths.* → BILI_*_ROOT 环境变量 → 当前工作目录。
 *   P2 debrief.mjs：封面/字幕/正文缓存写 <out>\<bv>\，抽帧 outDir 显式传给 bili-watch。
 *   P3 bili-watch.mjs：中间帧写 <tmp>\.frames-<bv>-<stamp>（用完即删），不再写工作区外。
 *
 * 用法：
 *   node tools/patch-sidecar.mjs sidecar/bili-whale
 * 说明：安装包内的 sidecar 已打过补丁；升级上游时先覆盖文件再跑一遍本脚本。
 */
import fs from 'node:fs'
import path from 'node:path'

const root = process.argv[2] || path.join('sidecar', 'bili-whale')
const P = (...p) => path.join(root, ...p)

function patch(file, pairs) {
  const full = P(file)
  let s = fs.readFileSync(full, 'utf8')
  const done = s.includes('冥零工作台内置化补丁')
  let n = 0
  for (const [from, to] of pairs) {
    if (s.includes(to)) continue  // 这条已经打过了
    if (!s.includes(from)) {
      // 已打过补丁的文件：新增的补丁条目可能不适用，跳过；全新文件必须命中
      if (done) continue
      console.error(`✗ ${file}：找不到锚点 → ${from.slice(0, 60)}`); process.exit(1)
    }
    s = s.replace(from, to); n += 1
  }
  if (!n) { console.log(`= ${file} 已是最新`); return }
  fs.writeFileSync(full, s)
  console.log(`✓ ${file}（${n} 处）`)
}

const MARK = '冥零工作台内置化补丁'

patch('tools/lib/paths.mjs', [
  ["import os from 'node:os'", "import fs from 'node:fs'\nimport os from 'node:os'"],
  ["/** Credentials are per OS user, independent of DSH_HOME. */", `// ── ${MARK}（2026-11）────────────────────────────────────────
// 工作区根：BILI_ROOT → config.paths.biliRoot → 当前工作目录。
// 产物目录：<root>\\out\\<bv>、<root>\\tmp、<root>\\logs（工作台与 QQ 插件共用）。
function _cfgPaths() {
  try { return JSON.parse(fs.readFileSync(configPath, 'utf8')).paths || {} } catch { return {} }
}
export function biliRoot() { return process.env.BILI_ROOT || _cfgPaths().biliRoot || process.cwd() }
export function outRoot() { return process.env.BILI_OUT_ROOT || _cfgPaths().outRoot || path.join(biliRoot(), 'out') }
export function mediaDir(bv) { return path.join(outRoot(), String(bv || 'unknown')) }
export function tmpRoot() { return process.env.BILI_TMP_ROOT || _cfgPaths().tmpRoot || path.join(biliRoot(), 'tmp') }
export function logsRoot() { return process.env.BILI_LOGS_ROOT || _cfgPaths().logsRoot || path.join(biliRoot(), 'logs') }

/** Credentials are per OS user, independent of DSH_HOME. */`],
])

patch('tools/commands/debrief.mjs', [
  ["import { dshPath } from '../lib/paths.mjs'", "import { mediaDir } from '../lib/paths.mjs'"],
  ["const shots = dshPath('shots')\nfs.mkdirSync(path.join(shots, 'covers'), { recursive: true })\nfs.mkdirSync(path.join(shots, 'subs'), { recursive: true })",
    "// 冥零工作台内置化补丁：所有产物落 <工作区>\\out\\<bv>\\\nconst shots = mediaDir(bvid)\nfs.mkdirSync(shots, { recursive: true })"],
  ["path.join(shots, 'covers', `${bvid}.jpg`)", "path.join(shots, 'cover.jpg')"],
  ["path.join(shots, 'subs', `${bvid}-debrief.txt`)", "path.join(shots, `${bvid}-debrief.txt`)"],
  ["[watch, bvid, GRID, ...(opt.tile",
    "[watch, bvid, GRID, shots, ...(opt.tile"],
])

patch('tools/commands/bili-watch.mjs', [
  ["import { dshPath } from '../lib/paths.mjs'", "import { dshPath, tmpRoot } from '../lib/paths.mjs'"],
  ["const tmp = path.join(outDir, `.frames-${stamp}`)\nfs.mkdirSync(tmp, { recursive: true })",
    "// 冥零工作台内置化补丁：中间帧进 <工作区>\\tmp，抽完即删（不留在 out 里）\nfs.mkdirSync(tmpRoot(), { recursive: true })\nconst tmp = path.join(tmpRoot(), `.frames-${bvid}-${stamp}`)\nfs.mkdirSync(tmp, { recursive: true })"],
])

patch('tools/commands/feed.mjs', [
  ["const cred = JSON.parse(fs.readFileSync(path.join(HOME, '.bili-ai', 'credentials.json'), 'utf8'))",
   "// 冥零工作台内置化补丁：没登录时给中文提示，不要吐 Node 栈\nlet cred\ntry { cred = JSON.parse(fs.readFileSync(path.join(HOME, '.bili-ai', 'credentials.json'), 'utf8')) }\ncatch { console.error('还没有登录 B 站：缺 %USERPROFILE%\\\\.bili-ai\\\\credentials.json（sessdata / bili_jct / buvid3）。登录方法见 docs\\\\deploy-bili.md「凭据」一节。'); process.exit(1) }"],
])

patch('tools/commands/selftest.mjs', [
  ["const CFG = path.join(DSH, 'bili-whale.config.json')",
   "// 冥零工作台内置化补丁：配置优先 $BILI_WHALE_CONFIG（工作台把配置放在 %APPDATA%\\MinglingWorkbench）\nconst CFG = process.env.BILI_WHALE_CONFIG || path.join(DSH, 'bili-whale.config.json')"],
  ["} catch (e) {\n  line(WARN, '依赖体检（deps）', '没跑起来：' + String(e.message).slice(0, 60))\n}",
   "} catch (e) {\n  // 冥零工作台内置化补丁：deps 有红项时用退出码 3 结束，异常里带着输出，别当成\"没跑起来\"\n  const out = String(e.stdout || '')\n  const reds = (out.match(/✗/g) ?? []).length\n  line(reds === 0 ? WARN : NO, '依赖体检（deps）', reds === 0 ? '没跑起来：' + String(e.message).slice(0, 60) : `${reds} 项红 —— 在工作台「体检」页点「依赖」看详情`)\n}"],
  ["console.log('\\n────────── 接下来要做的两件事（很多人卡在这）──────────\\n')\nconsole.log('  ① 【找到她的会话】')\nconsole.log('     插件启动时会自动开一个会话，位置在：')\nconsole.log('       左侧「工作区」→ 展开「未分组」文件夹 → 里面那个 bili-whale')\nconsole.log('     ⚠️ 不点开「未分组」是看不见它的 —— 这一步最容易漏 ✗')\nconsole.log('')\nconsole.log('  ② 【给她完全权限】')\nconsole.log('     打开那个会话 → 权限设置 → 选「完全访问 / danger-full-access」')\nconsole.log('     否则她起来后跑不了命令、发不了评论、写不了日记 ✗')\nconsole.log('')",
   "// 冥零工作台内置化补丁：B 站能力已经内置，不再让用户去 DSH 里找会话/配权限\nconsole.log('\\n────────── 接下来 ──────────\\n')\nconsole.log('  B 站能力已经内置在工作台里，不用装 DSH、也不用开会话：')\nconsole.log('    · 工作台「B站」页 → 挑一条选题或粘 BV/链接 → 让她看')\nconsole.log('    · 群里发 BV/链接（插件装好后）→ 她调同一个内置组件，写同一份台账')\nconsole.log('    · 有红的项 → 「体检」页点对应按钮重跑；路径/凭据看 docs\\\\deploy-bili.md')\nconsole.log('')"],
])

patch('tools/commands/deps.mjs', [
  ["  if (!windows.length) {\n    items.push({ name: '生物钟', ok: false, detail: '配置里没有任何作息窗口 → 永远不醒 ✗', fix: '设置页「作息」加一个窗口（例如 20:00–24:00，醒 1 次）' })",
   "  if (!windows.length) {\n    // 冥零工作台内置化补丁：工作台按需手动看，不跑夜间调度，这一项不该判红\n    const wb = process.env.MINGLING_WORKBENCH === '1'\n    items.push({ name: '生物钟', ok: wb, detail: wb ? '工作台按需开看，不跑夜间调度 —— 跳过 ✓' : '配置里没有任何作息窗口 → 永远不醒 ✗', fix: wb ? '' : '设置页「作息」加一个窗口（例如 20:00–24:00，醒 1 次）' })"],
])

patch('tools/commands/selftest.mjs', [
  ["line(c.self?.mid ? OK : NO, '她的身份'", "line(c.self?.mid ? OK : WARN, '她的身份'"],
  ["line(c.owner?.mid ? OK : NO, '主人的身份'", "line(c.owner?.mid ? OK : WARN, '主人的身份'"],
])

patch('tools/commands/deps.mjs', [
  ["  const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'))\n  const night = cfg.night ?? {}",
   "  // 冥零工作台内置化补丁：工作台没有夜间调度器，这一项与它无关，直接放行\n  if (process.env.MINGLING_WORKBENCH === '1') {\n    items.push({ name: '生物钟', ok: true, detail: '工作台按需开看，不跑夜间调度 —— 跳过 ✓', fix: '' })\n    throw { wbSkip: true }\n  }\n  const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'))\n  const night = cfg.night ?? {}"],
  ["} catch (e) {\n  items.push({ name: '生物钟', ok: false, detail: '检查失败：' + String(e?.message ?? e).slice(0, 80), fix: '看设置页「养鱼」里生物钟那行；或 node bili.mjs night plan' })\n}",
   "} catch (e) {\n  if (!e?.wbSkip) items.push({ name: '生物钟', ok: false, detail: '检查失败：' + String(e?.message ?? e).slice(0, 80), fix: '看设置页「养鱼」里生物钟那行；或 node bili.mjs night plan' })\n}"],
])

patch('tools/commands/selftest.mjs', [
  ["console.log('  想立刻看她跑一轮：设置页 →「生物钟」→ 把窗口改成现在之后 2 分钟 → 等她自己醒\\n')",
   "console.log('  想立刻看她跑一轮：工作台「B站」页粘一个 BV，或者群里发一条链接\\n')"],
  ["启动测试（装完插件跑这一条）", "启动测试（装好后跑这一条）"],
])

patch('tools/commands/selftest.mjs', [
  ["'设置页 →「她是谁」还没填'", "'可选：在 bili-whale.config.json 的 self.mid 填 B 站 mid'"],
  ["'设置页 →「她是谁」里填主人 mid'", "'可选：在 bili-whale.config.json 的 owner.mid 填你的 mid'"],
])

console.log('done.')
