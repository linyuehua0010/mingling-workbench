// dsh-bili-whale 补丁：抽帧色彩范围 + 看视频产物落到工作区
//
// 为什么（P1/P2）：脚本用 ffmpeg 抽帧写 .jpg，有些源片（实测 BV19b4A6PECX，1280x540）
// 后半段帧是 limited-range YUV，ffmpeg 9 的 mjpeg 编码器直接拒绝：
//   [mjpeg] Non full-range YUV is non-standard ... ff_frame_thread_encoder_init failed
// 结果 9 张帧只抽得出前 3 张，SHEET/SUBS 全废。加 -pix_fmt yuvj420p（full range）
// 就正常。上游要是修了，这个脚本会自己跳过。
//
// 为什么（P3–P6，2026-11-04）：bili-whale 默认把封面/九宫格/字幕写到 ~/.dsh/shots（C 盘）。
// 本工作台的约定是「看 B 站产生的新数据全落在工作区根目录下」：
//   out\<bv>\   封面、九宫格、字幕条、原片
//   tmp\        抽帧中间帧、字幕缓存（看完可清）
// 因此 P3–P6 把默认路径改成 mediaDir(bvid) / tmpRoot()。凭据、quota、日记
// 这些「状态」不搬（只读凭据保持 C 盘）。
//
// 用法：node tools/patch-bili-whale.mjs [--dry]
// 每次升级 dsh-bili-whale 之后重跑一次。
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

const dry = process.argv.includes('--dry')
const roots = [
  process.env.BILI_WHALE_DIR || '',
  path.join(os.homedir(), '.dsh', 'profiles', 'desktop', 'node_modules', 'dsh-bili-whale'),
  path.join(os.homedir(), '.dsh', 'node_modules', 'dsh-bili-whale'),
].filter(Boolean)

// ── P3：paths.mjs 增加 F 盘根目录解析 ─────────────────────────────────────
// 优先级：bili-whale.config.json 的 paths.* → 环境变量 BILI_*_ROOT → 默认 process.cwd()
const P3 = `
// ── [P3] 2026-11-04：看视频产生的新数据统一落到工作区 ───────────────────
// 优先级：bili-whale.config.json → paths.root/outDir/tmpDir/logsDir
//        → 环境变量 BILI_ROOT / BILI_OUT_ROOT / BILI_TMP_ROOT / BILI_LOGS_ROOT
//        → 默认 process.cwd()
// 只搬「产生的新数据」：凭据（~/.bili-ai/credentials.json）、quota、diary 等状态
// 仍在原处，只读不搬。
import fs from 'node:fs'

const DEFAULT_BILI_ROOT = process.cwd()
const pathsConfig = () => {
  try { return JSON.parse(fs.readFileSync(configPath, 'utf8')).paths || {} } catch { return {} }
}
const pickDir = (configured, envName, fallback) => {
  if (typeof configured === 'string' && configured.trim()) return path.resolve(configured)
  const fromEnv = process.env[envName]
  if (fromEnv && fromEnv.trim()) return path.resolve(fromEnv)
  return path.resolve(fallback)
}
export const biliRoot = () => pickDir(pathsConfig().root, 'BILI_ROOT', DEFAULT_BILI_ROOT)
export const outRoot = () => pickDir(pathsConfig().outDir, 'BILI_OUT_ROOT', path.join(biliRoot(), 'out'))
export const mediaDir = (bvid) => path.join(outRoot(), String(bvid))
export const tmpRoot = () => pickDir(pathsConfig().tmpDir, 'BILI_TMP_ROOT', path.join(biliRoot(), 'tmp'))
export const logsRoot = () => pickDir(pathsConfig().logsDir, 'BILI_LOGS_ROOT', path.join(biliRoot(), 'logs'))
export function ensureDir(dir) { fs.mkdirSync(dir, { recursive: true }); return dir }
`

const patches = [
  {
    id: 'P1',
    name: '抽帧 -pix_fmt yuvj420p',
    file: 'tools/commands/bili-watch.mjs',
    marker: "'-pix_fmt', 'yuvj420p'",
    steps: [[
      "'-frames:v', '1', '-q:v', '2', path.join(tmp, `f${String(i).padStart(2, '0')}.jpg`)",
      "'-frames:v', '1', '-q:v', '2', '-pix_fmt', 'yuvj420p', path.join(tmp, `f${String(i).padStart(2, '0')}.jpg`)",
    ]],
  },
  {
    id: 'P2',
    name: '字幕带 format=yuvj420p',
    file: 'tools/commands/bili-watch.mjs',
    marker: 'format=yuvj420p,tile=1x',
    steps: [[
      "`crop=iw:ih*0.17:0:ih*0.83,scale=1280:-1,tile=1x${N}`",
      "`crop=iw:ih*0.17:0:ih*0.83,scale=1280:-1,format=yuvj420p,tile=1x${N}`",
    ]],
  },
  {
    id: 'P3',
    name: 'paths.mjs：F 盘媒体根（config > env > 默认）',
    file: 'tools/lib/paths.mjs',
    marker: '[P3] 2026-11-04',
    append: P3,
  },
  {
    id: 'P4',
    name: 'debrief：封面/九宫格落 out\\<bv>，字幕缓存落 tmp\\subs',
    file: 'tools/commands/debrief.mjs',
    marker: 'mediaDir(bvid)',
    steps: [
      ["import { dshPath } from '../lib/paths.mjs'",
       "import { dshPath, mediaDir, tmpRoot } from '../lib/paths.mjs'"],
      ["const shots = dshPath('shots')", "const shots = mediaDir(bvid)"],
      ["fs.mkdirSync(path.join(shots, 'covers'), { recursive: true })",
       "fs.mkdirSync(shots, { recursive: true })"],
      ["fs.mkdirSync(path.join(shots, 'subs'), { recursive: true })",
       "fs.mkdirSync(path.join(tmpRoot(), 'subs'), { recursive: true })"],
      ["const coverFile = path.join(shots, 'covers', `${bvid}.jpg`)",
       "const coverFile = path.join(shots, 'cover.jpg')"],
      ["const subFile = path.join(shots, 'subs', `${bvid}-debrief.txt`)",
       "const subFile = path.join(tmpRoot(), 'subs', `${bvid}-debrief.txt`)"],
      ["[watch, bvid, GRID, ...(opt.tile !== undefined",
       "[watch, bvid, GRID, shots, ...(opt.tile !== undefined"],
    ],
  },
  {
    id: 'P5',
    name: 'bili-watch：默认 outDir=out\\<bv>，抽帧中间帧进 tmp',
    file: 'tools/commands/bili-watch.mjs',
    marker: 'parsedOutDir',
    steps: [
      ["import { dshPath } from '../lib/paths.mjs'",
       "import { dshPath, mediaDir, tmpRoot } from '../lib/paths.mjs'"],
      ["watchOptions(process.argv.slice(2), dshPath('shots','video'))",
       "watchOptions(process.argv.slice(2), null)"],
      ["const {bvid,grid,outDir,tile:TILE} = parsed",
       "const {bvid,grid,outDir:parsedOutDir,tile:TILE} = parsed\nconst outDir = parsedOutDir || mediaDir(bvid)"],
      ["fs.mkdirSync(outDir, { recursive: true })",
       "fs.mkdirSync(outDir, { recursive: true })\nfs.mkdirSync(tmpRoot(), { recursive: true })"],
      ["const tmp = path.join(outDir, `.frames-${stamp}`)",
       "const tmp = path.join(tmpRoot(), `frames-${bvid}-${stamp}`)"],
    ],
  },
  {
    id: 'P6',
    name: 'subtitles：默认落 tmp\\subs',
    file: 'tools/commands/subtitles.mjs',
    marker: "tmpRoot(), 'subs'",
    steps: [
      ["import { dshPath } from '../lib/paths.mjs'",
       "import { dshPath, tmpRoot } from '../lib/paths.mjs'"],
      ["const outDir = typeof opt.out === 'string' ? opt.out : dshPath('shots', 'subs')",
       "const outDir = typeof opt.out === 'string' ? opt.out : path.join(tmpRoot(), 'subs')"],
    ],
  },
]

function applySteps(src, steps) {
  let out = src
  let changed = false
  for (const [oldText, newText] of steps) {
    if (!oldText || !out.includes(oldText)) continue
    if (newText && out.includes(newText)) continue   // 已替换过，别重复追加
    out = out.replace(oldText, newText)
    changed = true
  }
  return { out, changed }
}

let touched = 0
for (const root of roots) {
  for (const patch of patches) {
    const file = path.join(root, patch.file)
    if (!fs.existsSync(file)) continue
    const src = fs.readFileSync(file, 'utf8')
    if (patch.append) {
      if (src.includes(patch.marker)) continue
      if (dry) {
        console.log(`[dry] ${patch.id} ${patch.name} → ${file}`)
        touched++
        continue
      }
      const bak = file + '.orig'
      if (!fs.existsSync(bak)) fs.copyFileSync(file, bak)
      fs.writeFileSync(file, src.replace(/\s*$/, '\n') + patch.append)
      console.log(`已打补丁 ${patch.id}：${patch.name} → ${file}（备份 .orig）`)
      touched++
      continue
    }
    const { out, changed } = applySteps(src, patch.steps)
    if (!changed) continue
    if (dry) {
      console.log(`[dry] ${patch.id} ${patch.name} → ${file}`)
      touched++
      continue
    }
    const bak = file + '.orig'
    if (!fs.existsSync(bak)) fs.copyFileSync(file, bak)
    fs.writeFileSync(file, out)
    console.log(`已打补丁 ${patch.id}：${patch.name} → ${file}（备份 .orig）`)
    touched++
  }
}
console.log(touched ? '完成' : '没有可改的文件（已打过补丁，或没装 dsh-bili-whale）')
