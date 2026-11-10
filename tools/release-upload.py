#!/usr/bin/env python3
"""上传 GitHub Release（V3.1.0）。

Token 从环境变量 GH_TOKEN 读取（本机存在 secrets/github-token.txt，可用
`export GH_TOKEN=$(tr -d '\\r\\n' < secrets/github-token.txt)` 注入），
不要把 token 写进命令行或提交到仓库。

用法：
  python tools/release-upload.py [--repo O/R] [--tag V3.1.0] [--title V3.1.0]
                                 [--asset-dir dist/release-3.1.0] [--notes ...]

幂等：release 已存在则复用；同名资产先删再传；已上传且大小一致的资产跳过。
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
UPLOADS = "https://uploads.github.com"


def req(method, url, token, body=None, content_type="application/json", timeout=120):
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", "Bearer " + token)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("X-GitHub-Api-Version", "2022-11-28")
    r.add_header("User-Agent", "MinglingWorkbench-release")
    if data is not None:
        r.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            payload = json.loads(raw)
        except Exception:
            payload = raw[:300].decode("utf-8", "replace")
        return e.code, payload


def upload_asset(repo, release_id, path, token, timeout=1800):
    name = os.path.basename(path)
    size = os.path.getsize(path)
    url = "%s/repos/%s/releases/%d/assets?name=%s" % (
        UPLOADS, repo, release_id, urllib.parse.quote(name))
    r = urllib.request.Request(url, method="POST")
    r.add_header("Authorization", "Bearer " + token)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "MinglingWorkbench-release")
    r.add_header("Content-Type", "application/octet-stream")
    # 直接读进内存：urllib 对 file-like data 会走 chunked 编码，GitHub 会报
    # 400 Bad Content-Length。88 MB 以内内存完全够用。
    with open(path, "rb") as f:
        r.data = f.read()
    assert len(r.data) == size, "读取字节数与文件大小不一致"
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return json.loads(resp.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="linyuehua0010/mingling-workbench")
    ap.add_argument("--tag", default="V3.1.0")
    ap.add_argument("--title", default="V3.1.0")
    ap.add_argument("--asset-dir", default=os.path.join("dist", "release-3.1.0"))
    ap.add_argument("--notes", default=None)
    ap.add_argument("--skip", default="RELEASE-NOTES.md")
    ap.add_argument("--only", default="", help="只传这些文件名（逗号分隔）")
    args = ap.parse_args()

    token = os.environ.get("GH_TOKEN", "").strip()
    if not token:
        print("缺少 GH_TOKEN", file=sys.stderr)
        return 2

    status, me = req("GET", API + "/user", token)
    if status != 200:
        print("token 校验失败：%s %s" % (status, me), file=sys.stderr)
        return 2
    print("token 用户：%s" % me.get("login"))

    notes_path = args.notes or os.path.join(args.asset_dir, "RELEASE-NOTES.md")
    notes = open(notes_path, encoding="utf-8").read() if os.path.exists(notes_path) else ""

    status, rel = req("GET", "%s/repos/%s/releases/tags/%s" % (API, args.repo, args.tag), token)
    if status == 200:
        print("release 已存在：%s (id=%s)，复用" % (args.tag, rel["id"]))
    elif status == 404:
        status, rel = req("POST", "%s/repos/%s/releases" % (API, args.repo), token, {
            "tag_name": args.tag,
            "target_commitish": "main",
            "name": args.title,
            "body": notes,
            "draft": False,
            "prerelease": False,
        })
        if status not in (200, 201):
            print("创建 release 失败：%s %s" % (status, rel), file=sys.stderr)
            return 1
        print("release 已创建：%s (id=%s)" % (args.tag, rel["id"]))
    else:
        print("查询 release 失败：%s %s" % (status, rel), file=sys.stderr)
        return 1

    rid = rel["id"]
    status, data = req("GET", "%s/repos/%s/releases/%d/assets?per_page=100" % (API, args.repo, rid), token)
    existing = {a["name"]: a for a in (data or [])} if status == 200 else {}

    only = [x.strip() for x in args.only.split(",") if x.strip()]
    files = sorted(f for f in os.listdir(args.asset_dir)
                   if os.path.isfile(os.path.join(args.asset_dir, f)) and f != args.skip
                   and (not only or f in only))
    for name in files:
        path = os.path.join(args.asset_dir, name)
        size = os.path.getsize(path)
        old = existing.get(name)
        if old and old.get("size") == size:
            # 已存在且大小一致：删掉重传，确保内容与本地一致（GitHub 无本地哈希可比）
            st, _ = req("DELETE", "%s/repos/%s/releases/assets/%d" % (API, args.repo, old["id"]), token)
            print("  覆盖：%s（删旧 %s）" % (name, st))
        elif old:
            req("DELETE", "%s/repos/%s/releases/assets/%d" % (API, args.repo, old["id"]), token)
            print("  覆盖：%s（旧大小 %s → 新 %s）" % (name, old.get("size"), size))
        print("上传 %s（%.1f MB）…" % (name, size / 1048576.0))
        sys.stdout.flush()
        try:
            obj = upload_asset(args.repo, rid, path, token)
        except urllib.error.HTTPError as e:
            print("  失败：%s %s" % (e.code, e.read()[:300]), file=sys.stderr)
            return 1
        except Exception as e:  # noqa: BLE001
            print("  失败：%s" % e, file=sys.stderr)
            return 1
        print("  OK：%s %s B" % (obj.get("name"), obj.get("size")))

    status, final = req("GET", "%s/repos/%s/releases/tags/%s" % (API, args.repo, args.tag), token)
    print("")
    print("release: %s" % final.get("html_url"))
    print("资产 %d 个：" % len(final.get("assets", [])))
    for a in final.get("assets", []):
        print("  %-45s %12d  %s" % (a["name"], a["size"], a.get("digest") or ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
