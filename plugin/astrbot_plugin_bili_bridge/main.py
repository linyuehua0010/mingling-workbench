"""B 站视频理解桥接 —— 直接调工作台内置的 bili-whale 组件。

流程：群里认出链接 → 转成 BV → 本机跑 `node tools/bili.mjs debrief <BV>` →
把六路材料（元信息/封面/字幕/弹幕热区/热评/抽帧）丢给当前模型，
用冥零的口气说三到六句 → 回群里，顺带一张九宫格。
看完由代码直接写一条 livingmemory（不指望模型自觉调工具），再写台账；
冥零工作台（C++）读同一个台账。

另外给模型三个工具：bili_watch / bili_feed / bili_status，
没被 @ 时只要消息里有 BV 或链接（或明确在说 B 站），也会把这次对话
交给模型，由它决定看不看 —— 频率闸在插件这边兜底。

没有 HTTP 服务、没有轮询、没有 bili-service：一条消息一个子进程。
"""
from __future__ import annotations

import asyncio
import json
import importlib
import uuid
from contextlib import nullcontext
from types import SimpleNamespace
import os
import re
import sqlite3
import subprocess
import time
from datetime import date
from pathlib import Path

import aiohttp

from astrbot.api import logger
from astrbot.api.event import AstrMessageEvent, MessageChain, filter
from astrbot.api.message_components import Image, Plain
from astrbot.api.star import Context, Star

BILI_RE = re.compile(
    r"https?://(?:www\.|m\.)?bilibili\.com/video/(?:BV[0-9A-Za-z]{10}|av\d+)"
    r"|https?://b23\.tv/[0-9A-Za-z]+"
)
# 卡片里偶尔没有 http 前缀、或者带了跳转参数，松一点兜底
BILI_LOOSE = re.compile(
    r"(?:https?://)?(?:[\w-]+\.)?bilibili\.com/video/[A-Za-z0-9?=&%._/-]+"
    r"|(?:https?://)?b23\.tv/[0-9A-Za-z]+"
)
BV_RE = re.compile(r"BV[0-9A-Za-z]{10}")
SHEET_RE = re.compile(r"^SHEET:\s*(.+)$", re.M)
SUBS_RE = re.compile(r"^SUBS:\s*(.+)$", re.M)
TITLE_RE = re.compile(r"^标题:\s*(.+)$", re.M)
UP_RE = re.compile(r"^UP:\s*([^　\s]+)", re.M)
INTRO_RE = re.compile(r"^简介:\s*(.+)$", re.M)
HOT_RE = re.compile(r"^\s*👍\d+\s+回复\d+\s+([^:：]+)[:：]\s*(.+)$", re.M)

DEFAULTS = {
    "require_at": True,
    "grid": "3x3",
    "timeout": 300,
    "reply_with_persona": True,
    "persona_id": "冥零",
    "whale_dir": "",
    "node_exe": "",
    "bili_root": "",
    # 软触发：没被 @，消息里有 BV/链接（或明确在说 B 站）时也交给模型决定
    "soft_trigger": True,
    "soft_cooldown_min": 10,
    "same_bv_per_day": True,
    # 看完直接写 livingmemory
    "memory_write": True,
    "owner_session": "",
}

# 读不到 AstrBot 人设时的兜底（真正的人格在 data_v4.db 的 personas 表里）
FALLBACK_PERSONA = (
    "你是公孙冥零，2007-07-04 生的女生，蓝发深蓝眼，爱睡懒觉、嘴硬心软、爱吐槽但怕麻烦。"
    "说话短句，每条不超过三十个字，不用句号，可以用括号写动作。"
    "口头禅：「知道了知道了」「真拿你没办法」「哎呀，被发现了」。不客服腔，不列点。"
)

DEBRIEF_SYSTEM = (
    "现在有人在群里 @ 你，丢来一条 B 站视频让你看。下面是你刚看完的材料"
    "（元信息、字幕、弹幕热区、热评、抽帧说明）。用你自己的口气说三到六句："
    "这视频讲了什么、值不值得看、你自己什么感觉。"
    "不要列点、不要念数据、不要客服腔，短句，口语。"
)

SOFT_HINT_BV = (
    "\n\n（群里有人发了一个 B 站视频 {bv}。你要是想看，就调 bili_watch，"
    "参数 bv_or_url=\"{bv}\"；不想看就正常接话。没看过就别说看过。）"
)
SOFT_HINT_FEED = (
    "\n\n（群里有人让你去 B 站找点东西看。先调 bili_feed 拿今日选题，"
    "挑一条再调 bili_watch 看；不要凭空编视频。）"
)


# ──────────────────────────────────────────────────────────── 路径
_CFG_ROOT = ""   # 插件配置里的 bili_root，优先级最高


def _plugin_root() -> Path:
    return Path(__file__).resolve().parent


def _state_dir() -> Path:
    """工作台的状态目录（日记、限额、bili-whale 配置都在这），不依赖任何外部宿主环境。"""
    env = os.environ.get("MINGLING_STATE_DIR", "") or os.environ.get("MINGLING_STATE", "")
    if env.strip():
        return Path(env).expanduser()
    appdata = os.environ.get("APPDATA", "")
    if appdata.strip():
        return Path(appdata) / "MinglingWorkbench"
    return Path.home() / ".mingling-workbench"


def _whale_config() -> dict:
    """读 bili-whale 的 config（和工作台 Node 侧同一份）。"""
    cands = []
    p = os.environ.get("BILI_WHALE_CONFIG", "")
    if p.strip():
        cands.append(Path(p))
    cands.append(_state_dir() / "bili-whale.config.json")
    for cand in cands:
        try:
            return json.loads(cand.read_text(encoding="utf-8"))
        except Exception:
            continue
    return {}


def _paths() -> dict[str, Path]:
    """输出路径优先级：config 的 paths.* → 环境变量 → 工作台设置 → 文档\冥零工作台。

    产物只落在工作区 out/tmp/logs；凭据仍读用户目录下的 .bili-ai。
    """
    cfg = (_whale_config().get("paths") or {}) if isinstance(_whale_config(), dict) else {}

    def pick(key: str, env: str, fallback: Path) -> Path:
        val = cfg.get(key)
        if isinstance(val, str) and val.strip():
            return Path(val).expanduser().resolve()
        from_env = os.environ.get(env, "")
        if from_env.strip():
            return Path(from_env).expanduser().resolve()
        return fallback.resolve()

    fallback = _bili_root_default()
    if _CFG_ROOT.strip():
        fallback = Path(_CFG_ROOT).expanduser().resolve()
    root = pick("root", "BILI_ROOT", fallback)
    return {
        "root": root,
        "out": pick("outDir", "BILI_OUT_ROOT", root / "out"),
        "tmp": pick("tmpDir", "BILI_TMP_ROOT", root / "tmp"),
        "logs": pick("logsDir", "BILI_LOGS_ROOT", root / "logs"),
    }


def _bili_root_default() -> Path:
    """env → 工作台 settings.json → 开发树（向上找 win32/src）→ 文档\冥零工作台。"""
    for cand in (os.environ.get("BILI_ROOT", ""), os.environ.get("MINGLING_WORKSPACE", "")):
        if cand.strip() and Path(cand).is_dir():
            return Path(cand)
    try:
        cfg = json.loads((_state_dir() / "settings.json").read_text(encoding="utf-8"))
        ws = str(cfg.get("workspace") or "")
        if ws.strip() and Path(ws).is_dir():
            return Path(ws)
    except Exception:
        pass
    here = _plugin_root()
    for p in [here, *here.parents]:
        if (p / "win32" / "src" / "core.h").is_file():
            return p
    docs = Path.home() / "Documents" / "冥零工作台"
    return docs


def _bili_root() -> Path:
    return _paths()["root"]


def _ensure_dirs() -> dict[str, Path]:
    paths = _paths()
    for key in ("out", "tmp", "logs"):
        try:
            paths[key].mkdir(parents=True, exist_ok=True)
        except Exception as exc:
            logger.warning(f"[bili_bridge] 建目录失败 {paths[key]}: {exc}")
    (paths["logs"] / "jobs").mkdir(parents=True, exist_ok=True)
    return paths


def _first_existing(*paths: str | Path) -> Path | None:
    for p in paths:
        if not p:
            continue
        q = Path(p)
        if q.is_file():
            return q
        if q.is_dir() and (q / "tools" / "bili.mjs").is_file():
            return q / "tools" / "bili.mjs"
    return None


def _sidecar_dirs() -> list[Path]:
    """随安装包分发的 sidecar 可能在哪儿。"""
    out: list[Path] = []
    env = os.environ.get("MINGLING_SIDECAR", "")
    if env.strip():
        out.append(Path(env))
    local = os.environ.get("LOCALAPPDATA", "")
    if local.strip():
        out.append(Path(local) / "Programs" / "MinglingWorkbench" / "sidecar")
    pf = os.environ.get("ProgramFiles", "")
    if pf.strip():
        out.append(Path(pf) / "MinglingWorkbench" / "sidecar")
    here = _plugin_root()
    for p in [here, *here.parents]:
        out.append(p / "sidecar")
    return out


def _find_whale_dir(cfg_value: str) -> Path | None:
    cands: list[object] = [cfg_value, os.environ.get("BILI_WHALE_DIR", "")]
    cands += [d / "bili-whale" for d in _sidecar_dirs()]
    for c in cands:
        if c and (Path(c) / "tools" / "bili.mjs").is_file():
            return Path(c)
    return None


def _find_node(cfg_value: str) -> str:
    home = Path.home()
    if cfg_value and Path(cfg_value).is_file():
        return cfg_value
    for env in (os.environ.get("BILI_NODE", ""), os.environ.get("DSH_NODE", "")):
        if env and Path(env).is_file():
            return env
    for d in _sidecar_dirs():
        cand = d / "node" / "node.exe"
        if cand.is_file():
            return str(cand)
    for c in (r"C:\Program Files\nodejs\node.exe", str(home / "AppData" / "Local" / "Programs" / "nodejs" / "node.exe")):
        if Path(c).is_file():
            return c
    return "node"


def _persona_db() -> Path | None:
    cands: list[Path] = []
    data_env = os.environ.get("ASTRBOT_DATA", "")
    if data_env:
        cands.append(Path(data_env) / "data_v4.db")
    here = _plugin_root()
    for p in [here, *here.parents]:
        cands.append(p / "data_v4.db")
    for c in cands:
        if c.is_file():
            return c
    return None


def _persona_text(persona_id: str) -> str:
    db = _persona_db()
    if db is None:
        return FALLBACK_PERSONA
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=3)
        try:
            row = con.execute("SELECT system_prompt FROM personas WHERE persona_id = ?",
                              (persona_id,)).fetchone()
        finally:
            con.close()
        if row and row[0] and len(row[0]) > 40:
            return row[0]
    except Exception as exc:
        logger.debug(f"[bili_bridge] 读人设失败: {exc}")
    return FALLBACK_PERSONA


# ──────────────────────────────────────────────────────────── 台账 / 正文
def _append_job(rec: dict) -> None:
    try:
        logs = _paths()["logs"]
        logs.mkdir(parents=True, exist_ok=True)
        with (logs / "jobs.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception as exc:
        logger.warning(f"[bili_bridge] 写台账失败: {exc}")


def _save_sink(bv: str, text: str) -> str:
    try:
        d = _paths()["logs"] / "jobs"
        d.mkdir(parents=True, exist_ok=True)
        path = d / f"{bv}-{int(time.time())}.txt"
        path.write_text(text, encoding="utf-8")
        return str(path)
    except Exception as exc:
        logger.warning(f"[bili_bridge] 存正文失败: {exc}")
        return ""


def _pending_file() -> Path:
    return _paths()["logs"] / "memory-pending.jsonl"


def _pending_add(rec: dict) -> None:
    try:
        path = _pending_file()
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        logger.warning(f"[bili_bridge] 记忆没写进去，已进补写队列: {path}")
    except Exception as exc:
        logger.error(f"[bili_bridge] 连补写队列都写不了: {exc}")


def _pending_all() -> list[dict]:
    path = _pending_file()
    if not path.is_file():
        return []
    out = []
    for ln in path.read_text(encoding="utf-8").splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            out.append(json.loads(ln))
        except Exception:
            logger.warning(f"[bili_bridge] memory-pending 有一行不是 JSON，跳过: {ln[:80]}")
    return out


def _pending_rewrite(items: list[dict]) -> None:
    path = _pending_file()
    try:
        if not items:
            path.unlink(missing_ok=True)
            return
        path.write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in items),
                        encoding="utf-8")
    except Exception as exc:
        logger.error(f"[bili_bridge] 重写补写队列失败: {exc}")


# ──────────────────────────────────────────────────────────── 记忆
def _lm_plugin():
    """拿 livingmemory 插件实例；没装/没激活返回 None。"""
    try:
        from astrbot.core.star import star_map
    except Exception:
        try:
            from astrbot.core.star.star import star_map  # type: ignore
        except Exception as exc:
            logger.debug(f"[bili_bridge] 拿不到 star_map: {exc}")
            return None
    for md in list(star_map.values()):
        name = (getattr(md, "name", "") or "") + "|" + (getattr(md, "root_dir_name", "") or "")
        if "astrbot_plugin_livingmemory" not in name:
            continue
        star = getattr(md, "star_cls", None)
        if star is not None:
            return star
    return None


def _sentences(text: str) -> list[str]:
    return [s.strip() for s in re.split(r"(?<=[。！？!?])|\n", text or "") if s.strip()]


def _memory_view(body: str) -> str:
    sents = _sentences(body)
    if not sents:
        return "看完有点想法，但这次没说出来。"
    return sents[-1][:80]


def _memory_parts(raw: str, body: str) -> tuple[str, str, str]:
    """从 debrief 原文里抠「讲了什么 / 我的看法 / 关键点」。"""
    intro = (INTRO_RE.search(raw).group(1).strip() if INTRO_RE.search(raw) else "")
    sents = _sentences(body)
    said = intro
    if not said and sents:
        said = "".join(sents[:2])
    if not said:
        said = "（这条简介是空的，先记下看过）"

    hot = []
    for name, text in HOT_RE.findall(raw):
        text = re.sub(r"\[[^\]]*\]", "", text).strip()
        if text:
            hot.append(f"{name.strip()[:16]}：{text[:40]}")
        if len(hot) >= 3:
            break
    points = "；".join(hot) if hot else "（热评没取到，先记标题和 UP）"
    return said[:220], _memory_view(body), points


def _memory_text(bv: str, title: str, up: str, raw: str, body: str, media: Path) -> str:
    said, view, points = _memory_parts(raw, body)
    title = title or f"{bv}（标题没取到）"
    up = up or "未知UP"
    today = date.today().isoformat()
    return (
        f"【B站】{bv}《{title}》@{up}（{today}）\n"
        f"讲了什么：{said}\n"
        f"我的看法：{view}\n"
        f"关键点：{points}\n"
        f"素材：{media}"
    )


def _scope_api(plugin):
    package = type(plugin).__module__.rsplit(".", 1)[0]
    return importlib.import_module(package + ".core.memory_scope")


def _session_event(session_id: str, context=None, metadata=None):
    platform, kind, identity = session_id.split(":", 2)
    platform_name = platform
    get_platform = getattr(context, "get_platform_inst", None)
    if callable(get_platform):
        instance = get_platform(platform)
        if instance is None:
            raise ValueError("来源平台还未就绪")
        platform_name = instance.meta().name
    metadata = metadata or {}
    return SimpleNamespace(
        unified_msg_origin=session_id,
        get_platform_name=lambda: platform_name, get_platform_id=lambda: platform,
        get_sender_id=lambda: identity if kind == "FriendMessage" else str(metadata.get("source_sender_id") or ""),
        get_group_id=lambda: identity if kind == "GroupMessage" else "",
        get_sender_name=lambda: str(metadata.get("source_sender_name") or ""),
    )


async def _lm_remember(bv: str, content: str, session_id: str, meta: dict) -> str:
    """Use LivingMemory's own access/scope policy, and retain persona/source ownership."""
    plugin = _lm_plugin()
    if plugin is None:
        return "livingmemory 插件没加载（或没激活）"
    engine = getattr(getattr(plugin, "initializer", None), "memory_engine", None)
    if engine is None:
        return "livingmemory 的 memory_engine 还没初始化"
    if not session_id or len(session_id.split(":", 2)) != 3 or not bv or not content.strip():
        return "缺少来源、内容或有效的主人会话"
    try:
        api = _scope_api(plugin)
        config = plugin.config_manager
        event = _session_event(session_id, getattr(plugin, "context", None), meta)
        if not api.is_event_memory_allowed(config, event):
            return "来源会话不在长期记忆白名单内"
        scope = api.resolve_memory_scope(config, event) or session_id
        persona = str(meta.get("persona_id") or "冥零")
        metadata = {**meta, "source_session_id": session_id, "persona_id": persona,
                    "session_id": scope, "adapter_id": session_id.split(":", 1)[0]}
        adapter = getattr(api, "adapter_access", None)
        with adapter(config, event, write=True) if adapter else nullcontext():
            # Page through duplicates and only update within the same scope/persona.
            page = 1
            while True:
                existing = await engine.list_memories_page(keyword=bv, session_id=scope, page=page, page_size=50)
                items = existing.get("items") or []
                for item in items:
                    raw_meta = item.get("metadata") or {}
                    if isinstance(raw_meta, str):
                        raw_meta = json.loads(raw_meta)
                    if (str(raw_meta.get("bili_bv") or "") == bv
                            and raw_meta.get("session_id") == scope
                            and raw_meta.get("persona_id") == persona
                            and raw_meta.get("adapter_id", metadata["adapter_id"]) == metadata["adapter_id"]):
                        ok = await engine.update_memory(int(item["id"]), {
                            "content": content, "importance": 0.62,
                            "metadata": {**raw_meta, **metadata, "updated_at": int(time.time())},
                        })
                        return "" if ok else "update_memory 返回 False"
                if len(items) < 50:
                    break
                page += 1
            memory_id = await engine.add_memory(content, session_id=scope, persona_id=persona,
                                                importance=0.62, metadata=metadata)
            if memory_id is None or memory_id is False:
                return "add_memory 未返回成功记录"
        return ""
    except Exception as exc:
        return f"写入失败: {type(exc).__name__}: {exc}"


class BiliBridge(Star):
    def __init__(self, context: Context, config: dict | None = None):
        global _CFG_ROOT
        super().__init__(context)
        self.cfg = {**DEFAULTS, **(dict(config) if config else {})}
        _CFG_ROOT = str(self.cfg.get("bili_root") or "")
        self.whale = _find_whale_dir(str(self.cfg.get("whale_dir") or ""))
        self.node = _find_node(str(self.cfg.get("node_exe") or ""))
        self._memory_task = None
        self._memory_retry_after = {}
        self._memory_lock = asyncio.Lock()
        self._busy: set[str] = set()          # 正在跑的 BV，防重复
        self._cache: dict[str, tuple[float, dict]] = {}   # bv -> (时间, 结果)
        self._soft_last: dict[str, float] = {}            # umo -> 上次软触发时间
        self._bv_day: dict[str, str] = {}                 # bv -> 软触发过的日期

    async def initialize(self) -> None:
        paths = _ensure_dirs()
        self._memory_task = asyncio.create_task(self._memory_loop())
        logger.info(f"[bili_bridge] 产物根: out={paths['out']} tmp={paths['tmp']} logs={paths['logs']}")
        if self.whale:
            logger.info(f"[bili_bridge] bili-whale 就绪 → {self.whale}")
        else:
            logger.warning("[bili_bridge] 没找到内置 B 站组件（工作台 sidecar\\bili-whale），B 站链接会看不了")

    async def terminate(self) -> None:
        if self._memory_task:
            self._memory_task.cancel()
            await asyncio.gather(self._memory_task, return_exceptions=True)
            self._memory_task = None
        self._busy.clear()

    def _owner_session(self) -> str:
        configured = str(self.cfg.get("owner_session") or "").strip()
        if configured:
            return configured
        # The setup allowlist contains the actual platform instance and owner session.
        plugin = _lm_plugin()
        config = getattr(plugin, "config_manager", None)
        allowed = config.get("access_control.allowed_ids", "") if config else ""
        values = allowed if isinstance(allowed, list) else re.split(r"[,;\n]", str(allowed))
        private = [str(x).strip() for x in values if ":FriendMessage:" in str(x) and not str(x).startswith("webchat:")]
        return private[0] if len(private) == 1 else ""

    async def _flush_memory(self) -> tuple[int, int]:
        async with self._memory_lock:
            if not self.cfg.get("memory_write", True):
                count = len(_pending_all()) + len(list((_paths()["logs"] / "memory-inbox").glob("*.json")))
                self._memory_status(0, count, "长期记忆写入已关闭")
                return 0, count
            done, last_error = 0, ""
            inbox = _paths()["logs"] / "memory-inbox"
            inbox.mkdir(parents=True, exist_ok=True)
            # Migrate the old queue synchronously before any await. Published files survive
            # cancellation/crashes, and new producers never race with a JSONL rewrite.
            remaining = []
            for it in _pending_all():
                try:
                    self._publish_memory(inbox, it)
                except OSError:
                    remaining.append(it)
            _pending_rewrite(remaining)
            last_error = self._backfill_jobs(inbox) or ""
            for path in [p for p in sorted(inbox.glob("*.json")) if self._memory_retry_after.get(p.name, 0) <= time.time()][:20]:
                self._memory_retry_after[path.name] = time.time() + 60
                try:
                    it = json.loads(path.read_text(encoding="utf-8-sig"))
                    meta = dict(it.get("metadata") or {})
                    meta.setdefault("persona_id", self.cfg["persona_id"])
                    err = await _lm_remember(str(it.get("bv", "")), str(it.get("content", "")),
                                             str(it.get("session_id") or self._owner_session()), meta)
                    if err:
                        last_error = err
                        logger.warning(f"[bili_bridge] 工作台记忆待补写: {err}")
                    else:
                        path.unlink()
                        self._memory_retry_after.pop(path.name, None)
                        done += 1
                except Exception as exc:
                    last_error = str(exc)
                    logger.warning(f"[bili_bridge] 工作台记忆待补写 {path.name}: {exc}")
            count = len(_pending_all()) + len(list(inbox.glob("*.json")))
            self._memory_status(done, count, last_error)
            return done, count

    @staticmethod
    def _memory_status(done: int, count: int, error: str):
        path = _paths()["logs"] / "memory-status.json"
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"updated": int(time.time()), "done": done, "pending": count,
                                   "error": error}, ensure_ascii=False), encoding="utf-8")
        tmp.replace(path)

    @staticmethod
    def _publish_memory(inbox: Path, record: dict):
        path = inbox / (uuid.uuid4().hex + ".json")
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        tmp.replace(path)

    def _backfill_jobs(self, inbox: Path):
        """Recover earlier successful workbench reads, including reads before this fix."""
        logs = _paths()["logs"]
        ledger, cursor = logs / "jobs.jsonl", logs / "memory-jobs.cursor"
        if not ledger.is_file():
            return
        try:
            offset = int(cursor.read_text()) if cursor.exists() else 0
            if offset > ledger.stat().st_size:
                offset = 0
            with ledger.open("rb") as stream:
                stream.seek(offset)
                for _ in range(20):
                    line = stream.readline()
                    if not line or not line.endswith(b"\n"):
                        break
                    try:
                        job = json.loads(line.decode("utf-8-sig"))
                    except (ValueError, UnicodeError):
                        offset = stream.tell()
                        continue
                    # New jobs already have an immutable queue entry.
                    if job.get("source") == "console" and job.get("status") == "ok" and not job.get("memory_queued"):
                        sink = Path(str(job.get("sink") or "")).resolve()
                        if sink.is_file() and sink.is_relative_to((logs / "jobs").resolve()):
                            content = sink.read_text(encoding="utf-8-sig")[:6000]
                            self._publish_memory(inbox, {
                                "bv": job.get("bv", ""),
                                "content": f"【工作台阅读记录】{job.get('title', '')}\n来源：{job.get('bv', '')}\n{content}",
                                "metadata": {"memory_origin": "workbench", "source": job.get("type") or "bilibili",
                                             "bili_bv": job.get("bv", "")},
                            })
                    offset = stream.tell()
            tmp = cursor.with_suffix(".tmp")
            tmp.write_text(str(offset))
            tmp.replace(cursor)
        except (OSError, ValueError) as exc:
            logger.warning(f"[bili_bridge] 历史阅读记忆等待补写: {exc}")
            return str(exc)

    async def _memory_loop(self):
        while True:
            try:
                await self._flush_memory()
            except Exception as exc:
                logger.warning(f"[bili_bridge] 自动补写记忆失败: {exc}")
            await asyncio.sleep(30)


    # ------------------------------------------------------------------ 入站
    @filter.event_message_type(filter.EventMessageType.ALL)
    async def on_message(self, event: AstrMessageEvent):
        text = _collect_text(event)
        logger.debug(f"[bili_bridge] 收到消息 {event.unified_msg_origin}: {text[:80]!r}")
        bv = _pick_bv(text)
        url = ""
        if not bv:
            match = BILI_RE.search(text) or BILI_LOOSE.search(text)
            if not match:
                if self.cfg.get("soft_trigger") and _mentions_bili(text):
                    self._maybe_soft(event, "", feed_only=True)
                return
            url = match.group(0)
            if not url.lower().startswith("http"):
                url = "https://" + url

        woken = _is_woken(event)
        if not woken:
            # require_at 只是「强触发」：被 @ 一定看；没被 @ 走软触发，看不看交给模型
            if not self.cfg.get("soft_trigger"):
                logger.info("[bili_bridge] 认出链接但要 @ 才处理，这条跳过")
                return
            if not self._maybe_soft(event, bv):
                return
            logger.info(f"[bili_bridge] 软触发：{bv or url} 交给模型决定")
            return

        if not self.whale:
            yield event.plain_result("工作台的内置 B 站组件没找到，我这边看不了。")
            return

        umo = event.unified_msg_origin
        chat = _chat_label(event)
        asyncio.create_task(self._handle(umo, chat, bv, url, {"source_sender_id": event.get_sender_id(), "source_sender_name": event.get_sender_name()}))
        yield event.plain_result("知道了知道了，我看一眼（看到字幕和弹幕，慢的话一两分钟）。")

    def _maybe_soft(self, event: AstrMessageEvent, bv: str, feed_only: bool = False) -> bool:
        """软触发闸：同会话 10 分钟 1 次；同 BV 当天只放一次。"""
        umo = event.unified_msg_origin
        now = time.time()
        last = self._soft_last.get(umo, 0.0)
        cooldown = float(self.cfg.get("soft_cooldown_min", 10) or 10) * 60
        if last and now - last < cooldown:
            logger.info(f"[bili_bridge] 软触发被冷却挡下（{int(now - last)}s < {int(cooldown)}s）")
            return False
        today = date.today().isoformat()
        if bv and self.cfg.get("same_bv_per_day", True) and self._bv_day.get(bv) == today:
            logger.info(f"[bili_bridge] 软触发被同日去重挡下：{bv}")
            return False
        self._soft_last[umo] = now
        if bv:
            self._bv_day[bv] = today
        event.is_at_or_wake_command = True
        event.set_extra("_bili_soft_bv", bv or "")
        event.set_extra("_bili_soft_feed", feed_only and not bv)
        return True

    @filter.on_llm_request()
    async def _bili_soft_hint(self, event: AstrMessageEvent, req):
        bv = event.get_extra("_bili_soft_bv", "")
        if bv:
            req.system_prompt = (req.system_prompt or "") + SOFT_HINT_BV.format(bv=bv)
        elif event.get_extra("_bili_soft_feed", False):
            req.system_prompt = (req.system_prompt or "") + SOFT_HINT_FEED

    # ------------------------------------------------------------------ 干活
    async def _handle(self, umo: str, chat: str, bv: str, url: str, identity: dict | None = None) -> None:
        started = time.time()
        try:
            if not bv:
                bv = await self._resolve_bv(url)
            if not bv:
                await self._say(umo, "这个链接我追不到 BV 号，你直接贴 BV 吧。")
                return
            if bv in self._busy:
                await self._say(umo, f"{bv} 正在看，别催。")
                return
            res = await self._watch(bv, umo, chat, source="qq")
            if not res.get("ok"):
                await self._say(umo, res.get("message") or "没看成。")
                return
            body = await self._summarize_bounded(res["raw"], chat)
            self._cache[bv] = (time.time(), {**res, "body": body})
            if self.cfg.get("memory_write", True):
                await self._remember(bv, res, body, umo, identity)
            await self._deliver(umo, body, res.get("sheet", ""))
        except Exception:
            logger.exception("[bili_bridge] 处理失败")
            await self._say(umo, "这条我卡住了，回头再说。")
        finally:
            self._busy.discard(bv or "")

    async def _watch(self, bv: str, umo: str, chat: str, source: str = "qq") -> dict:
        """跑一次 debrief，解析、存正文、记台账。工具和 @ 路径共用。"""
        started = time.time()
        cached = self._cache.get(bv)
        if cached and time.time() - cached[0] < 1800:
            return {**cached[1], "cached": True}
        if bv in self._busy:
            return {"ok": False, "error": "BILI_E_BUSY", "message": f"{bv} 正在看，别催。"}
        if not self.whale:
            return {"ok": False, "error": "BILI_E_NO_WHALE", "message": "工作台的内置 B 站组件没找到，我这边看不了。"}
        self._busy.add(bv)
        try:
            raw = await self._run(["debrief", bv, "--grid", str(self.cfg.get("grid", "3x3"))])
            err = _classify(raw)
            if err:
                _append_job({"t": int(started), "bv": bv, "title": "", "up": "", "source": source,
                             "chat": chat, "status": "fail", "sink": "", "error": err,
                             "seconds": f"{int(time.time() - started)}s"})
                return {"ok": False, "error": err, "message": _ERRORS[err][0], "raw": raw}

            title = (TITLE_RE.search(raw).group(1).strip() if TITLE_RE.search(raw) else "")
            up = (UP_RE.search(raw).group(1).strip() if UP_RE.search(raw) else "")
            sheet = (SHEET_RE.search(raw).group(1).strip() if SHEET_RE.search(raw) else "")
            sink = _save_sink(bv, raw)
            media = _paths()["out"] / bv
            res = {
                "ok": True, "bv": bv, "title": title, "up": up, "sheet": sheet,
                "sink": sink, "raw": raw, "out_dir": str(media), "seconds": int(time.time() - started),
            }
            _append_job({"t": int(started), "bv": bv, "title": title, "up": up, "source": source,
                         "chat": chat, "status": "ok", "sink": sink,
                         "seconds": f"{int(time.time() - started)}s"})
            self._cache[bv] = (time.time(), res)
            return res
        finally:
            self._busy.discard(bv)

    async def _remember(self, bv: str, res: dict, body: str, umo: str, identity: dict | None = None) -> None:
        media = Path(res.get("out_dir") or (_paths()["out"] / bv))
        content = _memory_text(bv, res.get("title", ""), res.get("up", ""), res.get("raw", ""), body, media)
        meta = {
            **(identity or {}),
            "bili_bv": bv, "bili_title": res.get("title", ""), "bili_up": res.get("up", ""),
            "bili_sheet": res.get("sheet", ""), "bili_out_dir": str(media),
            "memory_origin": "bili_bridge", "source": "bilibili",
            "persona_id": self.cfg["persona_id"],
        }
        async with self._memory_lock:
            err = await _lm_remember(bv, content, umo, meta)
        if err:
            logger.warning(f"[bili_bridge] 写记忆失败（{bv}）：{err}")
            _pending_add({"t": int(time.time()), "bv": bv, "content": content,
                          "session_id": umo, "metadata": meta, "error": err})
        else:
            logger.info(f"[bili_bridge] 已写入 livingmemory：{bv}")

    async def _summarize_bounded(self, raw: str, chat: str) -> str:
        """总结最多等 45 秒；模型抽风就退回模板，别把记忆和回复一起拖死。"""
        try:
            return await asyncio.wait_for(self._summarize(raw, chat), timeout=45)
        except asyncio.TimeoutError:
            logger.warning("[bili_bridge] 模型总结超时，退回模板")
            return _fallback_text(raw)

    async def _summarize(self, raw: str, chat: str) -> str:
        """把六路材料交给当前模型，用冥零的口气说几句。"""
        if not self.cfg.get("reply_with_persona", True):
            return _fallback_text(raw)
        try:
            provider = await self.context.get_using_provider_async()
            if provider is None:
                return _fallback_text(raw)
            system = _persona_text(str(self.cfg.get("persona_id") or "冥零")) + DEBRIEF_SYSTEM
            prompt = raw[:6000]
            resp = await provider.text_chat(prompt=prompt, system_prompt=system)
            body = (getattr(resp, "completion_text", "") or "").strip()
            if len(body) < 8:
                return _fallback_text(raw)
            return body[:900]
        except Exception as exc:
            logger.warning(f"[bili_bridge] 讨模型失败，退回模板: {exc}")
            return _fallback_text(raw)

    async def _run(self, args: list[str], timeout: float | None = None) -> str:
        env = dict(os.environ)
        env.setdefault("PYTHONUTF8", "1")
        paths = _paths()
        # bili-whale 的日记/quota/切片缓存都放工作台状态目录
        state = _state_dir()
        env["DSH_HOME"] = str(state / "bili-state")
        env["BILI_WHALE_CONFIG"] = str(state / "bili-whale.config.json")
        for d in _sidecar_dirs():
            ff = d / "bili-whale" / "bin" / "ffmpeg.exe"
            if ff.is_file():
                env.setdefault("FFMPEG", str(ff))
                break
        env["BILI_ROOT"] = str(paths["root"])
        env["BILI_OUT_ROOT"] = str(paths["out"])
        env["BILI_TMP_ROOT"] = str(paths["tmp"])
        env["BILI_LOGS_ROOT"] = str(paths["logs"])
        cmd = [self.node, str(self.whale / "tools" / "bili.mjs"), *args]

        def call() -> subprocess.CompletedProcess:
            return subprocess.run(cmd, cwd=str(paths["root"]), env=env,
                                  timeout=timeout or float(self.cfg.get("timeout", 300)),
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))

        try:
            cp = await asyncio.to_thread(call)
            return (cp.stdout or b"").decode("utf-8", "replace")
        except subprocess.TimeoutExpired:
            return "__BILI_TIMEOUT__"
        except Exception as exc:
            logger.warning(f"[bili_bridge] 跑 bili-whale 失败: {exc}")
            return "__BILI_NO_RUN__"

    async def _resolve_bv(self, url: str) -> str:
        """b23.tv 短链、带参数的链接 → BV 号。"""
        if not url:
            return ""
        found = BV_RE.search(url)
        if found:
            return found.group(0)
        if "/av" in url or "av" in url:
            aid = re.search(r"av(\d+)", url)
            if aid:
                bv = await self._av_to_bv(aid.group(1))
                if bv:
                    return bv
        # 短链：跟着跳转走一趟，最终地址里就有 BV
        try:
            async with aiohttp.ClientSession() as s:
                async with s.get(url, allow_redirects=True,
                                 timeout=aiohttp.ClientTimeout(total=12),
                                 headers={"user-agent": "Mozilla/5.0"}) as r:
                    final = str(r.url)
        except Exception as exc:
            logger.info(f"[bili_bridge] 短链解析失败: {exc}")
            return ""
        found = BV_RE.search(final)
        return found.group(0) if found else ""

    async def _av_to_bv(self, aid: str) -> str:
        try:
            async with aiohttp.ClientSession() as s:
                async with s.get(f"https://api.bilibili.com/x/web-interface/view?aid={aid}",
                                 timeout=aiohttp.ClientTimeout(total=10),
                                 headers={"user-agent": "Mozilla/5.0"}) as r:
                    data = await r.json(content_type=None)
            return str((data.get("data") or {}).get("bvid") or "")
        except Exception:
            return ""

    async def _deliver(self, umo: str, text: str, sheet: str) -> None:
        chain = [Plain(text[:1500])]
        if sheet and os.path.isfile(sheet):
            chain.append(Image.fromFileSystem(sheet))
        try:
            await self.context.send_message(umo, MessageChain(chain=chain))
        except Exception as exc:
            logger.error(f"[bili_bridge] 发送失败: {exc}")

    async def _say(self, umo: str, text: str) -> None:
        await self._deliver(umo, text, "")

    # ------------------------------------------------------------------ 工具
    @filter.llm_tool(name="bili_watch")
    async def bili_watch(self, event: AstrMessageEvent, bv_or_url: str):
        """看一条 B 站视频：抓字幕、弹幕热区、热评和九宫格，然后用冥零的口气回群。
        用户发了 BV 号 / b23.tv / bilibili.com/video 链接、或让你去看某个视频时调用。

        Args:
            bv_or_url(string): BV 号（如 BV1o64y167qq）或 B 站视频链接
        """
        raw_in = (bv_or_url or "").strip()
        bv = _pick_bv(raw_in) or (await self._resolve_bv(raw_in) if raw_in else "")
        if not bv:
            return _tool_json({"ok": False, "error": "BILI_E_BAD_BV",
                               "message": "没认出 BV 号，要 12 位 BV 或完整链接"})
        umo = event.unified_msg_origin
        chat = _chat_label(event)
        await self._say(umo, "知道了知道了，我看一眼（看到字幕和弹幕，慢的话一两分钟）。")
        res = await self._watch(bv, umo, chat, source="tool")
        if not res.get("ok"):
            await self._say(umo, res.get("message") or "没看成。")
            return _tool_json({"ok": False, "error": res.get("error", "BILI_E_UNKNOWN"),
                               "message": res.get("message", "没看成"), "bv": bv})
        body = await self._summarize_bounded(res["raw"], chat)
        if self.cfg.get("memory_write", True):
            await self._remember(bv, res, body, umo, {"source_sender_id": event.get_sender_id(), "source_sender_name": event.get_sender_name()})
        await self._deliver(umo, body, res.get("sheet", ""))
        said, _, points = _memory_parts(res["raw"], body)
        return _tool_json({
            "ok": True, "bv": bv, "title": res.get("title", ""), "up": res.get("up", ""),
            "summary": said, "view": _memory_view(body), "points": points,
            "sheet": res.get("sheet", ""), "out_dir": res.get("out_dir", ""),
            "note": "已经发到群里了（文字+九宫格），你接一句话就行，别重复发图。",
        })

    @filter.llm_tool(name="bili_feed")
    async def bili_feed(self, event: AstrMessageEvent):
        """拿今天 B 站的选题列表（标题、UP、时长、播放量），挑一条再调 bili_watch。"""
        if not self.whale:
            return _tool_json({"ok": False, "error": "BILI_E_NO_WHALE", "message": "bili-whale 没装好"})
        out = await self._run(["feed", "--n", "5"], timeout=60)
        lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
        picks = [ln for ln in lines if re.match(r"^\d+\.\s*BV", ln)][:5]
        if not picks:
            # feed 输出是选题列表而不是六路材料，拿到 BV 行就算成功
            err = _classify(out) or "BILI_E_UNKNOWN"
            return _tool_json({"ok": False, "error": err, "message": _ERRORS[err][0]})
        return _tool_json({"ok": True, "items": picks,
                           "note": "不要念编号；挑一条你真有兴趣的调 bili_watch。"})

    @filter.llm_tool(name="bili_status")
    async def bili_status(self, event: AstrMessageEvent):
        """查 bili-whale 的登录状态和今天还剩多少观看配额。"""
        if not self.whale:
            return _tool_json({"ok": False, "error": "BILI_E_NO_WHALE", "message": "bili-whale 没装好"})
        sess = await self._run(["session"], timeout=40)
        quota = await self._run(["quota", "status"], timeout=40)
        err = _classify(sess)
        if err:
            return _tool_json({"ok": False, "error": err, "message": _ERRORS[err][0], "raw": sess[-300:]})
        head = next((ln.strip() for ln in sess.splitlines() if "账号" in ln), "")
        qline = next((ln.strip() for ln in quota.splitlines() if "剩余" in ln or "配额" in ln), "")
        return _tool_json({"ok": True, "login": head, "quota": qline or quota.strip()[-160:]})

    # ------------------------------------------------------------------ 指令
    @filter.command("bili")
    async def bili_status_cmd(self, event: AstrMessageEvent):
        """看看 bili-whale 活着没有。"""
        if not self.whale:
            yield event.plain_result("bili-whale 没找到。")
            return
        out = await self._run(["session"], timeout=40)
        lines = [ln.strip() for ln in (out or "").splitlines() if ln.strip()]
        head = next((ln for ln in lines if "账号" in ln), "")
        status = "在线" if "有效" in (out or "") else "没登录"
        yield event.plain_result(f"bili-whale {status}｜{head or (lines[0][:60] if lines else '没输出')}")

    @filter.command("bili_mem")
    async def bili_mem_cmd(self, event: AstrMessageEvent):
        """把 memory-pending.jsonl 里的记忆补写进 livingmemory。/bili_mem flush"""
        done, remaining = await self._flush_memory()
        yield event.plain_result(f"补写完成：成功 {done} 条，还剩 {remaining} 条。")



# ──────────────────────────────────────────────────────────── 工具函数
_ERRORS = {
    "BILI_E_NO_WHALE": ("bili-whale 没装好，看不了。",),
    "BILI_E_AUTH": ("B 站登录过期了，得重新扫码登录。",),
    "BILI_E_QUOTA": ("今天的观看配额用完了，明天再看。",),
    "BILI_E_PATCH": ("抽帧补丁没打，九宫格出不来。",),
    "BILI_E_TIMEOUT": ("看太久了没跑完，稍后再试。",),
    "BILI_E_RUN": ("bili-whale 起不来，检查一下 node。",),
    "BILI_E_UNKNOWN": ("没看成，原因不明。",),
}


def _classify(raw: str) -> str:
    """把 bili-whale 的输出/失败归类成错误码；成功返回 ''。"""
    text = raw or ""
    if text == "__BILI_TIMEOUT__":
        return "BILI_E_TIMEOUT"
    if text == "__BILI_NO_RUN__":
        return "BILI_E_RUN"
    if "①" in text:
        return ""
    low = text.lower()
    if any(k in text for k in ("凭据过期", "登录过期", "未登录", "凭据无效", "请先登录")):
        return "BILI_E_AUTH"
    if any(k in text for k in ("配额", "quota")) and any(k in text for k in ("用完", "不足", "超")):
        return "BILI_E_QUOTA"
    if "yuvj420p" in low or "抽帧" in text and "失败" in text:
        return "BILI_E_PATCH"
    return "BILI_E_UNKNOWN"


def _tool_json(obj: dict) -> str:
    return json.dumps(obj, ensure_ascii=False)


def _mentions_bili(text: str) -> bool:
    low = (text or "").lower()
    return "b站" in low or "bilibili" in low or "b23.tv" in low


def _pick_bv(text: str) -> str:
    m = BV_RE.search(text)
    return m.group(0) if m else ""


def _fallback_text(raw: str) -> str:
    title = TITLE_RE.search(raw)
    up = UP_RE.search(raw)
    bits = []
    if title:
        bits.append(f"看了《{title.group(1).strip()}》")
    if up:
        bits.append(f"，{up.group(1).strip()} 的")
    hot = [ln.strip() for ln in raw.splitlines() if ln.strip().startswith(("🔥", "·"))][:2]
    if hot:
        bits.append("\n" + "\n".join(hot))
    return "".join(bits) or "看完了，材料在这：\n" + raw[:300]


def _components(event: AstrMessageEvent) -> list:
    obj = getattr(event, "message_obj", None)
    return list(getattr(obj, "message", None) or [])


def _collect_text(event: AstrMessageEvent) -> str:
    """纯文本 + 所有卡片/分享里能挖到的链接，拼成一段再匹配。"""
    parts = [event.message_str or ""]
    for comp in _components(event):
        name = getattr(getattr(comp, "type", None), "value", None) or type(comp).__name__
        if name == "Json":
            data = getattr(comp, "data", None)
            try:
                parts.append(json.dumps(data, ensure_ascii=False))
            except (TypeError, ValueError):
                parts.append(str(data))
        elif name in ("Share", "Unknown"):
            for attr in ("url", "text", "title"):
                val = getattr(comp, attr, None)
                if isinstance(val, str) and val:
                    parts.append(val)
        elif name == "Plain":
            parts.append(getattr(comp, "text", "") or "")
    joined = chr(10).join(p for p in parts if p)
    return joined.replace(chr(92) + "/", "/")


def _is_woken(event: AstrMessageEvent) -> bool:
    if getattr(event, "is_at_or_wake_command", False):
        return True
    try:
        return bool(event.is_wake_up())
    except Exception:
        return False


def _chat_label(event: AstrMessageEvent) -> str:
    try:
        gid = event.get_group_id()
        return f"群{gid}" if gid else "私聊"
    except Exception:
        return ""
