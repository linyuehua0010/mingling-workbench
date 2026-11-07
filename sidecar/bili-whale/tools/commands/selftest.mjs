// 启动测试（2026-10-20 加 —— 装完插件先跑这个，一步确认能不能用）
//
//   node bili.mjs selftest
//
// 为什么需要它：很多人装完插件卡在两件事上 ——
//   ① 插件新开的会话在「工作区 → 未分组」里，不点开那个文件夹看不见
//   ② 那个新会话默认没有完全权限，agent 起来后什么都干不了
// 这个命令把"该确认的事"列成一张表，缺哪项就直说缺哪项。
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from '../lib/capture.mjs'
import { fileURLToPath } from 'node:url'
import { dshPath } from '../lib/paths.mjs'
import { NODE_EXE } from '../lib/nodebin.mjs'   // 2026-10-21：别用 process.execPath（Electron 里它是主程序 ✗）


const HOME = (process.env.USERPROFILE || process.env.HOME || '/')
const DSH = dshPath()
// 冥零工作台内置化补丁：配置优先 $BILI_WHALE_CONFIG（工作台把配置放在 %APPDATA%\MinglingWorkbench）
const CFG = process.env.BILI_WHALE_CONFIG || path.join(DSH, 'bili-whale.config.json')
const CRED = path.join(HOME, '.bili-ai', 'credentials.json')
const OK = '✓'
const NO = '✗'
const WARN = '!'

let bad = 0
const line = (mark, label, detail) => {
  if (mark === NO) bad += 1
  console.log(`  ${mark} ${label}${detail ? '  —— ' + detail : ''}`)
}

console.log('\n══════════ 启动测试（装好后跑这一条）══════════\n')

// ① 配置文件
try {
  const c = JSON.parse(fs.readFileSync(CFG, 'utf8'))
  line(OK, '配置文件', CFG)
  line(c.self?.mid ? OK : WARN, '她的身份', c.self?.name ? `${c.self.name}（${c.self.mid}）` : '可选：在 bili-whale.config.json 的 self.mid 填 B 站 mid')
  line(c.owner?.mid ? OK : WARN, '主人的身份', c.owner?.name ? `${c.owner.name}（${c.owner.mid}）` : '可选：在 bili-whale.config.json 的 owner.mid 填你的 mid')
  line(c.share?.via ? OK : NO, '分享方式', c.share?.via === 'dm' ? '私信（不发公开评论）' : '评论区 @')
  line(c.notify?.type ? OK : NO, '消息推送', String(c.notify?.type ?? '未设置'))
} catch {
  line(NO, '配置文件', '没有 ' + CFG + ' —— 先去设置页保存一次')
}

// ② 凭据
try {
  const cred = JSON.parse(fs.readFileSync(CRED, 'utf8'))
  const has = !!cred.sessdata && !!cred.bili_jct
  line(has ? OK : NO, 'B站凭据', has ? '已保存（cookie）' : '缺 sessdata / bili_jct')
  line(cred.buvid3 ? OK : WARN, 'buvid3', cred.buvid3 ? '有' : '缺 —— 不影响评论/私信；个别接口可能被风控。想要就 F12 → Cookies 复制 buvid3 再写入')
  // 2026-10-21：bili_jct 是"能不能发东西"的关键 —— 只读全绿但一发就 code=-111，最常见就是它 ✗
  const jct = String(cred.bili_jct ?? '')
  if (!jct) line(NO, 'bili_jct（写操作）', '空着 —— 发私信/评论/收藏都会失败（code=-111）→ 设置页重新粘贴一次')
  else if (!/^[0-9a-fA-F]{32}$/.test(jct)) line(WARN, 'bili_jct（写操作）', '格式不像（长度 ' + jct.length + '，正常 32 位十六进制）—— 可能复制时截断了')
  else line(OK, 'bili_jct（写操作）', '格式正常（和 SESSDATA 是否同一账号，只能靠一次真实写入验证）')
} catch {
  line(NO, 'B站凭据', '没有 ' + CRED + ' —— 设置页粘贴 cookie 后保存')
}

// ③ 登录态
try {
  const BILI0 = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'bili.mjs')
  const out = execFileSync(NODE_EXE, [BILI0, 'session'], { encoding: 'utf8', timeout: 30000 })
  const who = out.match(/账号\s*:\s*(.+)/) ?? []
  const midM = out.match(/mid\s*:\s*(\d+)/) ?? []
  line(who[1] ? OK : NO, '登录态', who[1] ? `${who[1].trim()}（mid ${midM[1] ?? '?'}）` : String(out).trim().slice(0, 80))
} catch (e) {
  line(NO, '登录态', '查不到（cookie 可能过期）—— ' + String(e.message).slice(0, 60))
}

// ④ 数据目录
// 2026-10-23 修（issue #27）：'.dsh' 那条要看 DSH_HOME ✗ 不能写死 HOME/.dsh
for (const [label, p] of [['.bili-ai', path.join(HOME, '.bili-ai')], ['DSH_HOME', DSH]]) {
  line(fs.existsSync(p) ? OK : NO, '目录 ' + label, p)
}
const DIARY = path.join(DSH, 'whale-diary.md')
line(fs.existsSync(DIARY) ? OK : WARN, '日记', fs.existsSync(DIARY) ? '已存在' : '还没建（她第一次醒来会写）')

// ⑤ 依赖体检（直接调现成的 deps，别在这里重复实现 ✗）
try {
  const BILI2 = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'bili.mjs')
  const out = execFileSync(NODE_EXE, [BILI2, 'deps'], { encoding: 'utf8', timeout: 60000 })
  const reds = (String(out).match(/✗/g) ?? []).length
  line(reds === 0 ? OK : NO, '依赖体检（deps）', reds === 0 ? '全绿' : `${reds} 项红 —— 详见 \`node bili.mjs deps\``)
} catch (e) {
  // 冥零工作台内置化补丁：deps 有红项时用退出码 3 结束，异常里带着输出，别当成"没跑起来"
  const out = String(e.stdout || '')
  const reds = (out.match(/✗/g) ?? []).length
  line(reds === 0 ? WARN : NO, '依赖体检（deps）', reds === 0 ? '没跑起来：' + String(e.message).slice(0, 60) : `${reds} 项红 —— 在工作台「体检」页点「依赖」看详情`)
}

// ⑥ 告诉她/他 下一步该做什么（这一步是很多人卡住的地方）
// 冥零工作台内置化补丁：B 站能力已经内置，不再让用户去 DSH 里找会话/配权限
console.log('\n────────── 接下来 ──────────\n')
console.log('  B 站能力已经内置在工作台里，不用装 DSH、也不用开会话：')
console.log('    · 工作台「B站」页 → 挑一条选题或粘 BV/链接 → 让她看')
console.log('    · 群里发 BV/链接（插件装好后）→ 她调同一个内置组件，写同一份台账')
console.log('    · 有红的项 → 「体检」页点对应按钮重跑；路径/凭据看 docs\\deploy-bili.md')
console.log('')
// 2026-10-20：全绿时落个标记 —— 设置页和她的唤醒提示会用它在"还没测过"时提醒
if (bad === 0) {
  try {
    fs.mkdirSync(path.join(HOME, '.bili-ai'), { recursive: true })
    fs.writeFileSync(path.join(HOME, '.bili-ai', 'selftest-passed.json'), JSON.stringify({ at: new Date().toISOString() }, null, 2))
  } catch {}
  console.log('══════════ 全部通过 ✓ 可以用了 ══════════')
  console.log('  想立刻看她跑一轮：工作台「B站」页粘一个 BV，或者群里发一条链接\n')
} else {
  console.log(`══════════ ${bad} 项没通过 ✗ 按上面的提示补一下 ══════════\n`)
}
process.exit(bad === 0 ? 0 : 1)
