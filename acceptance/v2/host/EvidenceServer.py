#!/usr/bin/env python3
"""acceptance/v2/host/EvidenceServer.py — 证据接收与阶段文件分发（宿主机侧）

为什么重写：旧 acceptance/host-http.py 无论成败都返回 200，且固定写 vm-upload/，
无法区分"上传成功"与"写盘失败"，也不记录 SHA256。验收要求：检查上传 HTTP 状态、
核本机回收文件 SHA256、每次运行独立 run-id 不覆盖旧证据。

路由：
  GET  /health                              服务与目录自检
  GET  /stage/<name>                        下载 acceptance/stage/<name>（安装包与夹具）
  POST /upload/<runId>/<phase>/<name>       写入 acceptance/evidence/<runId>/<phase>/<name>
  GET  /receipts/<runId>                    该 run 的上传回执（JSON）

回执：每次 POST 追加一行 JSON 到 acceptance/evidence/<runId>/receipts.jsonl，
字段 utc/client/path/status/bytes/sha256/expectedSha256/error。状态码：
  200 写入并已 fsync；400 路径非法；413 超过上限；500 写盘失败。
"""
import hashlib
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STAGE = os.path.join(ROOT, "v2", "stage")  # v2：含真实安装包与清单；旧 acceptance/stage 里没有 exe
EVIDENCE = os.path.join(ROOT, "evidence")
MAX_BYTES = 512 * 1024 * 1024
SAFE = re.compile(r"^[A-Za-z0-9._\-\u4e00-\u9fff ]{1,180}$")
SAFE_RUN = re.compile(r"^[A-Za-z0-9._\-]{1,80}$")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class Handler(BaseHTTPRequestHandler):
    server_version = "MwEvidence/2.1"

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _receipt(self, run_id, entry):
        if not SAFE_RUN.match(run_id or ""):
            return
        d = os.path.join(EVIDENCE, run_id)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "receipts.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s %s\n" % (time.strftime("%H:%M:%S"), self.client_address[0], fmt % args))

    def do_GET(self):
        if self.path.startswith("/health"):
            ok = os.path.isdir(STAGE) and os.path.isdir(EVIDENCE)
            return self._json(200 if ok else 500, {
                "ok": ok, "stage": STAGE, "evidence": EVIDENCE,
                "stageFiles": sorted(os.listdir(STAGE))[:50] if os.path.isdir(STAGE) else [],
            })
        if self.path.startswith("/receipts/"):
            run_id = self.path.split("/")[2]
            if not SAFE_RUN.match(run_id):
                return self._json(400, {"ok": False, "error": "bad run id"})
            p = os.path.join(EVIDENCE, run_id, "receipts.jsonl")
            if not os.path.exists(p):
                return self._json(404, {"ok": False, "error": "no receipts"})
            rows = []
            with open(p, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        rows.append(json.loads(line))
            return self._json(200, {"ok": True, "count": len(rows), "receipts": rows})
        if self.path.startswith("/stage/"):
            name = self.path[len("/stage/"):].split("?")[0]
            if not SAFE.match(name):
                return self._json(400, {"ok": False, "error": "bad stage name"})
            p = os.path.join(STAGE, name)
            if not os.path.isfile(p):
                return self._json(404, {"ok": False, "error": "not found", "stage": STAGE})
            data = open(p, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("X-Sha256", hashlib.sha256(data).hexdigest())
            self.end_headers()
            self.wfile.write(data)
            return
        return self._json(404, {"ok": False, "error": "unknown route"})

    def do_POST(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        client = self.client_address[0]
        if len(parts) != 4 or parts[0] != "upload":
            return self._json(400, {"ok": False, "error": "bad route; want /upload/<run>/<phase>/<name>"})
        _, run_id, phase, name = parts
        if not SAFE_RUN.match(run_id) or not SAFE_RUN.match(phase) or not SAFE.match(name):
            return self._json(400, {"ok": False, "error": "bad run/phase/name"})
        expected = (self.headers.get("X-MW-Sha256") or self.headers.get("X-Sha256") or "").lower()
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BYTES:
            return self._json(413, {"ok": False, "error": "bad/oversized content-length", "length": length})
        data = self.rfile.read(length)
        d = os.path.join(EVIDENCE, run_id, phase)
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        entry = {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "client": client,
                 "runId": run_id, "phase": phase, "name": name, "path": p,
                 "bytes": len(data), "expectedSha256": expected}
        try:
            tmp = p + ".part"
            with open(tmp, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, p)
            entry["sha256"] = sha256_file(p)
            entry["status"] = 200
            if expected and expected != entry["sha256"]:
                entry["status"] = 409
                entry["error"] = "sha256 mismatch between header and stored bytes"
            self._receipt(run_id, entry)
            if entry["status"] == 409:
                return self._json(409, {"ok": False, "error": entry["error"], **entry})
            return self._json(200, {"ok": True, **entry})
        except Exception as exc:  # noqa: BLE001 - 落盘失败必须如实回 500
            entry["status"] = 500
            entry["error"] = repr(exc)
            self._receipt(run_id, entry)
            return self._json(500, {"ok": False, "error": repr(exc), **entry})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    global STAGE
    if len(sys.argv) > 2:
        STAGE = os.path.abspath(sys.argv[2])
    os.makedirs(EVIDENCE, exist_ok=True)
    os.makedirs(STAGE, exist_ok=True)
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    sys.stderr.write("MwEvidence listening 0.0.0.0:%d stage=%s evidence=%s\n" % (port, STAGE, EVIDENCE))
    sys.stderr.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
