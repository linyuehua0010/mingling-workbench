"""bili_bridge 插件自检：不连 QQ，只验证「找得到、跑得通」。

跑法（用 AstrBot 自己的 python）：
    <AstrBot>\\.venv\\Scripts\\python.exe plugin-selftest.py
    ... plugin-selftest.py --watch BV1Rk4364Ewp

第一段只做路径/人设发现（秒回），加 --watch 才会真跑一条 debrief（十几秒，会消耗一次网络请求）。
AstrBot 那套包 import 不了时退回 stub，只测纯逻辑。
"""
from __future__ import annotations

import argparse
import asyncio
import importlib
import logging
import sys
import time
import types
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parent / "plugin" / "astrbot_plugin_bili_bridge"


def _stub(name: str, **attrs) -> types.ModuleType:
    mod = types.ModuleType(name)
    for key, value in attrs.items():
        setattr(mod, key, value)
    sys.modules[name] = mod
    return mod


class _Any:
    def __init__(self, *a, **k):
        pass

    def __getattr__(self, item):
        return _Any()

    def __call__(self, *a, **k):
        return _Any()


class _Star:
    def __init__(self, ctx=None):
        self.context = ctx


def load_plugin():
    sys.path.insert(0, str(PLUGIN_DIR))
    try:
        return importlib.import_module("main")
    except Exception as exc:
        print(f"[warn] 直接 import 失败（{type(exc).__name__}: {exc}），改用 stub 模块")
        sys.modules.pop("main", None)
        _stub("astrbot")
        _stub("astrbot.api", logger=logging.getLogger("selftest"))
        _stub("astrbot.api.event", filter=_Any(), AstrMessageEvent=object, MessageChain=_Any)
        _stub("astrbot.api.star", Context=object, Star=_Star, register=lambda *a, **k: (lambda cls: cls))
        _stub("astrbot.api.message_components", Plain=_Any, Image=_Any)
        _stub("aiohttp")
        return importlib.import_module("main")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--watch", default="", help="顺手跑一条 debrief 的 BV 号")
    args = ap.parse_args()

    m = load_plugin()
    print("bili 根目录 :", m._bili_root())
    print("插件目录    :", m._plugin_root())
    print("bili-whale  :", m._find_whale_dir("") or "没找到")
    print("node        :", m._find_node(""))
    db = m._persona_db()
    print("人设库      :", db or "没找到")
    persona = m._persona_text("大肥鱼")
    print(f"人设长度    : {len(persona)} 字符（前 40：{persona[:40]!r}）")
    print("BV 识别     :", m._pick_bv("看看 https://www.bilibili.com/video/BV1Rk4364Ewp?p=1 这个"))

    if not args.watch:
        print("\n路径都通了。想看真实链路就加 --watch <BV 号>")
        return 0

    bridge = m.BiliBridge(None, {})
    started = time.time()
    text = asyncio.run(bridge._run(["debrief", args.watch, "--grid", "3x3"], 240))
    print(f"\ndebrief 用时 {time.time() - started:.1f}s，输出 {len(text)} 字符")
    title = m.TITLE_RE.search(text)
    sheet = m.SHEET_RE.search(text)
    print("标题        :", title.group(1) if title else "没解析到")
    print("九宫格      :", sheet.group(1) if sheet else "没解析到")
    print("退回文案    :", m._fallback_text(text)[:60].replace(chr(10), " "), "...")
    return 0 if (title and sheet) else 1


if __name__ == "__main__":
    raise SystemExit(main())
